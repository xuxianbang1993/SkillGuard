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
        read -p "   构建？[Y/n] " BUILD_CHOICE
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

# ── 2.7 Python3 ──────────────────────────────────────────────
ENV_TOTAL=$((ENV_TOTAL+1))
PYTHON_OK=0
if command -v python3 &>/dev/null; then
    PY_VER=$(python3 --version 2>/dev/null || echo "unknown")
    log_ok "Python3：$PY_VER"
    PYTHON_OK=1
    ENV_SCORE=$((ENV_SCORE+1))
else
    log_warn "Python3：未安装"
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

if command -v python3 &>/dev/null; then
    python3 -c "
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
        {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': gate_cmd}]},
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
#  Step 4：验证安装
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━ Step 3/4：脚本语法验证 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ALL_OK=1
for f in skillguard-gate.sh skillguard-audit.sh skillguard-write.sh run-tests.sh; do
    if bash -n "$SCRIPT_DIR/$f" 2>/dev/null; then
        log_ok "$f"
    else
        log_fail "$f 语法错误"
        ALL_OK=0
    fi
done

# 验证 settings.json
if command -v python3 &>/dev/null; then
    python3 -c "import json; json.load(open('$SETTINGS_FILE'))" 2>/dev/null && \
        log_ok "settings.json 格式有效" || \
        { log_fail "settings.json 格式无效"; ALL_OK=0; }
fi

# ════════════════════════════════════════════════════════════
#  Step 5：红队测试（可选）
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━ Step 4/4：红队测试验证（可选）━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f "$SCRIPT_DIR/run-tests.sh" ] && [ -d "$SCRIPT_DIR/test-fixtures" ]; then
    echo -e "   ${CYAN}运行红队测试验证 Layer 1 检测能力？（10 个攻击样本）${NC}"
    read -p "   运行？[Y/n] " TEST_CHOICE
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
#  最终汇总
# ════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
if [ $ALL_OK -eq 1 ] && [ $ENV_SCORE -ge $((ENV_TOTAL - 2)) ]; then
    echo "║  ✅ SkillGuard 配置完成！                                 ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║                                                        ║"
    echo "║  Hook 已激活，重启 Claude Code 即生效                     ║"
    echo "║  安装任何非官方技能时将自动触发安全审查                     ║"
    echo "║                                                        ║"
    echo "║  防御能力：                                              ║"
    printf "║    环境就绪度：%-42s║\n" "$ENV_SCORE / $ENV_TOTAL"
    printf "║    Layer 0 火绒 AV：%-37s║\n" "$L0_STATUS"
    printf "║    Layer 1 语义扫描：%-36s║\n" "$L1_STATUS"
    printf "║    Layer 2 容器扫描：%-36s║\n" "$L2_STATUS"
    printf "║    Layer 3 动态测试：%-36s║\n" "$L3_STATUS"
    echo "║                                                        ║"
else
    echo "║  ⚠️  SkillGuard 部分配置完成                               ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  请检查上方警告并安装缺失的依赖                            ║"
fi
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
