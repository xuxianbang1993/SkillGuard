#!/bin/bash
# 一键配置.sh — SkillGuard 一键配置脚本
# 用法：git clone https://github.com/xuxianbang1993/SkillGuard.git && cd SkillGuard && bash 一键配置.sh
#
# 功能：
#   1. 环境检测（Docker / Docker Sandbox / 火绒 / Python3 / Claude Code）
#   2. 自动构建 Docker 扫描镜像
#   3. 将 Hook 配置合并写入 ~/.claude/settings.json（不覆盖已有配置）
#   4. 验证安装结果 + 环境评分

set -uo pipefail

# ── 非交互模式（--yes / -y）────────────────────────────────
AUTO_YES=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_YES=1 ;;
    esac
done

# ── 颜色输出 ────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_ok()   { echo -e "   ${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "   ${YELLOW}⚠️  $1${NC}"; }
log_fail() { echo -e "   ${RED}❌ $1${NC}"; }
log_info() { echo -e "   ${CYAN}ℹ️  $1${NC}"; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           SkillGuard 一键配置                             ║"
echo "║           Claude Code 技能安装安全审查流水线               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1：确定 SkillGuard 脚本路径 ──────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 验证关键文件存在
MISSING=0
for f in skillguard-gate.sh skillguard-audit.sh skillguard-write.sh Dockerfile.skillguard; do
    if [ ! -f "$SCRIPT_DIR/$f" ]; then
        log_fail "找不到 $f"
        MISSING=$((MISSING+1))
    fi
done
if [ $MISSING -gt 0 ]; then
    log_fail "请确认在 SkillGuard 目录下运行此脚本"
    exit 1
fi

# 统一为正斜杠路径（兼容 Windows Git Bash）
SG_PATH=$(echo "$SCRIPT_DIR" | tr '\\' '/')
log_ok "SkillGuard 路径：$SG_PATH"

# ════════════════════════════════════════════════════════════
#  Step 2：环境检测
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━ Step 1/4：环境检测 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ENV_SCORE=0
ENV_TOTAL=0
WARNINGS=""

# ── 2.1 操作系统 ──────────────────────────────────────────────
ENV_TOTAL=$((ENV_TOTAL+1))
OS_INFO="unknown"
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "win32" ]]; then
    OS_INFO="Windows"
    if command -v powershell.exe &>/dev/null; then
        WIN_EDITION=$(powershell.exe -NoProfile -Command \
            "(Get-CimInstance Win32_OperatingSystem).Caption" 2>/dev/null | tr -d '\r' || echo "")
        if [ -n "$WIN_EDITION" ]; then
            OS_INFO="$WIN_EDITION"
        fi
    fi
    log_ok "操作系统：$OS_INFO"
    ENV_SCORE=$((ENV_SCORE+1))

    # 检查 Windows Sandbox 支持
    if echo "$OS_INFO" | grep -qi "home"; then
        log_info "Windows 家庭版不支持 Windows Sandbox（已用 Docker Sandbox 替代）"
    fi
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS_INFO="Linux ($(uname -r 2>/dev/null || echo 'unknown'))"
    log_ok "操作系统：$OS_INFO"
    ENV_SCORE=$((ENV_SCORE+1))
elif [[ "$OSTYPE" == "darwin"* ]]; then
    OS_INFO="macOS ($(sw_vers -productVersion 2>/dev/null || echo 'unknown'))"
    log_ok "操作系统：$OS_INFO"
    ENV_SCORE=$((ENV_SCORE+1))
else
    log_warn "操作系统：$OSTYPE（未测试）"
fi

# ── 2.2 Claude Code ──────────────────────────────────────────
ENV_TOTAL=$((ENV_TOTAL+1))
if [ -d "$HOME/.claude" ]; then
    log_ok "Claude Code：已安装（~/.claude 存在）"
    ENV_SCORE=$((ENV_SCORE+1))
else
    log_warn "Claude Code：未检测到 ~/.claude 目录"
    log_info "Hook 配置将在首次启动 Claude Code 后生效"
