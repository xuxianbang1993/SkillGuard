#!/bin/bash
# uninstall.sh — SkillGuard 一键卸载脚本
# 用法：cd SkillGuard && bash uninstall.sh
# 也可在 Claude Code 外直接运行（绕过 hook 拦截）
#
# 功能：
#   1. 从 ~/.claude/settings.json 移除 SkillGuard 的 PreToolUse hooks
#   2. 清理临时文件（.approved/、/tmp 标记文件）
#   3. 提示用户删除 SkillGuard 目录（不自动删除）

set -uo pipefail

# ── 颜色输出 ────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_ok()   { echo -e "   ${GREEN}OK $1${NC}"; }
log_warn() { echo -e "   ${YELLOW}WARN $1${NC}"; }
log_fail() { echo -e "   ${RED}FAIL $1${NC}"; }
log_info() { echo -e "   ${CYAN}INFO $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "========================================================"
echo "  SkillGuard 卸载"
echo "========================================================"
echo ""

# ── Step 1：从 settings.json 移除 SkillGuard hooks ────────────
echo "--- Step 1/3：移除 Hook 配置 ---"
echo ""

SETTINGS_FILE="$HOME/.claude/settings.json"

if [ ! -f "$SETTINGS_FILE" ]; then
    log_warn "settings.json 不存在，跳过"
else
    # 确定 Python 命令
    PY_CMD=""
    if command -v python3 &>/dev/null; then
        PY_CMD="python3"
    elif command -v python &>/dev/null; then
        PY_CMD="python"
    fi

    if [ -n "$PY_CMD" ]; then
        $PY_CMD -c "
import json, sys, os

settings_file = sys.argv[1]

try:
    with open(settings_file, 'r', encoding='utf-8') as f:
        settings = json.load(f)
except Exception as e:
    print(f'Error reading settings.json: {e}')
    sys.exit(1)

hooks = settings.get('hooks', {})
pre_tool_use = hooks.get('PreToolUse', [])

# 只移除包含 skillguard 的 hook 条目
cleaned = [h for h in pre_tool_use if 'skillguard' not in str(h).lower()]

if len(cleaned) == len(pre_tool_use):
    print('No SkillGuard hooks found in PreToolUse')
else:
    removed = len(pre_tool_use) - len(cleaned)
    if cleaned:
        hooks['PreToolUse'] = cleaned
    else:
        hooks.pop('PreToolUse', None)

    with open(settings_file, 'w', encoding='utf-8') as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)

    print(f'Removed {removed} SkillGuard hook(s) from settings.json')
" "$SETTINGS_FILE" 2>&1
        if [ $? -eq 0 ]; then
            log_ok "Hook 配置已从 settings.json 移除"
        else
            log_fail "移除失败，请手动编辑 $SETTINGS_FILE"
        fi
    elif command -v jq &>/dev/null; then
        TMP_FILE=$(mktemp)
        jq '.hooks.PreToolUse = [.hooks.PreToolUse[]? | select(.hooks[0].command | test("skillguard"; "i") | not)]
            | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end' \
            "$SETTINGS_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$SETTINGS_FILE"
        log_ok "Hook 配置已从 settings.json 移除（jq）"
    else
        log_fail "未找到 python/jq，请手动编辑 $SETTINGS_FILE 移除 PreToolUse 中的 skillguard 条目"
    fi
fi

# ── Step 2：清理临时文件 ──────────────────────────────────────
echo ""
echo "--- Step 2/3：清理临时文件 ---"
echo ""

# 清理 .approved/ 凭证目录
if [ -d "$SCRIPT_DIR/.approved" ]; then
    rm -rf "$SCRIPT_DIR/.approved"
    log_ok "已清理 .approved/ 凭证目录"
else
    log_info ".approved/ 不存在，跳过"
fi

# 清理 /tmp 标记文件
CLEANED_TMP=0
for f in /tmp/skillguard-*; do
    [ -f "$f" ] || continue
    rm -f "$f"
    CLEANED_TMP=$((CLEANED_TMP+1))
done
if [ $CLEANED_TMP -gt 0 ]; then
    log_ok "已清理 $CLEANED_TMP 个 /tmp 标记文件"
else
    log_info "无 /tmp 标记文件需要清理"
fi

# ── Step 3：提示删除目录 ──────────────────────────────────────
echo ""
echo "--- Step 3/3：删除 SkillGuard 目录 ---"
echo ""
echo "  SkillGuard 目录：$SCRIPT_DIR"
echo ""
echo -e "  ${YELLOW}请手动删除此目录完成卸载：${NC}"
echo "    rm -rf \"$SCRIPT_DIR\""
echo ""
echo "  (出于安全考虑，卸载脚本不会自动删除自身所在目录)"

# ── 汇总 ──────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo "  卸载完成！重启 Claude Code 即可生效。"
echo "========================================================"
echo ""
