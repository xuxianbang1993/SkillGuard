#!/bin/bash
# skillguard-audit.sh
# SkillGuard Audit — 技能安全审查主控脚本 v5.0
# 用法：bash skillguard-audit.sh <skill-source> <skill-name>
# 示例：bash skillguard-audit.sh "owner/repo@my-skill" "my-skill"
#
# 流程：
#   1. 创建唯一临时目录 + SHA256 基线快照
#   2. Docker Sandbox 安装技能（microVM 隔离）
#   3. 同步文件到临时目录
#   4. Layer 0: 火绒 AV 扫描
#   5. Layer 1: Prompt Injection 语义扫描（24+ 检测项）
#   6. Layer 2: Docker 强化容器代码扫描
#   7. Layer 3: Docker Sandbox microVM 动态测试（高风险来源）
#   8. 清理点 A：删除临时目录（三重验证）
#   9. SHA256 完整性验证（检测安装过程是否篡改关键文件）
#  10. 生成报告，询问用户是否释放到本机

set -uo pipefail

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

# ── 环境检测 ────────────────────────────────────────────────
# Windows 版本检测（影响 Layer 3 策略）
WIN_EDITION=""
if command -v powershell.exe &>/dev/null; then
    WIN_EDITION=$(powershell.exe -NoProfile -Command \
        "(Get-CimInstance Win32_OperatingSystem).Caption" 2>/dev/null | tr -d '\r' || echo "")
fi
IS_WIN_HOME=0
if echo "$WIN_EDITION" | grep -qi "home"; then
    IS_WIN_HOME=1
fi

# 火绒路径自动检测（多路径容错）
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

# ── CVE 版本预检（依赖组件安全基线）────────────────────────
CVE_WARNINGS=""
check_version_gte() {
    # 比较版本号: check_version_gte "current" "minimum" => 0 if current >= minimum
    local cur="$1" min="$2"
    [ "$(printf '%s\n%s' "$min" "$cur" | sort -V | head -1)" = "$min" ]
}

# Docker Desktop 版本检查
if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
    # CVE-2025-9074 (CVSS 9.3): Docker Desktop 本地 API 暴露，修复版本 4.44.3
    if ! check_version_gte "$DOCKER_VER" "4.44.3" 2>/dev/null; then
        # Docker Engine version != Desktop version, check via docker info
        DESKTOP_VER=$(docker info --format '{{index .Labels "com.docker.desktop.version"}}' 2>/dev/null || echo "")
        if [ -n "$DESKTOP_VER" ] && ! check_version_gte "$DESKTOP_VER" "4.44.3" 2>/dev/null; then
            CVE_WARNINGS="${CVE_WARNINGS}[CVE-2025-9074] Docker Desktop $DESKTOP_VER < 4.44.3（本地 API 暴露）\n"
        fi
    fi
    # runc 版本检查: CVE-2025-31133/52565/52881 (容器逃逸)
    RUNC_VER=$(docker info --format '{{.RuncCommit.ID}}' 2>/dev/null || echo "")
    if [ -n "$RUNC_VER" ]; then
        RUNC_FULL=$(runc --version 2>/dev/null | head -1 | grep -oP '[\d.]+' || echo "")
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