fi

# ── 2.3 Docker ────────────────────────────────────────────────
ENV_TOTAL=$((ENV_TOTAL+1))
DOCKER_OK=0
DOCKER_VER=""
if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version 2>/dev/null | head -1 || echo "")
    if docker info &>/dev/null; then
        log_ok "Docker：$DOCKER_VER（运行中）"
        DOCKER_OK=1
        ENV_SCORE=$((ENV_SCORE+1))

        # CVE 版本检查
        DESKTOP_VER=$(docker info --format '{{index .Labels "com.docker.desktop.version"}}' 2>/dev/null || echo "")
        if [ -n "$DESKTOP_VER" ]; then
            # 简单版本比较
            MAJOR=$(echo "$DESKTOP_VER" | cut -d. -f1)
            MINOR=$(echo "$DESKTOP_VER" | cut -d. -f2)
            PATCH=$(echo "$DESKTOP_VER" | cut -d. -f3)
            if [ "${MAJOR:-0}" -lt 4 ] || ([ "${MAJOR:-0}" -eq 4 ] && [ "${MINOR:-0}" -lt 44 ]); then
                log_warn "Docker Desktop $DESKTOP_VER < 4.44.3 — CVE-2025-9074（本地 API 暴露）"
                WARNINGS="${WARNINGS}\n- Docker Desktop 版本过低，建议升级到 ≥ 4.44.3"
            fi
        fi
    else
        log_warn "Docker：已安装但未运行 — 请启动 Docker Desktop"
        WARNINGS="${WARNINGS}\n- Docker 未运行，Layer 2/3 不可用"
    fi
else
    log_fail "Docker：未安装"
    log_info "Layer 2（容器代码扫描）和 Layer 3（microVM 动态测试）需要 Docker"
    log_info "安装：https://docs.docker.com/desktop/"
    WARNINGS="${WARNINGS}\n- Docker 未安装，Layer 2/3 完全不可用（仅 Layer 0/1 工作）"
fi

# ── 2.4 Docker Sandbox（microVM）──────────────────────────────
ENV_TOTAL=$((ENV_TOTAL+1))
SANDBOX_OK=0
if [ $DOCKER_OK -eq 1 ]; then
    if docker sandbox ls &>/dev/null 2>&1; then
        log_ok "Docker Sandbox：可用（microVM 隔离）"
        SANDBOX_OK=1
        ENV_SCORE=$((ENV_SCORE+1))
    else
        log_warn "Docker Sandbox：不可用"
        log_info "需要 Docker Desktop ≥ 4.44.3 且启用 Sandbox 功能"
        log_info "验证：docker sandbox ls"
        WARNINGS="${WARNINGS}\n- Docker Sandbox 不可用，技能审查将无法运行（硬性依赖）"
    fi
else
    log_warn "Docker Sandbox：跳过（Docker 未就绪）"
fi

# ── 2.5 Docker 扫描镜像 ──────────────────────────────────────
ENV_TOTAL=$((ENV_TOTAL+1))
IMAGE_OK=0
if [ $DOCKER_OK -eq 1 ]; then
    if docker images skillguard -q 2>/dev/null | grep -q .; then
        log_ok "Docker 扫描镜像：skillguard（已构建）"
        IMAGE_OK=1
        ENV_SCORE=$((ENV_SCORE+1))
    else
        log_warn "Docker 扫描镜像：skillguard 未构建（Layer 2 需要）"
        echo ""
        echo -e "   ${CYAN}是否现在构建 Docker 扫描镜像？（约 1-2 分钟）${NC}"
        echo -e "   ${CYAN}命令：docker build -t skillguard -f Dockerfile.skillguard .${NC}"
        if [ $AUTO_YES -eq 1 ]; then
            BUILD_CHOICE="Y"
            echo "   构建？[Y/n] Y（--yes 自动确认）"
        else
            read -p "   构建？[Y/n] " BUILD_CHOICE
        fi
        if [[ "${BUILD_CHOICE:-Y}" =~ ^[Yy]$ ]] || [ -z "$BUILD_CHOICE" ]; then
            echo ""
            echo "   正在构建 skillguard 镜像..."
            if docker build -t skillguard -f "$SCRIPT_DIR/Dockerfile.skillguard" "$SCRIPT_DIR" 2>&1 | tail -3; then
                log_ok "Docker 扫描镜像构建成功"
                IMAGE_OK=1
                ENV_SCORE=$((ENV_SCORE+1))
            else
                log_fail "Docker 扫描镜像构建失败"
                WARNINGS="${WARNINGS}\n- Docker 镜像构建失败，Layer 2 不可用"
            fi
        else
            log_info "跳过。后续可手动执行：docker build -t skillguard -f Dockerfile.skillguard ."
            WARNINGS="${WARNINGS}\n- Docker 镜像未构建，Layer 2 不可用"
        fi
    fi
