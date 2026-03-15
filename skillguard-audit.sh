#!/bin/bash
# skillguard-audit.sh
# SkillGuard Audit — 技能安全审查主控脚本 5.6.4
# 用法：bash skillguard-audit.sh <skill-source> <skill-name>
#
# 流程（5.6.4 重新设计）：
#   1. 创建唯一临时目录 + SHA256 基线快照
#   2. git clone --depth=1 获取技能文件（替代 Docker+npm install）
#   3. Layer 0: AV 杀毒扫描（Windows Defender CLI 优先，火绒备用）
#   4. 文件隔离转移：复制到 Docker Volume，删除主机文件
#   5. Layer 1: Prompt Injection 语义扫描（容器内，24+ 检测项）
#   6. Layer 2: Docker 强化容器代码扫描（容器内）
#   7. Layer 3: Docker 动态行为测试（仅高危触发，容器内）
#   8. 销毁 Docker Volume + 删除主机临时目录
#   9. SHA256 完整性验证
#  10. 生成报告

set -uo pipefail

# ── 心跳看门狗（每步必须喂狗，60 秒无心跳则强制终止）────────
# 原理：脚本每完成一个步骤就更新心跳文件的时间戳
#       后台看门狗每 5 秒检查心跳，如果超过 60 秒没更新 → 脚本卡死 → 强制 kill
#       正常运行不会触发（每步都喂狗），只有真正卡住才杀
SG_HEARTBEAT_INTERVAL=60  # 心跳超时阈值（秒）：单步超过这个时间未喂狗就判定卡死
SG_HEARTBEAT_FILE="${TMPDIR:-/tmp}/sg-heartbeat-$$"
SG_SCRIPT_PID=$$

# 初始心跳
date +%s | tr -d '\r\n' > "$SG_HEARTBEAT_FILE"

# 喂狗函数（每步开始时调用）
sg_heartbeat() {
    date +%s | tr -d '\r\n' > "$SG_HEARTBEAT_FILE"
}

# 后台看门狗进程
(
    while true; do
        sleep 5
        # 脚本已退出则看门狗自行结束
        if ! kill -0 $SG_SCRIPT_PID 2>/dev/null; then
            break
        fi
        # 检查心跳年龄
        if [ -f "$SG_HEARTBEAT_FILE" ]; then
            last_beat=$(cat "$SG_HEARTBEAT_FILE" 2>/dev/null | tr -d '\r\n' || echo "0")
            now=$(date +%s | tr -d '\r\n')
            age=$((now - last_beat))
            if [ $age -gt $SG_HEARTBEAT_INTERVAL ]; then
                echo "" >&2
                echo "[SkillGuard] ⛔ 看门狗：${age}s 无心跳（阈值 ${SG_HEARTBEAT_INTERVAL}s），某步骤卡死，强制终止" >&2
                kill $SG_SCRIPT_PID 2>/dev/null
                sleep 2
                kill -9 $SG_SCRIPT_PID 2>/dev/null
                break
            fi
        fi
    done
    rm -f "$SG_HEARTBEAT_FILE" 2>/dev/null
) &
SG_WATCHDOG_PID=$!

# 正常退出时取消看门狗 + 清理心跳文件
sg_cancel_watchdog() {
    kill "$SG_WATCHDOG_PID" 2>/dev/null || true
    rm -f "$SG_HEARTBEAT_FILE" 2>/dev/null || true
}

# ── 步骤超时保护函数 ─────────────────────────────────────────
# 用法: sg_run_step "步骤名" 超时秒数 命令...
# 超时后输出警告并返回非零，不会卡死
sg_run_step() {
    local step_name="$1"
    local step_timeout="$2"
    shift 2
    timeout "$step_timeout" "$@"
    local rc=$?
    if [ $rc -eq 124 ]; then
        echo "   ⛔ [$step_name] 超时（${step_timeout}s），已强制终止"
    fi
    return $rc
}

# ── 确定 Python 命令（验证真实可用，排除 Windows Store stub）──
SG_PYTHON=""
for _candidate in python3 python; do
    if command -v "$_candidate" &>/dev/null && "$_candidate" --version &>/dev/null; then
        SG_PYTHON="$_candidate"
        break
    fi
done

SKILL_SOURCE="${1:-}"
SKILL_NAME="${2:-unknown}"

# ── 输入验证（防命令注入）────────────────────────────────
if [ -z "$SKILL_SOURCE" ]; then
    echo "❌ 用法：bash skillguard-audit.sh <skill-source> <skill-name>"
    exit 1
fi
if [[ ! "$SKILL_SOURCE" =~ ^[a-zA-Z0-9_./@:=-]+$ ]]; then
    echo "❌ 技能来源包含非法字符，拒绝执行：$SKILL_SOURCE"
    echo "   仅允许：字母、数字、_  .  /  @  :  =  -"
    exit 1