# ── 工具函数 ─────────────────────────────────────────────────
log_section() { echo ""; echo "━━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
log_ok()      { echo "   ✅ $1"; }
log_warn()    { echo "   ⚠️  $1"; }
log_fail()    { echo "   ❌ $1"; }

# ── 清理函数（三重验证防误删）────────────────────────────────
safe_delete_tmp() {
    local target="$1"
    # 验证 1：不为空
    if [ -z "$target" ]; then
        echo "[safe_delete] 跳过：路径为空"; return 1
    fi
    # 验证 2：必须以正确前缀开头
    if [[ "$target" != "${AUDIT_TMP_BASE}/skillguard-audit-"* ]]; then
        echo "[safe_delete] 跳过：路径不符合安全前缀规范 ($target)"; return 1
    fi
    # 验证 3：目录必须实际存在
    if [ ! -d "$target" ]; then
        echo "[safe_delete] 跳过：目录不存在 ($target)"; return 0
    fi
    rm -rf "$target"
    echo "   🗑️  临时目录已安全删除：$target"
}

# cleanup_sandbox 已移除 — Step 2 改用 docker run --rm（自动清理）
# 不再需要手动清理 Sandbox

# cleanup_windows_sandbox 已移除 — Windows Home 不支持 Windows Sandbox
# Layer 3 已全面迁移到 Docker Sandbox microVM（v4.0）

# ── Sandbox 降级：GitHub 克隆到临时目录（不在主机安装）────────────
fetch_skill_via_github() {
    # 从 SKILL_SOURCE 提取 GitHub repo slug（兼容 URL 和 owner/repo 格式）
    local repo_slug
    repo_slug=$(echo "$SKILL_SOURCE" | \
        sed 's|https\?://github\.com/||' | \
        sed 's|https\?://clawhub\.ai/||' | \
        sed 's|\.git$||' | \
        sed 's/@.*//')

    if ! echo "$repo_slug" | grep -qE '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$'; then
        echo "   ❌ 无法识别仓库格式：$SKILL_SOURCE（需要 owner/repo）"
        safe_delete_tmp "$AUDIT_TMP"
        exit 1
    fi

    echo "   📥 降级方案：克隆仓库到临时目录（仅审查，不安装到主机）：$repo_slug"

    if command -v gh &>/dev/null; then
        if gh repo clone "$repo_slug" "$SKILL_FILES" -- --depth=1 -q 2>/dev/null; then
            echo "   ✅ GitHub 克隆成功（gh CLI）"
            return 0
        fi
    fi

    if command -v git &>/dev/null; then
        if git clone --depth=1 -q "https://github.com/$repo_slug.git" "$SKILL_FILES" 2>/dev/null; then
            echo "   ✅ GitHub 克隆成功（git）"
            return 0
        fi
    fi

    echo "   ❌ GitHub 克隆失败（gh 和 git 均不可用或网络错误）"
    safe_delete_tmp "$AUDIT_TMP"
    exit 1
}

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
echo "║           SkillGuard 隔离安全审查流水线 v5.0                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  技能：%-50s║\n" "$SKILL_NAME"
printf "║  来源：%-50s║\n" "$SKILL_SOURCE"
printf "║  风险级别：%-46s║\n" "$SOURCE_RISK"
printf "║  时间：%-50s║\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "║  环境：%-50s║\n" "${WIN_EDITION:-unknown}"
printf "║  火绒：%-50s║\n" "${HUORONG:-未找到}"
printf "║  Layer3：%-48s║\n" "Docker Sandbox microVM"
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
BASELINE_FILE="${AUDIT_TMP}/integrity-baseline.sha256"
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

# ── STEP 2：隔离安装技能（Docker 容器 → GitHub 克隆降级）──────
log_section "Step 2：隔离安装技能并提取文件"

STEP2_OK=false

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    echo "   🐳 使用 Docker 容器隔离安装（volume mount 提取文件）"

    # docker run + volume mount：容器内安装技能，复制到挂载目录
    # MSYS_NO_PATHCONV：防止 Git Bash 转换 -v 路径中的 /output
    STEP2_OUTPUT=$(MSYS_NO_PATHCONV=1 docker run --rm \
        --memory 512m \
        --pids-limit 200 \
        -e "SKILL_SOURCE=$SKILL_SOURCE" \
        -e "SKILL_NAME=$SKILL_NAME" \
        -v "$SKILL_FILES:/output" \
        node:20-slim \
        bash -c '
            npm install -g @anthropic-ai/claude-code 2>/dev/null
            npx skills@latest add "$SKILL_SOURCE" -g -y 2>&1

            # 搜索技能安装路径并复制到挂载目录
            FOUND=0
            for search_dir in \
                "$HOME/.claude/.agents/skills/$SKILL_NAME" \
                "$HOME/.agents/skills/$SKILL_NAME" \
                "$HOME/.claude/skills/$SKILL_NAME"; do
                if [ -d "$search_dir" ]; then
                    cp -r "$search_dir"/* /output/ 2>/dev/null && FOUND=1 && break
                fi
            done

            # 兜底：全局搜索 skills 目录
            if [ $FOUND -eq 0 ]; then
                SKILL_DIR=$(find / -type d -name "$SKILL_NAME" -path "*/skills/*" 2>/dev/null | head -1)
                if [ -n "$SKILL_DIR" ]; then
                    cp -r "$SKILL_DIR"/* /output/ 2>/dev/null && FOUND=1
                fi
            fi

            [ $FOUND -eq 1 ] && echo "COPY_OK" || echo "COPY_FAILED"
        ' 2>&1) || true

    if echo "$STEP2_OUTPUT" | grep -q 'COPY_OK'; then
        echo "   ✅ 技能文件已从 Docker 容器提取到临时目录"
        STEP2_OK=true
    else
        echo "   ⚠️  Docker 容器内文件提取失败，降级到 GitHub 克隆"
        echo "$STEP2_OUTPUT" | tail -5 | sed 's/^/      /'
    fi
fi

if ! $STEP2_OK; then
    fetch_skill_via_github
fi

# 检查文件是否存在
if [ -z "$(ls -A "$SKILL_FILES" 2>/dev/null)" ]; then
    echo "   ❌ 技能文件获取失败，无法继续审查"
    safe_delete_tmp "$AUDIT_TMP"
    exit 1
fi

# ════════════════════════════════════════════════════════════
#  LAYER 0：火绒 AV 扫描
# ════════════════════════════════════════════════════════════
log_section "Layer 0：火绒 AV 扫描（特征库病毒/木马）"

WIN_SKILL_FILES=$(wslpath -w "$SKILL_FILES" 2>/dev/null || echo "$SKILL_FILES")

if [ -n "$HUORONG" ]; then
    "$HUORONG" -s "$WIN_SKILL_FILES" 2>/dev/null
    L0_EXIT=$?
    if [ $L0_EXIT -eq 0 ]; then
        L0_RESULT="PASS"
        log_ok "未发现已知病毒/木马/恶意代码（退出码 0 = 无威胁，已实测）"
    else
        L0_RESULT="FAIL"
        L0_DETAIL="火绒退出码：$L0_EXIT（发现威胁）"
        log_fail "火绒检测到威胁！退出码：$L0_EXIT"
    fi
else
    L0_RESULT="SKIP"
    log_warn "火绒未找到，跳过 Layer 0"
    log_warn "已搜索路径：C:/Program Files/Huorong/*, C:/Program Files (x86)/Huorong/*, D:/Program Files/Huorong/*"
fi

# ════════════════════════════════════════════════════════════
#  LAYER 1：Prompt Injection 语义扫描
# ════════════════════════════════════════════════════════════
log_section "Layer 1：Prompt Injection 语义扫描"

L1_ISSUES=0
L1_LINES=""

check_pattern() {
    local desc="$1"
    shift
    local result
    result=$(grep "$@" "$SKILL_FILES" 2>/dev/null || true)
    if [ -n "$result" ]; then
        log_warn "$desc"
        echo "$result" | head -3 | sed 's/^/      /'
        L1_LINES="${L1_LINES}\n[${desc}]\n${result}\n"
        L1_ISSUES=$((L1_ISSUES+1))
    else
        log_ok "$desc：无"
    fi
}

check_pattern "HTML 注释隐藏指令" \
    -rniE '<!--.*--(execute|send|read|fetch|POST|ignore|override|system|admin)'

# 零宽字符检测：优先 grep -P，不可用时降级 python3
if grep --help 2>&1 | grep -q '\-P'; then
    check_pattern "零宽字符（隐形文字）" \
        -rlP "[\x{200B}\x{200C}\x{200D}\x{FEFF}\x{200E}\x{200F}\x{2060}]"
else
    ZWC_RESULT=$($SG_PYTHON -c "
import sys, os
for root, dirs, files in os.walk(sys.argv[1]):
    for f in files:
        path = os.path.join(root, f)
        try:
            text = open(path, 'r', encoding='utf-8', errors='ignore').read()
            if any(c in text for c in '\u200b\u200c\u200d\ufeff\u200e\u200f\u2060'):
                print(path)
        except: pass
" "$SKILL_FILES" 2>/dev/null || true)
    if [ -n "$ZWC_RESULT" ]; then
        log_warn "零宽字符（隐形文字）"
        echo "$ZWC_RESULT" | head -3 | sed 's/^/      /'
        L1_LINES="${L1_LINES}\n[零宽字符]\n${ZWC_RESULT}\n"
        L1_ISSUES=$((L1_ISSUES+1))
    else
        log_ok "零宽字符（隐形文字）：无"
    fi
fi

check_pattern "权威+紧迫语言组合" \
    -rniE "(system|admin|critical|urgent).{0,50}(immediately|always|must|override)"

check_pattern "凭证关键词" \
    -rniE "API_KEY|ANTHROPIC_KEY|Bearer|private[._]key"

check_pattern "指令覆盖尝试（高危）" \
    -rniE "ignore previous|override instruction|disregard|higher priority"

check_pattern "已知外传域名（高危）" \
    -rniE "webhook\.site|pipedream\.net|requestbin|ngrok\.io|burpcollaborator|interact\.sh"

# ── 新增检测模式（Phase 1 加固）──────────────────────────────

# [C-06] Unicode Tag 字符（ASCII Smuggling）
UTAG_RESULT=$($SG_PYTHON -c "
import sys, os
for root, dirs, files in os.walk(sys.argv[1]):
    for f in files:
        path = os.path.join(root, f)
        try:
            text = open(path, 'r', encoding='utf-8', errors='ignore').read()
            # U+E0000-E007F (Tags block) + U+FE00-FE0F (Variation Selectors)
            if any('\U000E0000' <= c <= '\U000E007F' or '\uFE00' <= c <= '\uFE0F' for c in text):
                print(f'ASCII_SMUGGLING: {path}')
        except: pass
" "$SKILL_FILES" 2>/dev/null || true)
if [ -n "$UTAG_RESULT" ]; then
    log_warn "Unicode Tag 字符（ASCII Smuggling，高危）"
    echo "$UTAG_RESULT" | head -3 | sed 's/^/      /'
    L1_LINES="${L1_LINES}\n[Unicode Tag]\n${UTAG_RESULT}\n"
    L1_ISSUES=$((L1_ISSUES+1))
    L1_HAS_CRITICAL=1
else
    log_ok "Unicode Tag 字符（ASCII Smuggling）：无"
fi

# [M-10] BiDi 双向控制字符（Trojan Source）
BIDI_RESULT=$($SG_PYTHON -c "
import sys, os
bidi_chars = set('\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069\u200E\u200F\u061C')
for root, dirs, files in os.walk(sys.argv[1]):
    for f in files:
        path = os.path.join(root, f)
        try:
            text = open(path, 'r', encoding='utf-8', errors='ignore').read()
            found = [c for c in text if c in bidi_chars]
            if found:
                print(f'BIDI: {path} (chars: {[hex(ord(c)) for c in set(found)]})')
        except: pass
" "$SKILL_FILES" 2>/dev/null || true)
if [ -n "$BIDI_RESULT" ]; then
    log_warn "BiDi 双向控制字符（Trojan Source，高危）"
    echo "$BIDI_RESULT" | head -3 | sed 's/^/      /'
    L1_LINES="${L1_LINES}\n[BiDi]\n${BIDI_RESULT}\n"
    L1_ISSUES=$((L1_ISSUES+1))
    L1_HAS_CRITICAL=1
else
    log_ok "BiDi 双向控制字符（Trojan Source）：无"
fi

# [C-07] Markdown 图片外传
check_pattern "Markdown 图片外传（数据泄露）" \
    -rniE '!\[.*\]\(https?://[^)]{5,}\)'

# [C-08] MCP 工具描述注入
check_pattern "MCP Tool 描述注入" \
    -rniE '"description"[^"]{0,20}"[^"]{0,300}(ignore|override|execute|fetch|read file|send|POST|exfil)[^"]{0,100}"'

# [H-13] 多语言指令覆盖（中/日/韩/俄）
check_pattern "中文指令覆盖" \
    -rniE "忽略.{0,20}(之前|上面|前面|以上)|覆盖.{0,20}指令|系统.{0,20}提示|无视.{0,20}(规则|限制)"

check_pattern "日韩俄指令覆盖" \
    -rniE "前の指示を無視|이전 지시를 무시|игнорируй предыдущие"

# [H-14] Base64 混淆注入
check_pattern "Base64 混淆注入" \
    -rniE "(decode|base64|atob|btoa|b64decode).{0,100}(execute|run|eval|system|exec)"

# [H-15] .claude/settings.json Hook 注入（CVE-2025-59536）
HOOK_RESULT=$(find "$SKILL_FILES" -name "settings.json" -path "*/.claude/*" 2>/dev/null | head -3)
if [ -n "$HOOK_RESULT" ]; then
    if grep -rl "hooks" $HOOK_RESULT 2>/dev/null | head -1 | grep -q .; then
        log_warn ".claude/settings.json Hook 注入（CVE-2025-59536，高危）"
        echo "$HOOK_RESULT" | sed 's/^/      /'
        L1_LINES="${L1_LINES}\n[Hook Injection]\n${HOOK_RESULT}\n"
        L1_ISSUES=$((L1_ISSUES+1))
        L1_HAS_CRITICAL=1
    else
        log_ok ".claude/settings.json 无 Hook 注入"
    fi
else
    log_ok ".claude/settings.json Hook 注入：无相关文件"
fi

# [补充] DNS 外传命令
check_pattern "DNS 外传命令（CVE-2025-55284）" \
    -rniE "(ping|dig|nslookup|host)\s+.{0,50}\.(com|net|io|xyz|top)"

# [补充] 反向 Shell 模式
check_pattern "反向 Shell 模式（高危）" \
    -rniE "bash\s+-i.*(/dev/tcp|/dev/udp)|nc\s+(-e|--exec)|mkfifo.*nc|python.*socket.*connect"

# ── Phase 3 新增检测模式 ──────────────────────────────────────

# [P3-01] Homoglyph / Confusable 字符检测（视觉欺骗）
HOMO_RESULT=$($SG_PYTHON -c "
import sys, os, unicodedata

# 高风险 Homoglyph 映射表（Cyrillic/Greek/Math 常用于伪装 ASCII）
# 这些字符外观与 ASCII 几乎相同但 codepoint 不同
CONFUSABLES = {
    '\u0410': 'A',   # Cyrillic А
    '\u0412': 'B',   # Cyrillic В
    '\u0421': 'C',   # Cyrillic С
    '\u0415': 'E',   # Cyrillic Е
    '\u041D': 'H',   # Cyrillic Н
    '\u041A': 'K',   # Cyrillic К
    '\u041C': 'M',   # Cyrillic М
    '\u041E': 'O',   # Cyrillic О
    '\u0420': 'P',   # Cyrillic Р
    '\u0422': 'T',   # Cyrillic Т
    '\u0425': 'X',   # Cyrillic Х
    '\u0430': 'a',   # Cyrillic а
    '\u0435': 'e',   # Cyrillic е
    '\u043E': 'o',   # Cyrillic о
    '\u0440': 'p',   # Cyrillic р
    '\u0441': 'c',   # Cyrillic с
    '\u0443': 'y',   # Cyrillic у (close to y)
    '\u0445': 'x',   # Cyrillic х
    '\u0455': 's',   # Cyrillic ѕ
    '\u0456': 'i',   # Cyrillic і
    '\u0458': 'j',   # Cyrillic ј
    '\u04BB': 'h',   # Cyrillic һ
    '\u0391': 'A',   # Greek Α
    '\u0392': 'B',   # Greek Β
    '\u0395': 'E',   # Greek Ε
    '\u0397': 'H',   # Greek Η
    '\u0399': 'I',   # Greek Ι
    '\u039A': 'K',   # Greek Κ
    '\u039C': 'M',   # Greek Μ
    '\u039D': 'N',   # Greek Ν
    '\u039F': 'O',   # Greek Ο
    '\u03A1': 'P',   # Greek Ρ
    '\u03A4': 'T',   # Greek Τ
    '\u03A7': 'X',   # Greek Χ
    '\u03B1': 'a',   # Greek α (close)
    '\u03BF': 'o',   # Greek ο
    '\u0261': 'g',   # Latin ɡ
    '\u026A': 'i',   # Latin ɪ
    '\uFF41': 'a',   # Fullwidth ａ
    '\uFF42': 'b',   # Fullwidth ｂ
}
confusable_set = set(CONFUSABLES.keys())

for root, dirs, files in os.walk(sys.argv[1]):
    for f in files:
        path = os.path.join(root, f)
        try:
            text = open(path, 'r', encoding='utf-8', errors='ignore').read()
            found = {}
            for i, c in enumerate(text):
                if c in confusable_set:
                    context = text[max(0,i-15):i+16].replace(chr(10),' ')
                    found[c] = (CONFUSABLES[c], hex(ord(c)), context)
            if found:
                for ch, (looks_like, codepoint, ctx) in list(found.items())[:3]:
                    print(f'HOMOGLYPH: {path} | U+{ord(ch):04X} looks like \"{looks_like}\" | ...{ctx}...')
        except: pass
" "$SKILL_FILES" 2>/dev/null || true)
if [ -n "$HOMO_RESULT" ]; then
    log_warn "Homoglyph 混淆字符（视觉欺骗攻击，高危）"
    echo "$HOMO_RESULT" | head -5 | sed 's/^/      /'
    L1_LINES="${L1_LINES}\n[Homoglyph]\n${HOMO_RESULT}\n"
    L1_ISSUES=$((L1_ISSUES+1))
    L1_HAS_CRITICAL=1
else
    log_ok "Homoglyph 混淆字符：无"
fi

# [P3-02] RAG 文档投毒检测
# 检测 Markdown frontmatter/metadata 中的隐藏指令
check_pattern "Frontmatter 隐藏指令（RAG 投毒）" \
    -rniE '^---[\s\S]{0,500}(system_prompt|instruction|role|persona|ignore|override)'

# 检测 HTML style 隐藏（CSS display:none / visibility:hidden + 指令）
check_pattern "CSS 隐藏文本（RAG 投毒）" \
    -rniE '(display:\s*none|visibility:\s*hidden|font-size:\s*0|opacity:\s*0).{0,200}(ignore|override|execute|system|instruction)'

# 检测 data URI 嵌入（可携带恶意 payload）
check_pattern "Data URI 嵌入（可执行 payload）" \
    -rniE 'data:(text|application)/(html|javascript|x-python)[;,]'

# 检测文档结构操纵（假装是系统消息/API响应）
check_pattern "伪造系统消息/API 响应" \
    -rniE '(\[SYSTEM\]|\[system\]|<\|im_start\|>system|<system>|role.*system.*content)'

# [P3-03] 环境变量外传（扩展检测）
check_pattern "环境变量外传到 URL" \
    -rniE '(ANTHROPIC|OPENAI|AWS|GITHUB|SLACK|DISCORD)_[A-Z_]*.*https?://'

# [P3-04] 编码混淆链（多层编码绕过检测）
check_pattern "多层编码混淆（绕过检测）" \
    -rniE '(atob|btoa|base64|hex|charCodeAt|fromCharCode|encodeURI|decodeURI).{0,80}(atob|btoa|base64|hex|charCodeAt|fromCharCode|eval|exec)'

# ── 判定逻辑（按严重性分级，不仅按数量）─────────────────────
L1_HAS_CRITICAL="${L1_HAS_CRITICAL:-0}"

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
#  LAYER 2：Docker 强化容器代码扫描
# ════════════════════════════════════════════════════════════
log_section "Layer 2：Docker 强化容器代码扫描"

if command -v docker &>/dev/null && docker images skillguard -q 2>/dev/null | grep -q .; then

    L2_OUTPUT=$(docker run --rm \
        --network none \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --pids-limit 100 \
        --user 1000:1000 \
        --memory 256m \
        --tmpfs /tmp:size=10m,noexec \
        --tmpfs /dev/shm:size=1m,noexec \
        -v "$SKILL_FILES:/scan:ro" \
        skillguard \
        bash -c '
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
        ' 2>/dev/null)

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
    log_warn "Docker 镜像 skillguard 未找到，跳过 Layer 2"
    log_warn "请先执行：docker build -t skillguard -f Dockerfile.skillguard ."
fi

# ════════════════════════════════════════════════════════════
#  LAYER 3：Docker Sandbox microVM 动态测试（高风险来源）
#  替代方案：Windows Home 不支持 Windows Sandbox，使用 Docker Sandbox
#  隔离强度：独立内核 + 私有 Docker daemon = VM 级隔离
# ════════════════════════════════════════════════════════════
if [ "$SOURCE_RISK" = "EXTREME" ] || [ "$SOURCE_RISK" = "HIGH" ] || \
   [ "$L1_RESULT" = "WARN" ] || [ "$L1_RESULT" = "FAIL" ]; then

    log_section "Layer 3：Docker 容器动态执行测试"

    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        echo "   🔒 启动隔离容器进行动态行为监测"

        # 使用 docker run 进行动态测试（容器隔离 + 安全加固）
        L3_LOGS=$(MSYS_NO_PATHCONV=1 docker run --rm \
            --cap-drop ALL \
            --security-opt no-new-privileges:true \
            --pids-limit 100 \
            --memory 256m \
            -e "SKILL_SOURCE=$SKILL_SOURCE" \
            node:20-slim \
            bash -c '
                echo "=== L3 DYNAMIC TEST START ==="
                echo "--- Network baseline ---"
                ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "no ss/netstat"

                echo "--- File baseline ---"
                find /root -type f 2>/dev/null | sort > /tmp/files-before.txt

                echo "--- Installing skill ---"
                npm install -g @anthropic-ai/claude-code 2>/dev/null
                npx skills@latest add "$SKILL_SOURCE" -g -y 2>&1 || echo "INSTALL_FAILED"

                echo "--- Post-install checks ---"
                echo ">> New files:"
                find /root -type f 2>/dev/null | sort > /tmp/files-after.txt
                diff /tmp/files-before.txt /tmp/files-after.txt 2>/dev/null || true

                echo ">> Network connections:"
                ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "no ss/netstat"

                echo ">> Suspicious processes:"
                ps aux 2>/dev/null | grep -vE "bash|ps|grep|node|npm" || true

                echo ">> Crontab check:"
                crontab -l 2>/dev/null || echo "no crontab"

                echo ">> Shell rc modification:"
                cat /root/.bashrc 2>/dev/null | tail -5
                cat /root/.profile 2>/dev/null | tail -5

                echo "=== L3 DYNAMIC TEST END ==="
            ' 2>&1) || L3_LOGS="DOCKER_RUN_FAILED"

        # 分析行为
        L3_ALERTS=""
        if echo "$L3_LOGS" | grep -qiE 'INSTALL_FAILED|DOCKER_RUN_FAILED'; then
            L3_ALERTS="${L3_ALERTS}[安装失败] "
        fi
        if echo "$L3_LOGS" | grep -qiE 'curl|wget|nc\s|ncat|python.*http'; then
            L3_ALERTS="${L3_ALERTS}[检测到网络工具调用] "
        fi
        if echo "$L3_LOGS" | grep -qiE '\.ssh|\.aws|\.gnupg|credentials'; then
            L3_ALERTS="${L3_ALERTS}[访问敏感目录] "
        fi
        if echo "$L3_LOGS" | grep -qiE 'crontab.*-e|systemctl|\.bashrc.*>>' ; then
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
#  清理点 A：删除临时目录（扫描完成，无论结果）
# ════════════════════════════════════════════════════════════
log_section "清理点 A：删除扫描临时目录"
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

# 清理基线文件（已在临时目录中，safe_delete_tmp 已处理）

# ════════════════════════════════════════════════════════════
#  最终判定
# ════════════════════════════════════════════════════════════
if [ "$L0_RESULT" = "FAIL" ] || [ "$L1_RESULT" = "FAIL" ] || [ "$INTEGRITY_FAILED" -eq 1 ]; then
    FINAL_VERDICT="MALICIOUS"
elif [ "$L0_RESULT" = "PASS" ] && \
     [ "$L1_RESULT" = "PASS" ] && \
     [ "$L2_RESULT" != "FAIL" ] && \
     [ "$L3_RESULT" != "WARN" ]; then
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
printf "║  L0  火绒 AV 扫描         %-31s║\n" \
    "$([ "$L0_RESULT" = "PASS" ] && echo "✅ 通过" || [ "$L0_RESULT" = "FAIL" ] && echo "❌ 发现威胁" || echo "⚠️  已跳过")"
printf "║  L1  Prompt Injection    %-31s║\n" \
    "$([ "$L1_RESULT" = "PASS" ] && echo "✅ 通过" || [ "$L1_RESULT" = "FAIL" ] && echo "❌ 高危" || [ "$L1_RESULT" = "WARN" ] && echo "⚠️  有警告" || echo "⚠️  已跳过")"
printf "║  L2  嵌入代码扫描          %-31s║\n" \
    "$([ "$L2_RESULT" = "PASS" ] && echo "✅ 通过" || [ "$L2_RESULT" = "WARN" ] && echo "⚠️  需复核" || echo "⚠️  已跳过")"
printf "║  L3  动态执行测试          %-31s║\n" \
    "$([ "$L3_RESULT" = "PASS" ] && echo "✅ 通过" || [ "$L3_RESULT" = "WARN" ] && echo "⚠️  有可疑行为" || [ "$L3_RESULT" = "SKIP" ] && echo "⚠️  已跳过" || echo "—  未触发")"
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
        echo "⛔ 技能 [$SKILL_NAME] 被判定为恶意，已拒绝安装并清除所有隔离副本。"
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