else
    log_warn "Docker 扫描镜像：跳过（Docker 未就绪）"
fi

# ── 2.6 火绒杀毒软件（Windows 专用 Layer 0）─────────────────
ENV_TOTAL=$((ENV_TOTAL+1))
HUORONG_OK=0
HUORONG_PATH=""

# 检测是否为 Windows 环境
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || command -v powershell.exe &>/dev/null; then
    HUORONG_CANDIDATES=(
        "C:/Program Files/Huorong/Sysdiag/bin/HipsMain.exe"
        "C:/Program Files (x86)/Huorong/Sysdiag/bin/HipsMain.exe"
        "D:/Program Files/Huorong/Sysdiag/bin/HipsMain.exe"
        "D:/Program Files (x86)/Huorong/Sysdiag/bin/HipsMain.exe"
    )
    for candidate in "${HUORONG_CANDIDATES[@]}"; do
        if [ -f "$candidate" ]; then
            HUORONG_PATH="$candidate"
            break
        fi
        # 尝试 wslpath 转换
        wsl_candidate=$(wslpath "$candidate" 2>/dev/null || echo "")
        if [ -n "$wsl_candidate" ] && [ -f "$wsl_candidate" ]; then
            HUORONG_PATH="$candidate"
            break
        fi
    done

    if [ -n "$HUORONG_PATH" ]; then
        log_ok "火绒杀毒：已安装（$HUORONG_PATH）"
        HUORONG_OK=1
        ENV_SCORE=$((ENV_SCORE+1))
    else
        log_warn "火绒杀毒：未找到"
        log_info "Layer 0（传统 AV 扫描）将跳过"
        log_info "已搜索：C/D 盘 Program Files 下的 Huorong 目录"
        log_info "如使用其他杀毒软件，Layer 0 会自动跳过（不影响 Layer 1-3）"
        WARNINGS="${WARNINGS}\n- 火绒未找到，Layer 0 跳过（Layer 1-3 不受影响）"
    fi
else
    log_info "火绒杀毒：非 Windows 环境，Layer 0 跳过"
    log_info "Layer 1-3 在所有平台均可用"
    ENV_SCORE=$((ENV_SCORE+1))  # 非 Windows 不需要火绒
fi

# ── 2.7 Python ───────────────────────────────────────────────
ENV_TOTAL=$((ENV_TOTAL+1))
PYTHON_OK=0
PYTHON_CMD=""
# 注意：Windows 的 python3 可能是 Microsoft Store 重定向 stub（AppInstallerPythonRedirector.exe）
# 该 stub 会返回 exit code 49 而不是执行 Python，必须用 --version 验证真实可用性
for candidate in python3 python; do
    if command -v "$candidate" &>/dev/null; then
        if "$candidate" --version &>/dev/null; then
            PYTHON_CMD="$candidate"
            break
        fi
    fi
done

if [ -n "$PYTHON_CMD" ]; then
    PY_VER=$($PYTHON_CMD --version 2>&1 || echo "unknown")
    log_ok "Python：$PY_VER（命令：$PYTHON_CMD）"
    PYTHON_OK=1
    ENV_SCORE=$((ENV_SCORE+1))
