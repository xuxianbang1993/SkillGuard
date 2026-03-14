#!/bin/bash
# update.sh — SkillGuard 一键更新脚本
# 用法：cd SkillGuard && bash update.sh
#
# 功能：
#   1. 记录当前版本
#   2. git pull 拉取最新代码
#   3. 重新生成 checksums.sha256
#   4. 重新配置 Hook（路径可能变化）
#   5. 显示版本间的 CHANGELOG（新功能 + Bug 修复）

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || { log_fail "无法进入 SkillGuard 目录"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           SkillGuard 一键更新                             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1：记录当前版本 ────────────────────────────────────────
OLD_VERSION="unknown"
if [ -f "$SCRIPT_DIR/VERSION" ]; then
    OLD_VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')
fi
log_info "当前版本：v$OLD_VERSION"

# ── Step 2：检查是否有本地修改 ──────────────────────────────────
echo ""
echo "━━━ Step 1/4：检查本地状态 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    log_fail "当前目录不是 Git 仓库，无法更新"
    log_info "请重新克隆：git clone https://github.com/xuxianbang1993/SkillGuard.git"
    exit 1
fi

# 检查本地是否有未提交的修改
LOCAL_CHANGES=$(git status --porcelain 2>/dev/null | grep -v '^\?\?' | head -5)
if [ -n "$LOCAL_CHANGES" ]; then
    log_warn "检测到本地修改："
    echo "$LOCAL_CHANGES" | while read -r line; do
        echo "      $line"
    done
    echo ""
    echo -e "   ${YELLOW}本地修改可能在更新时产生冲突。${NC}"
    echo -e "   ${CYAN}选择操作：${NC}"
    echo "      1) 保留修改并尝试合并（默认）"
    echo "      2) 放弃本地修改，强制更新"
    echo "      3) 取消更新"
    read -p "   选择 [1/2/3]: " MERGE_CHOICE
    case "${MERGE_CHOICE:-1}" in
        2)
            log_warn "放弃本地修改..."
            git checkout -- . 2>/dev/null
            git clean -fd 2>/dev/null
            ;;
        3)
            log_info "已取消更新"
            exit 0
            ;;
        *)
            log_info "尝试合并本地修改..."
            ;;
    esac
fi

log_ok "本地状态检查完成"

# ── Step 3：拉取最新代码 ────────────────────────────────────────
echo ""
echo "━━━ Step 2/4：拉取最新代码 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

PULL_OUTPUT=$(git pull 2>&1)
PULL_EXIT=$?

if [ $PULL_EXIT -ne 0 ]; then
    log_fail "git pull 失败："
    echo "$PULL_OUTPUT"
    echo ""
    log_info "如有冲突，请手动解决后重新运行 bash update.sh"
    exit 1
fi

if echo "$PULL_OUTPUT" | grep -q "Already up to date"; then
    log_ok "已是最新版本，无需更新"
    NEW_VERSION="$OLD_VERSION"
else
    log_ok "代码已更新"
    echo "$PULL_OUTPUT" | head -10 | while read -r line; do
        echo "      $line"
    done
fi

# 读取新版本
NEW_VERSION="unknown"
if [ -f "$SCRIPT_DIR/VERSION" ]; then
    NEW_VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')
fi

# ── Step 4：重新生成 checksums ──────────────────────────────────
echo ""
echo "━━━ Step 3/4：更新完整性校验 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f "$SCRIPT_DIR/generate-checksums.sh" ]; then
    bash "$SCRIPT_DIR/generate-checksums.sh" 2>/dev/null
    if [ $? -eq 0 ]; then
        log_ok "checksums.sha256 已重新生成"
    else
        log_warn "校验和生成失败（不影响使用，但自检功能可能异常）"
    fi
else
    log_warn "generate-checksums.sh 不存在，跳过"
fi

# ── Step 5：重新配置 Hook ───────────────────────────────────────
echo ""
echo "━━━ Step 4/4：重新配置 Hook ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f "$SCRIPT_DIR/一键配置.sh" ]; then
    # 静默运行配置脚本的 Hook 配置部分
    SG_PATH=$(echo "$SCRIPT_DIR" | tr '\\' '/')
    CLAUDE_DIR="$HOME/.claude"
    SETTINGS_FILE="$CLAUDE_DIR/settings.json"
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
other_hooks = [h for h in existing_pre if 'skillguard' not in str(h).lower()]
settings['hooks']['PreToolUse'] = sg_hooks['PreToolUse'] + other_hooks

with open(settings_file, 'w', encoding='utf-8') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)

print('OK')
" "$SETTINGS_FILE" "$GATE_CMD" "$WRITE_CMD" 2>/dev/null
        if [ $? -eq 0 ]; then
            log_ok "Hook 配置已更新"
        else
            log_warn "Hook 配置更新失败，请手动运行：bash 一键配置.sh"
        fi
    else
        log_info "未找到 python3，请手动运行：bash 一键配置.sh"
    fi
else
    log_warn "一键配置.sh 不存在，请手动配置 Hook"
fi

# ── 显示更新日志 ────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════"

if [ "$OLD_VERSION" = "$NEW_VERSION" ]; then
    echo -e "   ${GREEN}✅ 已是最新版本 v${NEW_VERSION}，无需更新${NC}"
else
    echo -e "   ${GREEN}✅ 更新完成：v${OLD_VERSION} → v${NEW_VERSION}${NC}"
    echo ""

    # 显示两个版本之间的 CHANGELOG
    if [ -f "$SCRIPT_DIR/CHANGELOG.md" ]; then
        echo "┌── 更新日志 ─────────────────────────────────────────────┐"
        echo "│"

        # 提取从旧版本之后到新版本的所有 changelog 内容
        IN_RANGE=0
        while IFS= read -r line; do
            # 检测版本号标题行 ## [x.y]
            if echo "$line" | grep -qE '^\#\# \['; then
                VER=$(echo "$line" | grep -oP '\[\K[^\]]+')
                if [ "$VER" = "$NEW_VERSION" ]; then
                    IN_RANGE=1
                    continue
                fi
                # 遇到旧版本或更老版本，停止输出
                if [ "$VER" = "$OLD_VERSION" ]; then
                    IN_RANGE=0
                    break
                fi
                # 介于新旧版本之间的中间版本也要显示
                if [ $IN_RANGE -eq 1 ]; then
                    echo "│"
                    echo -e "│  ${BOLD}── v${VER} ──${NC}"
                fi
                continue
            fi

            if [ $IN_RANGE -eq 1 ]; then
                # 格式化输出 changelog 行
                case "$line" in
                    "### 新功能"*)
                        echo -e "│  ${GREEN}🆕 新功能：${NC}"
                        ;;
                    "### 改进"*)
                        echo -e "│  ${CYAN}⬆️  改进：${NC}"
                        ;;
                    "### 修复"*)
                        echo -e "│  ${YELLOW}🔧 修复：${NC}"
                        ;;
                    "### 安全"*)
                        echo -e "│  ${RED}🔒 安全：${NC}"
                        ;;
                    "- "*)
                        echo "│    ${line#- }"
                        ;;
                    "---"*)
                        ;;
                    "")
                        ;;
                    *)
                        [ -n "$line" ] && echo "│    $line"
                        ;;
                esac
            fi
        done < "$SCRIPT_DIR/CHANGELOG.md"

        echo "│"
        echo "└──────────────────────────────────────────────────────────┘"
    fi
fi

echo ""
echo -e "   ${CYAN}重启 Claude Code 即可使用新版本${NC}"
echo ""