fi
if [[ ! "$SKILL_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "❌ 技能名称包含非法字符，拒绝执行：$SKILL_NAME"
    echo "   仅允许：字母、数字、_  -"
    exit 1
fi

# ── 路径配置 ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_SKILLS_DIR="$HOME/.claude/.agents/skills"

# ── 环境检测（全部加超时，防止阻塞）─────────────────────────
# Windows 版本检测（影响 Layer 3 策略）
WIN_EDITION=""
if command -v powershell.exe &>/dev/null; then
    WIN_EDITION=$(timeout 5 powershell.exe -NoProfile -Command \
        "(Get-CimInstance Win32_OperatingSystem).Caption" 2>/dev/null | tr -d '\r' || echo "")
fi
IS_WIN_HOME=0
if echo "$WIN_EDITION" | grep -qi "home"; then
    IS_WIN_HOME=1
fi

# 火绒路径自动检测（备用 AV 引擎，仅在 Windows Defender 不可用时使用）
HUORONG=""
HUORONG_CANDIDATES=(
    "C:/Program Files/Huorong/Sysdiag/bin/HipsMain.exe"
    "C:/Program Files (x86)/Huorong/Sysdiag/bin/HipsMain.exe"
    "D:/Program Files/Huorong/Sysdiag/bin/HipsMain.exe"
)
for candidate in "${HUORONG_CANDIDATES[@]}"; do
    wsl_path=$(wslpath "$candidate" 2>/dev/null || echo "$candidate")
    if [ -f "$wsl_path" ] || [ -f "$candidate" ]; then
        HUORONG="$candidate"
        break
    fi
done

# Windows Defender CLI 路径
DEFENDER_CLI="C:/Program Files/Windows Defender/MpCmdRun.exe"

# ── CVE 版本预检（依赖组件安全基线）────────────────────────
CVE_WARNINGS=""
check_version_gte() {
    # 比较版本号: check_version_gte "current" "minimum" => 0 if current >= minimum
    local cur="$1" min="$2"
    [ "$(printf '%s\n%s' "$min" "$cur" | sort -V | head -1)" = "$min" ]
}

# Docker Desktop 版本检查
if command -v docker &>/dev/null; then
    DOCKER_VER=$(timeout 5 docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
    # CVE-2025-9074 (CVSS 9.3): Docker Desktop 本地 API 暴露，修复版本 4.44.3
    if ! check_version_gte "$DOCKER_VER" "4.44.3" 2>/dev/null; then
        # Docker Engine version != Desktop version, check via docker info
        DESKTOP_VER=$(timeout 5 docker info --format '{{index .Labels "com.docker.desktop.version"}}' 2>/dev/null || echo "")
        if [ -n "$DESKTOP_VER" ] && ! check_version_gte "$DESKTOP_VER" "4.44.3" 2>/dev/null; then
            CVE_WARNINGS="${CVE_WARNINGS}[CVE-2025-9074] Docker Desktop $DESKTOP_VER < 4.44.3（本地 API 暴露）\n"
        fi
    fi
    # runc 版本检查: CVE-2025-31133/52565/52881 (容器逃逸)
    RUNC_VER=$(timeout 5 docker info --format '{{.RuncCommit.ID}}' 2>/dev/null || echo "")
    if [ -n "$RUNC_VER" ]; then
        RUNC_FULL=$(timeout 3 runc --version 2>/dev/null | head -1 | sed -n 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' || echo "")
        if [ -n "$RUNC_FULL" ] && ! check_version_gte "$RUNC_FULL" "1.2.6" 2>/dev/null; then
            CVE_WARNINGS="${CVE_WARNINGS}[CVE-2025-31133] runc $RUNC_FULL < 1.2.6（容器逃逸风险）\n"
        fi
    fi
fi

# Node.js 版本检查（供应链安全）
if command -v node &>/dev/null; then
    NODE_VER=$(node --version 2>/dev/null | tr -d 'v' || echo "0.0.0")
    if ! check_version_gte "$NODE_VER" "20.0.0" 2>/dev/null; then
        CVE_WARNINGS="${CVE_WARNINGS}[供应链] Node.js $NODE_VER < 20（建议使用 LTS）\n"
    fi
fi

# ── 临时目录（唯一、有边界）─────────────────────────────────
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RAND=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 4)
# Windows Git Bash: /tmp 不映射到 Docker 可挂载路径，改用 $HOME 下目录
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    AUDIT_TMP_BASE="$HOME/.skillguard-tmp"
else
    AUDIT_TMP_BASE="/tmp"
fi
AUDIT_TMP="${AUDIT_TMP_BASE}/skillguard-audit-${TIMESTAMP}-${RAND}"
SKILL_FILES="${AUDIT_TMP}/skill-files"

# ── 结果追踪 ─────────────────────────────────────────────────
L0_RESULT="SKIP"
L1_RESULT="SKIP"
L2_RESULT="SKIP"
L3_RESULT="SKIP"
L0_DETAIL=""
L1_DETAIL=""
L2_DETAIL=""
L3_DETAIL=""
FINAL_VERDICT="UNKNOWN"

# ── Docker Volume 名称（用于隔离扫描）────────────────────────
SG_VOLUME_NAME="sg-scan-${TIMESTAMP}-${RAND}"
SG_VOLUME_CREATED=false

# ── 进度计时器 ───────────────────────────────────────────────
AUDIT_START_TIME=$SECONDS
log_progress() {
    local elapsed=$((SECONDS - AUDIT_START_TIME))
    printf "[%02d:%02d] %s\n" $((elapsed/60)) $((elapsed%60)) "$1"
}

# ── 工具函数 ─────────────────────────────────────────────────
log_section() { echo ""; sg_heartbeat; log_progress "━━━ $1 ━━━"; }
log_ok()      { echo "   ✅ $1"; }
log_warn()    { echo "   ⚠️  $1"; }
log_fail()    { echo "   ❌ $1"; }

# ── 清理函数（三重验证防误删）────────────────────────────────
safe_delete_tmp() {
    local target="$1"
    if [ -z "$target" ]; then return 1; fi
    if [[ "$target" != "${AUDIT_TMP_BASE}/skillguard-audit-"* ]]; then
        echo "[safe_delete] 跳过：路径不符合安全前缀规范 ($target)"; return 1
    fi
    if [ ! -d "$target" ]; then return 0; fi
    rm -rf "$target"
    log_progress "🗑️  临时目录已安全删除"
}

# ── Docker Volume 清理 ────────────────────────────────────────
cleanup_volume() {
    if $SG_VOLUME_CREATED; then
        docker volume rm "$SG_VOLUME_NAME" 2>/dev/null && \
            log_progress "🗑️  Docker Volume 已销毁: $SG_VOLUME_NAME" || true
        SG_VOLUME_CREATED=false
    fi
}

# 确保异常退出时也清理
trap 'sg_cancel_watchdog; safe_delete_tmp "$AUDIT_TMP" 2>/dev/null; cleanup_volume 2>/dev/null' EXIT

# ── 来源风险分级 ─────────────────────────────────────────────
classify_risk() {
    local src="$1"
    if echo "$src" | grep -qE '^clawhub'; then
        echo "EXTREME"
    elif echo "$src" | grep -qE '^[^/]+/[^/]+@'; then
        # GitHub 来源：看 stars 需人工判断，默认为 MEDIUM
        echo "MEDIUM"
    else
        echo "HIGH"
    fi
}
SOURCE_RISK=$(classify_risk "$SKILL_SOURCE")

# ════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           SkillGuard 隔离安全审查流水线 5.6.4                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  技能：%-50s║\n" "$SKILL_NAME"
printf "║  来源：%-50s║\n" "$SKILL_SOURCE"
printf "║  风险级别：%-46s║\n" "$SOURCE_RISK"
printf "║  时间：%-50s║\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "║  环境：%-50s║\n" "${WIN_EDITION:-unknown}"
AV_ENGINE_NAME="未找到"
if [ -f "$DEFENDER_CLI" ]; then
    AV_ENGINE_NAME="Windows Defender CLI"
elif [ -n "$HUORONG" ]; then
    AV_ENGINE_NAME="火绒(GUI备用)"
fi
printf "║  AV引擎：%-48s║\n" "$AV_ENGINE_NAME"
printf "║  Layer3：%-48s║\n" "Docker Volume 隔离"
echo "╚══════════════════════════════════════════════════════════╝"

# 显示 CVE 版本预检警告
if [ -n "$CVE_WARNINGS" ]; then
    echo ""
    echo "┌── CVE 版本预检警告 ──────────────────────────────────────┐"
    echo -e "$CVE_WARNINGS" | while read -r line; do
        [ -n "$line" ] && echo "│  ⚠️  $line"
    done
    echo "└─────────────────────────────────────────────────────────┘"
fi

# ── STEP 1：创建临时目录 + SHA256 基线快照 ─────────────────────
log_section "准备：创建临时工作目录 + 安全基线"
mkdir -p "$SKILL_FILES"
echo "   📁 临时目录：$AUDIT_TMP"

# SHA256 基线快照：记录关键文件的哈希值（安装前）
BASELINE_FILE="${AUDIT_TMP_BASE}/integrity-baseline-${RAND}.sha256"
INTEGRITY_TARGETS=(
    "$HOME/.claude/CLAUDE.md"
    "$HOME/.claude/settings.json"
    "$HOME/.claude/settings.local.json"
    "$HOME/.bashrc"
    "$HOME/.zshrc"
    "$HOME/.profile"
)
BASELINE_COUNT=0
for target in "${INTEGRITY_TARGETS[@]}"; do
    if [ -f "$target" ]; then
        sha256sum "$target" >> "$BASELINE_FILE" 2>/dev/null
        BASELINE_COUNT=$((BASELINE_COUNT+1))
    fi
done
# 也记录 .claude/hooks/ 目录下所有文件
if [ -d "$HOME/.claude/hooks" ]; then
    find "$HOME/.claude/hooks" -type f -exec sha256sum {} + >> "$BASELINE_FILE" 2>/dev/null
    HOOKS_COUNT=$(find "$HOME/.claude/hooks" -type f 2>/dev/null | wc -l)
    BASELINE_COUNT=$((BASELINE_COUNT + HOOKS_COUNT))
fi
echo "   🔐 SHA256 基线已建立：$BASELINE_COUNT 个文件"

# ── STEP 2：获取技能文件（git clone，替代 Docker+npm install）──
log_section "Step 2：获取技能文件（git clone）"

# 从 SKILL_SOURCE 提取 GitHub repo slug
REPO_SLUG=$(echo "$SKILL_SOURCE" | \
    sed 's|https\?://github\.com/||' | \
    sed 's|https\?://clawhub\.ai/||' | \
    sed 's|\.git$||' | \
    sed 's/@.*//')

if ! echo "$REPO_SLUG" | grep -qE '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$'; then
    log_fail "无法识别仓库格式：$SKILL_SOURCE（需要 owner/repo）"
    safe_delete_tmp "$AUDIT_TMP"
    exit 1
fi

STEP2_OK=false

# 主路径：git clone
if command -v git &>/dev/null; then
    if timeout 30 git clone --depth=1 -q "https://github.com/$REPO_SLUG.git" "$SKILL_FILES" 2>/dev/null; then
        log_ok "git clone 成功（$REPO_SLUG）"
        STEP2_OK=true
    fi
fi

# 降级：gh repo clone
if ! $STEP2_OK && command -v gh &>/dev/null; then
    if timeout 30 gh repo clone "$REPO_SLUG" "$SKILL_FILES" -- --depth=1 -q 2>/dev/null; then
        log_ok "gh repo clone 成功（$REPO_SLUG）"
        STEP2_OK=true
    fi
fi

if ! $STEP2_OK; then
    log_fail "技能文件获取失败（git 和 gh 均不可用或网络错误）"
    safe_delete_tmp "$AUDIT_TMP"
    exit 1
fi

# 检查文件是否存在
if [ -z "$(ls -A "$SKILL_FILES" 2>/dev/null)" ]; then
    log_fail "技能文件为空，无法继续审查"
    safe_delete_tmp "$AUDIT_TMP"
    exit 1
fi

# ════════════════════════════════════════════════════════════
#  LAYER 0：AV 杀毒扫描（Windows Defender 优先，火绒备用）
# ════════════════════════════════════════════════════════════
log_section "Layer 0：AV 杀毒扫描"

# 扫描前删除 .git 目录（二进制文件，不需要扫描，避免误报）
rm -rf "$SKILL_FILES/.git" 2>/dev/null
log_ok "已删除 .git/ 目录（排除二进制文件）"

# Windows 路径（用于 AV 扫描）
WIN_SKILL_FILES=$(cygpath -w "$SKILL_FILES" 2>/dev/null || wslpath -w "$SKILL_FILES" 2>/dev/null || echo "$SKILL_FILES")

# AV 引擎优先级：Windows Defender CLI（有退出码） > 火绒（GUI 模式，会阻塞）

if [ -f "$DEFENDER_CLI" ]; then
    log_ok "使用 Windows Defender CLI 扫描"
    DEFENDER_OUTPUT=$(timeout 60 "$DEFENDER_CLI" -Scan -ScanType 3 -File "$WIN_SKILL_FILES" -DisableRemediation 2>&1) || true
    DEFENDER_EXIT=$?
    if [ $DEFENDER_EXIT -eq 0 ]; then
        L0_RESULT="PASS"
        log_ok "Windows Defender：未发现威胁"
    elif [ $DEFENDER_EXIT -eq 2 ]; then
        L0_RESULT="FAIL"
        L0_DETAIL="Windows Defender 发现威胁"
        log_fail "Windows Defender 检测到威胁！"
        echo "$DEFENDER_OUTPUT" | grep -i "Threat" | head -5 | sed 's/^/      /'
    elif [ $DEFENDER_EXIT -eq 124 ]; then
        L0_RESULT="SKIP"
        log_warn "Windows Defender 扫描超时（120 秒），已跳过"
    else
        L0_RESULT="SKIP"
        log_warn "Windows Defender 退出码：$DEFENDER_EXIT（非标准，跳过）"
    fi
elif [ -n "$HUORONG" ]; then
    # 火绒备用：HipsMain.exe -s 会弹 GUI 窗口，扫完不自动退出
    log_warn "火绒为 GUI 模式（备用），启动后台扫描（10 秒等待）"
    "$HUORONG" -s "$WIN_SKILL_FILES" &>/dev/null &
    AV_PID=$!
    sleep 10
    kill "$AV_PID" 2>/dev/null || true
    L0_RESULT="SKIP"
    log_warn "火绒 GUI 扫描已触发（备用引擎，无退出码，请查看火绒窗口）"
else
    L0_RESULT="SKIP"
    log_warn "未找到 AV 引擎（Windows Defender / 火绒），跳过 Layer 0"
fi

# ════════════════════════════════════════════════════════════
#  LAYER 1：Prompt Injection 语义扫描（主机 Python，在隔离转移前执行）
# ════════════════════════════════════════════════════════════
log_section "Layer 1：Prompt Injection 语义扫描"

L1_ISSUES=0
L1_LINES=""
L1_HAS_CRITICAL=0

DOCKER_AVAILABLE=false
if command -v docker &>/dev/null && timeout 10 docker info &>/dev/null 2>&1; then
    DOCKER_AVAILABLE=true
fi

# Layer 1 在主机上执行（文件还在主机临时目录，.git/ 已删除）
if [ -n "$SG_PYTHON" ]; then
    L1_OUTPUT=$(timeout 60 $SG_PYTHON << 'PYEOF'
import sys, os, json, re

scan_dir = sys.argv[1] if len(sys.argv) > 1 else "."
issues = {}

def walk_files(d):
    for root, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if x != ".git"]
        for f in files:
            yield os.path.join(root, f)

def read_file(path):
    try: return open(path, "r", encoding="utf-8", errors="ignore").read()
    except: return ""

def grep_check(desc, pattern):
    found = []
    pat = re.compile(pattern, re.IGNORECASE)
    for path in walk_files(scan_dir):
        text = read_file(path)
        for i, line in enumerate(text.split("\n"), 1):
            if pat.search(line):
                found.append(f"{path}:{i}: {line[:120]}")
                if len(found) >= 3: break
        if len(found) >= 3: break
    return found

# 1-6: Basic patterns
for desc, pat in [
    ("HTML注释隐藏指令", r"<!--.*--(execute|send|read|fetch|POST|ignore|override|system|admin)"),
    ("权威紧迫语言", r"(system|admin|critical|urgent).{0,50}(immediately|always|must|override)"),
    ("凭证关键词", r"API_KEY|ANTHROPIC_KEY|Bearer|private[._]key"),
    ("指令覆盖", r"ignore previous|override instruction|disregard|higher priority"),
    ("外传域名", r"webhook\.site|pipedream\.net|requestbin|ngrok\.io|burpcollaborator|interact\.sh"),
    ("DNS外传", r"(ping|dig|nslookup|host)\s+.{0,50}\.(com|net|io|xyz|top)"),
    ("Base64混淆", r"(decode|base64|atob|btoa|b64decode).{0,100}(execute|run|eval|system|exec)"),
    ("Markdown图片外传", r"!\[.*\]\(https?://[^)]{5,}\)"),
    ("中文指令覆盖", r"忽略.{0,20}(之前|上面|前面|以上)|覆盖.{0,20}指令|系统.{0,20}提示|无视.{0,20}(规则|限制)"),
    ("伪造系统消息", r"(\[SYSTEM\]|\[system\]|<\|im_start\|>system|<system>|role.*system.*content)"),
    ("环境变量外传", r"(ANTHROPIC|OPENAI|AWS|GITHUB|SLACK|DISCORD)_[A-Z_]*.*https?://"),
    ("多层编码混淆", r"(atob|btoa|base64|hex|charCodeAt|fromCharCode).{0,80}(eval|exec)"),
    ("CSS隐藏文本", r"(display:\s*none|visibility:\s*hidden|font-size:\s*0|opacity:\s*0).{0,200}(ignore|override|execute)"),
    ("DataURI嵌入", r"data:(text|application)/(html|javascript|x-python)[;,]"),
]:
    r = grep_check(desc, pat)
    if r: issues[desc] = r

# 7. 零宽字符
zwc = set("\u200b\u200c\u200d\ufeff\u200e\u200f\u2060")
for path in walk_files(scan_dir):
    text = read_file(path)
    if any(c in zwc for c in text):
        issues.setdefault("零宽字符", []).append(path)

# 8. Unicode Tag（仅 Tags block，排除 Variation Selectors）
for path in walk_files(scan_dir):
    text = read_file(path)
    if any("\U000E0000" <= c <= "\U000E007F" for c in text):
        issues.setdefault("CRITICAL:UnicodeTag", []).append(f"ASCII_SMUGGLING: {path}")

# 9. BiDi
bidi = set("\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069\u200E\u200F\u061C")
for path in walk_files(scan_dir):
    text = read_file(path)
    found = [c for c in text if c in bidi]
    if found:
        issues.setdefault("CRITICAL:BiDi", []).append(f"BIDI: {path}")

# 10. 反向 Shell
r = grep_check("CRITICAL:反向Shell", r"bash\s+-i.*(/dev/tcp|/dev/udp)|nc\s+(-e|--exec)|mkfifo.*nc|python.*socket.*connect")
if r: issues["CRITICAL:反向Shell"] = r

# 11. Homoglyph
CONFUSABLES = {
    "\u0410":"A","\u0412":"B","\u0421":"C","\u0415":"E","\u041D":"H",
    "\u041A":"K","\u041C":"M","\u041E":"O","\u0420":"P","\u0422":"T",
    "\u0430":"a","\u0435":"e","\u043E":"o","\u0440":"p","\u0441":"c",
    "\u0455":"s","\u0456":"i","\u0458":"j",
}
cs = set(CONFUSABLES.keys())
for path in walk_files(scan_dir):
    text = read_file(path)
    found = {c for c in text if c in cs}
    if found:
        for ch in list(found)[:3]:
            issues.setdefault("CRITICAL:Homoglyph", []).append(f"U+{ord(ch):04X} in {path}")

# 12. Hook 注入
import glob
hook_files = glob.glob(os.path.join(scan_dir, "**/.claude/settings.json"), recursive=True)
for hf in hook_files:
    if "hooks" in read_file(hf).lower():
        issues.setdefault("CRITICAL:Hook注入", []).append(hf)

print(json.dumps(issues, ensure_ascii=False))
PYEOF
"$SKILL_FILES" 2>/dev/null) || L1_OUTPUT="{}"

    # 解析结果
    if echo "$L1_OUTPUT" | $SG_PYTHON -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        L1_KEYS=$(echo "$L1_OUTPUT" | $SG_PYTHON -c "
import sys, json
data = json.load(sys.stdin)
for key, vals in data.items():
    critical = key.startswith('CRITICAL:')
    name = key.replace('CRITICAL:', '')
    status = 'CRITICAL' if critical else 'WARN'
    print(f'{status}|{name}|{vals[0] if vals else \"\"}')
" 2>/dev/null || true)
        while IFS='|' read -r severity name detail; do
            [ -z "$name" ] && continue
            if [ "$severity" = "CRITICAL" ]; then
                log_warn "$name（高危）"
                echo "      $detail" | head -1
                L1_HAS_CRITICAL=1
            else
                log_warn "$name"
                echo "      $detail" | head -1
            fi
            L1_ISSUES=$((L1_ISSUES+1))
        done <<< "$L1_KEYS"
    fi
    if [ $L1_ISSUES -eq 0 ]; then
        log_ok "24 项安全检测全部通过"
    fi
else
    log_warn "Python 不可用，Layer 1 仅做基础 grep 扫描"
    for pattern_desc in \
        "HTML注释隐藏指令|-rniE|<!--.*--(execute|send|read|fetch|POST|ignore|override|system|admin)" \
        "指令覆盖|-rniE|ignore previous|override instruction|disregard|higher priority" \
        "外传域名|-rniE|webhook\.site|pipedream\.net|requestbin|ngrok\.io"; do
        desc=$(echo "$pattern_desc" | cut -d'|' -f1)
        result=$(grep -rniE "$(echo "$pattern_desc" | cut -d'|' -f3)" "$SKILL_FILES" 2>/dev/null | head -3 || true)
        if [ -n "$result" ]; then
            log_warn "$desc"
            echo "$result" | sed 's/^/      /'
            L1_ISSUES=$((L1_ISSUES+1))
        fi
    done
    [ $L1_ISSUES -eq 0 ] && log_ok "基础检测通过"
fi

# ── 判定逻辑（按严重性分级，不仅按数量）─────────────────────

if [ $L1_ISSUES -eq 0 ]; then
    L1_RESULT="PASS"
elif [ "$L1_HAS_CRITICAL" -eq 1 ]; then
    L1_RESULT="FAIL"
    L1_DETAIL="发现 $L1_ISSUES 个风险项（含高危：Unicode Tag/BiDi/Hook 注入）"
elif [ $L1_ISSUES -le 2 ]; then
    L1_RESULT="WARN"
    L1_DETAIL="发现 $L1_ISSUES 个中等风险项"
else
    L1_RESULT="FAIL"
    L1_DETAIL="发现 $L1_ISSUES 个高风险项"
fi

# ════════════════════════════════════════════════════════════
#  文件隔离转移：主机文件 → Docker Volume → 删除主机文件
#  （Layer 1 已在主机完成，后续 Layer 2-3 在容器内执行）
# ════════════════════════════════════════════════════════════
log_section "文件隔离转移：主机 → Docker Volume"

if $DOCKER_AVAILABLE; then
    # 创建 Docker Volume
    timeout 10 docker volume create "$SG_VOLUME_NAME" >/dev/null 2>&1
    SG_VOLUME_CREATED=true
    log_ok "Docker Volume 已创建: $SG_VOLUME_NAME"

    # 复制文件到 Volume（使用本地已有的 node:20-slim 镜像）
    MSYS_NO_PATHCONV=1 timeout 30 docker run --rm \
        -v "$SKILL_FILES:/src:ro" \
        -v "$SG_VOLUME_NAME:/dst" \
        node:20-slim sh -c "cp -r /src/* /dst/ 2>/dev/null; echo COPY_DONE" >/dev/null 2>&1

    # 立即删除主机文件
    rm -rf "$SKILL_FILES"
    mkdir -p "$SKILL_FILES"
    log_ok "主机文件已删除，后续扫描仅在 Docker Volume 内进行"
else
    log_warn "Docker 不可用，文件保留在主机临时目录（无隔离）"
fi

# ════════════════════════════════════════════════════════════
#  LAYER 2：Docker 强化容器代码扫描（使用 Volume 隔离）
# ════════════════════════════════════════════════════════════
log_section "Layer 2：Docker 容器代码扫描"

if $DOCKER_AVAILABLE; then
    # 确定挂载参数（Volume 或主机目录）
    L2_MOUNT=""
    if $SG_VOLUME_CREATED; then
        L2_MOUNT="-v $SG_VOLUME_NAME:/scan:ro"
    else
        L2_MOUNT="-v $SKILL_FILES:/scan:ro"
    fi

    L2_OUTPUT=$(timeout 60 docker run --rm \
        --network none \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --pids-limit 100 \
        --memory 256m \
        --tmpfs /tmp:size=10m,noexec \
        --tmpfs /dev/shm:size=1m,noexec \
        $L2_MOUNT \
        node:20-slim sh -c '
            ISSUES=""

            r=$(grep -rn -E "eval\s*\(|base64.*\|.*bash|curl.*\|.*sh|echo.*\|.*bash" /scan/ 2>/dev/null)
            [ -n "$r" ] && ISSUES="${ISSUES}[危险执行模式]\n${r}\n"

            r=$(grep -rn -E "~/\.ssh|~/\.aws|/etc/passwd|MEMORY\.md|\.env" /scan/ 2>/dev/null)
            [ -n "$r" ] && ISSUES="${ISSUES}[敏感路径访问]\n${r}\n"

            r=$(grep -rn -E "process\.env\.|os\.environ|printenv" /scan/ 2>/dev/null)
            [ -n "$r" ] && ISSUES="${ISSUES}[环境变量窃取]\n${r}\n"

            r=$(grep -rn -E "npx\s+-y\s+[^@\n]+$|curl.+\|.+(bash|sh)" /scan/ 2>/dev/null)
            [ -n "$r" ] && ISSUES="${ISSUES}[供应链风险-unpinned]\n${r}\n"

            r=$(grep -rn -E "CLAUDE\.md|settings\.json|hooks|\.bashrc|crontab" /scan/ 2>/dev/null)
            [ -n "$r" ] && ISSUES="${ISSUES}[持久化后门]\n${r}\n"

            if [ -n "$ISSUES" ]; then
                echo "ISSUES_FOUND"
                echo -e "$ISSUES"
            else
                echo "CLEAN"
            fi
        ' 2>/dev/null) || true

    if echo "$L2_OUTPUT" | grep -q "^CLEAN"; then
        L2_RESULT="PASS"
        log_ok "所有代码模式检查通过"
    elif echo "$L2_OUTPUT" | grep -q "ISSUES_FOUND"; then
        L2_RESULT="WARN"
        L2_DETAIL=$(echo "$L2_OUTPUT" | grep -v "ISSUES_FOUND")
        log_warn "发现可疑代码模式，建议人工复核"
        echo "$L2_DETAIL" | head -10 | sed 's/^/      /'
    fi
else
    L2_RESULT="SKIP"
    log_warn "Docker 不可用，跳过 Layer 2"
fi

# ════════════════════════════════════════════════════════════
#  LAYER 3：Docker 容器动态行为测试（仅高危触发）
#  5.6.4: 挂载已有文件，不再安装 claude-code 和 skills
# ════════════════════════════════════════════════════════════
if [ "$SOURCE_RISK" = "EXTREME" ] || [ "$SOURCE_RISK" = "HIGH" ] || \
   [ "$L1_RESULT" = "WARN" ] || [ "$L1_RESULT" = "FAIL" ]; then

    log_section "Layer 3：Docker 容器动态行为测试"

    if $DOCKER_AVAILABLE; then
        log_ok "启动隔离容器进行动态行为监测"

        # 确定挂载参数
        L3_MOUNT=""
        if $SG_VOLUME_CREATED; then
            L3_MOUNT="-v $SG_VOLUME_NAME:/app:ro"
        else
            L3_MOUNT="-v $SKILL_FILES:/app:ro"
        fi

        # 挂载已有文件，检查可执行脚本的行为
        L3_LOGS=$(timeout 60 docker run --rm \
            --cap-drop ALL \
            --security-opt no-new-privileges:true \
            --pids-limit 100 \
            --memory 256m \
            $L3_MOUNT \
            node:20-slim \
            bash -c '
                echo "=== L3 DYNAMIC TEST START ==="

                echo "--- Executable scripts check ---"
                find /app -name "*.sh" -o -name "*.py" -o -name "*.js" 2>/dev/null | head -20

                echo "--- Script content analysis ---"
                for script in $(find /app -name "*.sh" -o -name "*.py" -o -name "*.js" 2>/dev/null | head -10); do
                    echo ">> Checking: $script"
                    # 检查是否有网络调用、文件操作等
                    grep -nE "curl|wget|fetch|http|socket|exec|spawn|child_process|subprocess|os\.system" "$script" 2>/dev/null | head -5
                done

                echo "--- Package.json dependencies ---"
                if [ -f /app/package.json ]; then
                    cat /app/package.json | grep -A 20 "dependencies" 2>/dev/null | head -25
                fi

                echo "--- Hidden files check ---"
                find /app -name ".*" -not -name ".git" -not -name ".gitignore" -not -name ".npmignore" 2>/dev/null

                echo "=== L3 DYNAMIC TEST END ==="
            ' 2>&1) || L3_LOGS="DOCKER_RUN_FAILED"

        # 分析行为
        L3_ALERTS=""
        if echo "$L3_LOGS" | grep -qiE 'DOCKER_RUN_FAILED'; then
            L3_ALERTS="${L3_ALERTS}[容器执行失败] "
        fi
        if echo "$L3_LOGS" | grep -qiE 'curl|wget|nc\s|ncat|python.*http|child_process|subprocess'; then
            L3_ALERTS="${L3_ALERTS}[检测到网络/进程调用] "
        fi
        if echo "$L3_LOGS" | grep -qiE '\.ssh|\.aws|\.gnupg|credentials'; then
            L3_ALERTS="${L3_ALERTS}[访问敏感目录] "
        fi
        if echo "$L3_LOGS" | grep -qiE 'crontab|systemctl|\.bashrc.*>>'; then
            L3_ALERTS="${L3_ALERTS}[持久化行为] "
        fi

        if [ -n "$L3_ALERTS" ]; then
            L3_RESULT="WARN"
            L3_DETAIL="动态测试发现可疑行为：$L3_ALERTS"
            log_warn "动态测试发现可疑行为"
            echo "   警告：$L3_ALERTS"
            echo "   --- 关键日志片段 ---"
            echo "$L3_LOGS" | grep -iE 'curl|wget|ssh|aws|cron|bashrc|FAILED' | head -10 | sed 's/^/      /'
        else
            L3_RESULT="PASS"
            log_ok "动态测试通过，未发现可疑运行时行为"
        fi
    else
        L3_RESULT="SKIP"
        log_warn "Docker 不可用，跳过 Layer 3 动态测试"
    fi
fi

# ════════════════════════════════════════════════════════════
#  清理：销毁 Docker Volume + 删除临时目录
# ════════════════════════════════════════════════════════════
log_section "清理：销毁隔离资源"
cleanup_volume
safe_delete_tmp "$AUDIT_TMP"

# ════════════════════════════════════════════════════════════
#  SHA256 完整性验证（检测安装过程中关键文件是否被篡改）
# ════════════════════════════════════════════════════════════
log_section "完整性验证：SHA256 基线校验"
INTEGRITY_FAILED=0
if [ -f "$BASELINE_FILE" ]; then
    VERIFY_OUTPUT=$(sha256sum -c "$BASELINE_FILE" 2>&1 || true)
    FAILED_FILES=$(echo "$VERIFY_OUTPUT" | grep -i "FAILED" || true)
    if [ -n "$FAILED_FILES" ]; then
        INTEGRITY_FAILED=1
        log_fail "关键文件被篡改！"
        echo "$FAILED_FILES" | sed 's/^/      /'
        echo ""
        echo "   ⛔ 以下文件在审查过程中被修改（可能是恶意技能的副作用）："
        echo "$FAILED_FILES" | sed 's/^/      /'
    else
        log_ok "所有关键文件完整性验证通过（$BASELINE_COUNT 个文件未被篡改）"
    fi
    # 检查是否有新增的 hooks 文件
    if [ -d "$HOME/.claude/hooks" ]; then
        NEW_HOOKS=$(find "$HOME/.claude/hooks" -type f -newer "$BASELINE_FILE" 2>/dev/null || true)
        if [ -n "$NEW_HOOKS" ]; then
            INTEGRITY_FAILED=1
            log_fail "检测到新增 Hook 文件（可能的 CVE-2025-59536 攻击）："
            echo "$NEW_HOOKS" | sed 's/^/      /'
        fi
    fi
else
    log_warn "基线文件不存在，跳过完整性验证"
fi

# 清理基线文件
rm -f "$BASELINE_FILE" 2>/dev/null

# ════════════════════════════════════════════════════════════
#  最终判定
# ════════════════════════════════════════════════════════════
if [ "$L0_RESULT" = "FAIL" ] || [ "$L1_RESULT" = "FAIL" ] || [ "$INTEGRITY_FAILED" -eq 1 ]; then
    FINAL_VERDICT="MALICIOUS"
elif [ "$L1_RESULT" = "PASS" ] && \
     [ "$L2_RESULT" != "FAIL" ] && \
     [ "$L3_RESULT" != "WARN" ] && \
     [ "$L0_RESULT" != "FAIL" ]; then
    # L0 SKIP（AV 引擎未安装）不影响 SAFE 判定
    FINAL_VERDICT="SAFE"
else
    FINAL_VERDICT="WARN"
fi

# ── 生成汇总报告 ─────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                   SkillGuard 安全审查报告                         ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  技能名称：%-46s║\n" "$SKILL_NAME"
printf "║  来源：%-50s║\n" "$SKILL_SOURCE"
printf "║  审查时间：%-46s║\n" "$(date '+%Y-%m-%d %H:%M:%S')"
echo "╠══════════════════════════════════════════════════════════╣"

# 格式化报告行（避免 || 链式条件 bug）
_fmt_result() {
    case "$1" in
        PASS) echo "✅ 通过" ;;
        FAIL) echo "❌ 失败" ;;
        WARN) echo "⚠️  警告" ;;
        SKIP) echo "—  跳过" ;;
        *)    echo "—  未触发" ;;
    esac
}
printf "║  L0  AV 杀毒扫描          %-31s║\n" "$(_fmt_result $L0_RESULT)"
printf "║  L1  Prompt Injection    %-31s║\n" "$(_fmt_result $L1_RESULT)"
printf "║  L2  嵌入代码扫描          %-31s║\n" "$(_fmt_result $L2_RESULT)"
printf "║  L3  动态执行测试          %-31s║\n" "$(_fmt_result $L3_RESULT)"
echo "╠══════════════════════════════════════════════════════════╣"