else
    log_warn "Python：未安装"
    log_info "以下检测将降级或跳过：零宽字符、Unicode Tag、BiDi、Homoglyph"
    WARNINGS="${WARNINGS}\n- Python3 未安装，部分 Layer 1 高级检测降级"
fi

# ── 2.8 Node.js ──────────────────────────────────────────────
ENV_TOTAL=$((ENV_TOTAL+1))
if command -v node &>/dev/null; then
    NODE_VER=$(node --version 2>/dev/null || echo "unknown")
    log_ok "Node.js：$NODE_VER"
    ENV_SCORE=$((ENV_SCORE+1))
    # 检查版本
    NODE_MAJOR=$(echo "$NODE_VER" | tr -d 'v' | cut -d. -f1)
    if [ "${NODE_MAJOR:-0}" -lt 20 ]; then
        log_warn "Node.js $NODE_VER < 20（建议使用 LTS 版本）"
    fi
else
    log_warn "Node.js：未安装（技能安装需要 npx）"
    WARNINGS="${WARNINGS}\n- Node.js 未安装，无法执行技能安装命令"
fi

# ── 环境检测汇总 ──────────────────────────────────────────────
echo ""
echo "┌── 环境检测结果 ────────────────────────────────────────────┐"
echo -e "│  得分：${BOLD}$ENV_SCORE / $ENV_TOTAL${NC}"

if [ $ENV_SCORE -eq $ENV_TOTAL ]; then
    echo -e "│  ${GREEN}状态：所有组件就绪，SkillGuard 可以满功率运行${NC}"
elif [ $ENV_SCORE -ge $((ENV_TOTAL - 2)) ]; then
    echo -e "│  ${YELLOW}状态：大部分组件就绪，部分 Layer 可能降级${NC}"
else
    echo -e "│  ${RED}状态：多个组件缺失，建议先安装依赖${NC}"
fi

# 显示各 Layer 可用性
echo "│"
L0_STATUS="✅"; [ $HUORONG_OK -eq 0 ] && [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]] && L0_STATUS="⚠️  跳过"
L1_STATUS="✅"; [ $PYTHON_OK -eq 0 ] && L1_STATUS="⚠️  降级"
L2_STATUS="✅"; [ $IMAGE_OK -eq 0 ] && L2_STATUS="❌ 不可用"
L3_STATUS="✅"; [ $SANDBOX_OK -eq 0 ] && L3_STATUS="❌ 不可用"

echo "│  Layer 0 火绒 AV 扫描      $L0_STATUS"
echo "│  Layer 1 语义扫描 (24+项)   $L1_STATUS"
echo "│  Layer 2 Docker 代码扫描    $L2_STATUS"
echo "│  Layer 3 microVM 动态测试   $L3_STATUS"

if [ -n "$WARNINGS" ]; then
    echo "│"
    echo "│  待解决："
    echo -e "$WARNINGS" | while read -r line; do
        [ -n "$line" ] && echo "│  $line"
    done
fi
echo "└──────────────────────────────────────────────────────────┘"

# ════════════════════════════════════════════════════════════
#  Step 3：配置 Hook
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━ Step 2/4：配置 Claude Code Hook ━━━━━━━━━━━━━━━━━━━━━"
echo ""

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
mkdir -p "$CLAUDE_DIR" 2>/dev/null || true

GATE_CMD="bash $SG_PATH/skillguard-gate.sh"
WRITE_CMD="bash $SG_PATH/skillguard-write.sh"

# 确定 Python 命令（验证真实可用，排除 Windows Store stub）
PY_CMD=""
for candidate in python3 python; do
    if command -v "$candidate" &>/dev/null && "$candidate" --version &>/dev/null; then
        PY_CMD="$candidate"
        break
    fi
done

if [ -n "$PY_CMD" ]; then
    $PY_CMD -c "
import json, os, sys

