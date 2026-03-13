#!/bin/bash
# install.sh — SkillGuard 一键安装脚本
# 用法：git clone https://github.com/xuxianbang1993/SkillGuard.git && cd SkillGuard && bash install.sh
#
# 功能：
#   1. 自动检测 SkillGuard 脚本路径
#   2. 将 Hook 配置合并写入 ~/.claude/settings.json（不覆盖已有配置）
#   3. 验证安装结果

set -euo pipefail

# ── 颜色输出 ────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_fail() { echo -e "${RED}❌ $1${NC}"; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           SkillGuard 安装向导                             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1：确定 SkillGuard 脚本路径 ──────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 验证关键文件存在
for f in skillguard-gate.sh skillguard-audit.sh skillguard-write.sh; do
    if [ ! -f "$SCRIPT_DIR/$f" ]; then
        log_fail "找不到 $f，请确认在 SkillGuard 目录下运行此脚本"
        exit 1
    fi
done

# 统一为正斜杠路径（兼容 Windows Git Bash）
SG_PATH=$(echo "$SCRIPT_DIR" | tr '\\' '/')
log_ok "SkillGuard 路径：$SG_PATH"

# ── Step 2：检查 ~/.claude 目录 ───────────────────────────────
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

mkdir -p "$CLAUDE_DIR" 2>/dev/null || true

# ── Step 3：构建 Hook 配置 ────────────────────────────────────
GATE_CMD="bash $SG_PATH/skillguard-gate.sh"
WRITE_CMD="bash $SG_PATH/skillguard-write.sh"

# ── Step 4：写入或合并 settings.json ──────────────────────────
if command -v python3 &>/dev/null; then
    # 使用 Python 安全合并 JSON（保留已有配置）
    python3 -c "
import json, os, sys

settings_file = sys.argv[1]
gate_cmd = sys.argv[2]
write_cmd = sys.argv[3]

# 读取现有配置
settings = {}
if os.path.exists(settings_file):
    try:
        with open(settings_file, 'r', encoding='utf-8') as f:
            settings = json.load(f)
    except (json.JSONDecodeError, IOError):
        # 备份损坏的文件
        backup = settings_file + '.bak'
        os.rename(settings_file, backup)
        print(f'⚠️  原 settings.json 格式错误，已备份到 {backup}')
        settings = {}

# 构建 SkillGuard Hook 配置
sg_hooks = {
    'PreToolUse': [
        {
            'matcher': 'Bash',
            'hooks': [{'type': 'command', 'command': gate_cmd}]
        },
        {
            'matcher': 'Write',
            'hooks': [{'type': 'command', 'command': write_cmd}]
        },
        {
            'matcher': 'Edit',
            'hooks': [{'type': 'command', 'command': write_cmd}]
        }
    ]
}

# 合并：保留其他 hook 类型，替换 PreToolUse
if 'hooks' not in settings:
    settings['hooks'] = {}

# 检查是否已存在 SkillGuard 配置
existing_pre = settings.get('hooks', {}).get('PreToolUse', [])
has_skillguard = any('skillguard' in str(h).lower() for h in existing_pre)

if has_skillguard:
    print('SkillGuard hooks 已存在，更新路径...')

# 移除旧的 SkillGuard entries（保留用户自定义的其他 hooks）
other_hooks = [h for h in existing_pre if 'skillguard' not in str(h).lower()]

# 合并：SkillGuard hooks + 用户已有的其他 hooks
settings['hooks']['PreToolUse'] = sg_hooks['PreToolUse'] + other_hooks

# 写入
with open(settings_file, 'w', encoding='utf-8') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)

print('OK')
" "$SETTINGS_FILE" "$GATE_CMD" "$WRITE_CMD"

    MERGE_RESULT=$?
    if [ $MERGE_RESULT -eq 0 ]; then
        log_ok "Hook 配置已写入 $SETTINGS_FILE"
    else
        log_fail "配置写入失败"
        exit 1
    fi

elif command -v jq &>/dev/null; then
    # jq 降级方案
    if [ -f "$SETTINGS_FILE" ]; then
        # 合并到已有文件
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
        # 创建新文件
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
    # 无 python3 也无 jq，直接写入（仅适用于全新安装）
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

# ── Step 5：验证安装 ──────────────────────────────────────────
echo ""
echo "── 验证安装 ──────────────────────────────────────────────"

# 检查脚本语法
ALL_OK=1
for f in skillguard-gate.sh skillguard-audit.sh skillguard-write.sh; do
    if bash -n "$SCRIPT_DIR/$f" 2>/dev/null; then
        log_ok "$f 语法正确"
    else
        log_fail "$f 语法错误"
        ALL_OK=0
    fi
done

# 检查 settings.json 是否有效 JSON
if command -v python3 &>/dev/null; then
    python3 -c "import json; json.load(open('$SETTINGS_FILE'))" 2>/dev/null && \
        log_ok "settings.json 格式有效" || \
        { log_fail "settings.json 格式无效"; ALL_OK=0; }
fi

# 检查依赖
echo ""
echo "── 环境依赖 ──────────────────────────────────────────────"
command -v docker &>/dev/null && log_ok "Docker: $(docker --version 2>/dev/null | head -1)" || log_warn "Docker 未安装（Layer 2/3 不可用）"
command -v python3 &>/dev/null && log_ok "Python3: $(python3 --version 2>/dev/null)" || log_warn "Python3 未安装（部分检测降级）"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
if [ $ALL_OK -eq 1 ]; then
    echo "║  ✅ SkillGuard 安装完成！                                 ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  Hook 已激活，下次启动 Claude Code 即生效                  ║"
    echo "║  安装任何非官方技能时将自动触发四层安全审查                  ║"
else
    echo "║  ⚠️  SkillGuard 部分安装完成，请检查上方错误                ║"
fi
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