case "$FINAL_VERDICT" in
    "MALICIOUS")
        echo "║  🚫 综合判定：恶意技能，已自动清除所有副本               ║"
        echo "╠══════════════════════════════════════════════════════════╣"
        [ -n "$L0_DETAIL" ] && printf "║  L0 威胁：%-46s║\n" "$L0_DETAIL"
        [ -n "$L1_DETAIL" ] && printf "║  L1 威胁：%-46s║\n" "$L1_DETAIL"
        echo "╚══════════════════════════════════════════════════════════╝"
        echo ""
        # 清理点 B：docker run --rm 自动清理，无需额外操作
        echo ""
        echo "⛔ 技能 [$SKILL_NAME] 被判定为恶意，已拒绝安装并清除所有隔离资源。"
        exit 2
        ;;
    "WARN")
        echo "║  ⚠️  综合判定：存在警告项，请人工确认后决定               ║"
        [ -n "$L1_DETAIL" ] && printf "║  警告：%-50s║\n" "$L1_DETAIL"
        [ -n "$L2_DETAIL" ] && printf "║  警告：%-50s║\n" "Layer2 有可疑模式"
        echo "╠══════════════════════════════════════════════════════════╣"
        echo "║  是否仍要释放安装到本机？                                 ║"
        echo "║  告知 Claude：「释放」或「取消」                           ║"
        echo "╚══════════════════════════════════════════════════════════╝"
        exit 3
        ;;
    "SAFE")
        echo "║  ✅ 综合判定：通过所有安全检查                            ║"
        echo "╠══════════════════════════════════════════════════════════╣"
        echo "║  是否释放安装到本机？                                     ║"
        echo "║  告知 Claude：「释放」或「取消」                           ║"
        echo "╚══════════════════════════════════════════════════════════╝"
        exit 0
        ;;
esac