settings_file = sys.argv[1]
gate_cmd = sys.argv[2]
write_cmd = sys.argv[3]

settings = {}
if os.path.exists(settings_file):
    try:
        with open(settings_file, 'r', encoding='utf-8') as f:
            settings = json.load(f)
    except (json.JSONDecodeError, IOError):
        backup = settings_file + '.bak'
        os.rename(settings_file, backup)
        print(f'⚠️  原 settings.json 格式错误，已备份到 {backup}')
        settings = {}

sg_hooks = {
    'PreToolUse': [
        {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': gate_cmd, 'timeout': 300000}]},
        {'matcher': 'Write', 'hooks': [{'type': 'command', 'command': write_cmd}]},
        {'matcher': 'Edit', 'hooks': [{'type': 'command', 'command': write_cmd}]}
    ]
}

if 'hooks' not in settings:
    settings['hooks'] = {}

existing_pre = settings.get('hooks', {}).get('PreToolUse', [])
has_skillguard = any('skillguard' in str(h).lower() for h in existing_pre)

if has_skillguard:
    print('SkillGuard hooks 已存在，更新路径...')

other_hooks = [h for h in existing_pre if 'skillguard' not in str(h).lower()]
settings['hooks']['PreToolUse'] = sg_hooks['PreToolUse'] + other_hooks

with open(settings_file, 'w', encoding='utf-8') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)

print('OK')
" "$SETTINGS_FILE" "$GATE_CMD" "$WRITE_CMD"

    if [ $? -eq 0 ]; then
        log_ok "Hook 配置已写入 $SETTINGS_FILE"
    else
        log_fail "配置写入失败"
        exit 1
    fi

elif command -v jq &>/dev/null; then
    if [ -f "$SETTINGS_FILE" ]; then
        TMP_FILE=$(mktemp)
        jq --arg gate "$GATE_CMD" --arg write "$WRITE_CMD" '
            .hooks.PreToolUse = [
                {"matcher": "Bash", "hooks": [{"type": "command", "command": $gate}]},
                {"matcher": "Write", "hooks": [{"type": "command", "command": $write}]},
                {"matcher": "Edit", "hooks": [{"type": "command", "command": $write}]}
            ] + ([.hooks.PreToolUse[]? | select(.hooks[0].command | test("skillguard"; "i") | not)] // [])
        ' "$SETTINGS_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$SETTINGS_FILE"
        log_ok "Hook 配置已合并到 $SETTINGS_FILE"
    else
        jq -n --arg gate "$GATE_CMD" --arg write "$WRITE_CMD" '{
            hooks: {
                PreToolUse: [
                    {matcher: "Bash", hooks: [{type: "command", command: $gate}]},
                    {matcher: "Write", hooks: [{type: "command", command: $write}]},
                    {matcher: "Edit", hooks: [{type: "command", command: $write}]}
                ]
            }
        }' > "$SETTINGS_FILE"
        log_ok "Hook 配置已创建 $SETTINGS_FILE"
    fi
else
    if [ -f "$SETTINGS_FILE" ]; then
        log_warn "检测到已有 $SETTINGS_FILE，但无 python3/jq 无法安全合并"
        log_warn "请手动将以下内容合并到 $SETTINGS_FILE："
        echo ""
        echo "  \"hooks\": {"
        echo "    \"PreToolUse\": ["
        echo "      {\"matcher\": \"Bash\", \"hooks\": [{\"type\": \"command\", \"command\": \"$GATE_CMD\"}]},"
        echo "      {\"matcher\": \"Write\", \"hooks\": [{\"type\": \"command\", \"command\": \"$WRITE_CMD\"}]},"
        echo "      {\"matcher\": \"Edit\", \"hooks\": [{\"type\": \"command\", \"command\": \"$WRITE_CMD\"}]}"
        echo "    ]"
        echo "  }"
        echo ""
        exit 1
    else
        cat > "$SETTINGS_FILE" << JSONEOF
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "$GATE_CMD"}]},
      {"matcher": "Write", "hooks": [{"type": "command", "command": "$WRITE_CMD"}]},
      {"matcher": "Edit", "hooks": [{"type": "command", "command": "$WRITE_CMD"}]}
    ]
  }
}
JSONEOF
        log_ok "Hook 配置已创建 $SETTINGS_FILE"
    fi
fi

# ════════════════════════════════════════════════════════════
#  Step 4：验证安装（回读验证，不信任写入脚本的输出）
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━ Step 3/4：安装验证（回读确认）━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ALL_OK=1
HOOKS_VERIFIED=0

# ── 3.1 脚本语法验证 ─────────────────────────────────────────
for f in skillguard-gate.sh skillguard-audit.sh skillguard-write.sh run-tests.sh; do
    if bash -n "$SCRIPT_DIR/$f" 2>/dev/null; then
        log_ok "$f 语法正确"
    else
        log_fail "$f 语法错误"
        ALL_OK=0
    fi
done

# ── 3.2 settings.json 格式验证 ───────────────────────────────
if [ -n "$PY_CMD" ]; then
    $PY_CMD -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$SETTINGS_FILE" 2>/dev/null && \
        log_ok "settings.json JSON 格式有效" || \
        { log_fail "settings.json JSON 格式无效"; ALL_OK=0; }
fi

# ── 3.3 关键验证：回读 settings.json 确认 hooks 确实写入 ────────
echo ""
echo -e "   ${BOLD}▸ 回读 settings.json 验证 hooks...${NC}"
if [ -f "$SETTINGS_FILE" ]; then
    # 检查 PreToolUse 是否存在且包含 skillguard
    if [ -n "$PY_CMD" ]; then
        VERIFY_RESULT=$($PY_CMD -c "
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        settings = json.load(f)
    hooks = settings.get('hooks', {}).get('PreToolUse', [])
    gate_found = False
    write_found = False
    edit_found = False
    for h in hooks:
        matcher = h.get('matcher', '')
        cmds = [hh.get('command', '') for hh in h.get('hooks', [])]
        cmd_str = ' '.join(cmds).lower()
        if matcher == 'Bash' and 'skillguard-gate' in cmd_str:
            gate_found = True
        elif matcher == 'Write' and 'skillguard-write' in cmd_str:
            write_found = True
        elif matcher == 'Edit' and 'skillguard-write' in cmd_str:
            edit_found = True
    if gate_found and write_found and edit_found:
        print('ALL_OK')
    else:
        missing = []
        if not gate_found: missing.append('Bash/gate')
        if not write_found: missing.append('Write')
        if not edit_found: missing.append('Edit')
        print('MISSING:' + ','.join(missing))
except Exception as e:
    print('ERROR:' + str(e))
" "$SETTINGS_FILE" 2>/dev/null)

        if [ "$VERIFY_RESULT" = "ALL_OK" ]; then
            log_ok "回读确认：PreToolUse hooks 全部就位（Bash/Write/Edit）"
            HOOKS_VERIFIED=1
        elif echo "$VERIFY_RESULT" | grep -q "^MISSING:"; then
            MISSING_HOOKS=$(echo "$VERIFY_RESULT" | sed 's/^MISSING://')
            log_fail "回读发现 hooks 缺失：$MISSING_HOOKS"
            log_fail "settings.json 写入失败！请检查文件权限或手动配置"
            ALL_OK=0
        else
            log_fail "回读验证出错：$VERIFY_RESULT"
            ALL_OK=0
        fi
    else
        # 无 Python，用 grep 降级验证
        if grep -q "skillguard-gate" "$SETTINGS_FILE" && grep -q "skillguard-write" "$SETTINGS_FILE"; then
            log_ok "回读确认：settings.json 包含 skillguard hooks（grep 降级验证）"
            HOOKS_VERIFIED=1
        else
            log_fail "回读发现 hooks 未写入 settings.json"
            ALL_OK=0
        fi
    fi
else
    log_fail "settings.json 不存在！"
    ALL_OK=0
fi

# ── 3.4 验证 hook 路径指向的脚本文件确实存在 ──────────────────
if [ $HOOKS_VERIFIED -eq 1 ]; then
    if [ -f "$SG_PATH/skillguard-gate.sh" ] && [ -f "$SG_PATH/skillguard-write.sh" ]; then
        log_ok "Hook 目标文件存在：$SG_PATH/skillguard-{gate,write}.sh"
    else
        log_fail "Hook 路径指向的脚本文件不存在！"
        [ ! -f "$SG_PATH/skillguard-gate.sh" ] && log_fail "  缺失：$SG_PATH/skillguard-gate.sh"
        [ ! -f "$SG_PATH/skillguard-write.sh" ] && log_fail "  缺失：$SG_PATH/skillguard-write.sh"
        ALL_OK=0
    fi
fi

# ════════════════════════════════════════════════════════════
#  Step 5：红队测试（可选）
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━ Step 4/4：红队测试验证（可选）━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f "$SCRIPT_DIR/run-tests.sh" ] && [ -d "$SCRIPT_DIR/test-fixtures" ]; then
    echo -e "   ${CYAN}运行红队测试验证 Layer 1 检测能力？（10 个攻击样本）${NC}"
    if [ $AUTO_YES -eq 1 ]; then
        TEST_CHOICE="Y"
        echo "   运行？[Y/n] Y（--yes 自动确认）"
    else
        read -p "   运行？[Y/n] " TEST_CHOICE
    fi
    if [[ "${TEST_CHOICE:-Y}" =~ ^[Yy]$ ]] || [ -z "$TEST_CHOICE" ]; then
        bash "$SCRIPT_DIR/run-tests.sh"
        TEST_RESULT=$?
        if [ $TEST_RESULT -eq 0 ]; then
            log_ok "红队测试全部通过"
        else
            log_warn "红队测试有 $TEST_RESULT 个失败"
            ALL_OK=0
        fi
    else
        log_info "跳过。后续可手动执行：bash run-tests.sh"
    fi
else
    log_warn "测试文件缺失，跳过红队验证"
fi

# ════════════════════════════════════════════════════════════
#  最终汇总（基于实际验证结果，非假设）
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━ 最终验证：实际状态确认 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 重新检测各组件实际状态（不信任之前的变量，实际运行命令确认）
FINAL_HOOK="❌ 未写入"
FINAL_DOCKER="❌ 未运行"
FINAL_IMAGE="❌ 未构建"
FINAL_SANDBOX="❌ 不可用"
FINAL_HUORONG="⚠️  未检测"
FINAL_PYTHON="❌ 未安装"

# Hook 状态（已在 3.3 验证）
if [ $HOOKS_VERIFIED -eq 1 ]; then
    FINAL_HOOK="✅ 已写入并验证"
fi

# Docker 实际状态
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    DOCKER_VER_FINAL=$(docker --version 2>/dev/null | head -1)
    FINAL_DOCKER="✅ 运行中（$DOCKER_VER_FINAL）"

    # 镜像实际状态
    if docker images skillguard -q 2>/dev/null | grep -q .; then
        FINAL_IMAGE="✅ 已构建"
    fi

    # Sandbox 实际状态
    if docker sandbox ls &>/dev/null 2>&1; then
        FINAL_SANDBOX="✅ 可用"
    fi
elif command -v docker &>/dev/null; then
    FINAL_DOCKER="⚠️  已安装但未运行"
else
    FINAL_DOCKER="❌ 未安装"
fi

# 火绒实际状态（Windows 环境）
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || command -v powershell.exe &>/dev/null; then
    # 检查进程是否在运行（最可靠的方式）
    if command -v powershell.exe &>/dev/null; then
        HR_PROC=$(powershell.exe -NoProfile -Command \
            "Get-Process -Name 'HipsMain','HipsDaemon' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path" \
            2>/dev/null | tr -d '\r')
        if [ -n "$HR_PROC" ]; then
            FINAL_HUORONG="✅ 运行中（$HR_PROC）"
        else
            # 进程没跑，看文件是否存在
            for candidate in "C:/Program Files/Huorong/Sysdiag/bin/HipsMain.exe" \
                             "C:/Program Files (x86)/Huorong/Sysdiag/bin/HipsMain.exe"; do
                if [ -f "$candidate" ]; then
                    FINAL_HUORONG="⚠️  已安装但未运行（$candidate）"
                    break
                fi
            done
            if echo "$FINAL_HUORONG" | grep -q "未检测"; then
                FINAL_HUORONG="❌ 未安装"
            fi
        fi
    else
        # 无 powershell，检查文件
        for candidate in "C:/Program Files/Huorong/Sysdiag/bin/HipsMain.exe" \
                         "C:/Program Files (x86)/Huorong/Sysdiag/bin/HipsMain.exe"; do
            if [ -f "$candidate" ]; then
                FINAL_HUORONG="⚠️  已安装（无法确认运行状态）"
                break
            fi
        done
    fi
else
    FINAL_HUORONG="ℹ️  非 Windows，Layer 0 跳过"
fi

# Python 实际状态
if [ -n "$PY_CMD" ]; then
    PY_VER_FINAL=$($PY_CMD --version 2>&1)
    FINAL_PYTHON="✅ $PY_VER_FINAL"
fi

echo "╔══════════════════════════════════════════════════════════╗"
if [ $ALL_OK -eq 1 ] && [ $HOOKS_VERIFIED -eq 1 ]; then
    echo "║  ✅ SkillGuard 配置完成！                                 ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║                                                        ║"
    echo "║  Hook 已激活，重启 Claude Code 即生效                     ║"
    echo "║  安装任何非官方技能时将自动触发安全审查                     ║"
else
    echo "║  ❌ SkillGuard 配置失败                                   ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  请检查上方错误信息并修复后重新运行                        ║"
fi
echo "║                                                        ║"
echo "║  实际验证结果（以下均为运行命令确认，非假设）：             ║"
echo "║                                                        ║"
printf "║    Hooks：   %-44s║\n" "$FINAL_HOOK"
printf "║    Docker：  %-44s║\n" "$FINAL_DOCKER"
printf "║    镜像：    %-44s║\n" "$FINAL_IMAGE"
printf "║    Sandbox： %-44s║\n" "$FINAL_SANDBOX"
printf "║    火绒：    %-44s║\n" "$FINAL_HUORONG"
printf "║    Python：  %-44s║\n" "$FINAL_PYTHON"
echo "║                                                        ║"
echo "║  Layer 可用性：                                           ║"
# Layer 状态基于实际验证结果重新计算
L0_FINAL="✅"
if echo "$FINAL_HUORONG" | grep -qE "❌|未检测"; then
    if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
        L0_FINAL="⚠️  跳过（火绒未就绪）"
    else
        L0_FINAL="ℹ️  跳过（非 Windows）"
    fi
fi
L1_FINAL="✅"
if echo "$FINAL_PYTHON" | grep -q "❌"; then
    L1_FINAL="⚠️  降级（Python 未安装）"
fi
L2_FINAL="❌ 不可用"
if echo "$FINAL_DOCKER" | grep -q "✅" && echo "$FINAL_IMAGE" | grep -q "✅"; then
    L2_FINAL="✅"
elif echo "$FINAL_DOCKER" | grep -q "✅"; then
    L2_FINAL="⚠️  Docker 就绪但镜像未构建"
fi
L3_FINAL="❌ 不可用"
if echo "$FINAL_SANDBOX" | grep -q "✅"; then
    L3_FINAL="✅"
fi
printf "║    Layer 0 火绒 AV：    %-33s║\n" "$L0_FINAL"
printf "║    Layer 1 语义扫描：   %-33s║\n" "$L1_FINAL"
printf "║    Layer 2 容器扫描：   %-33s║\n" "$L2_FINAL"
printf "║    Layer 3 动态测试：   %-33s║\n" "$L3_FINAL"
echo "║                                                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
