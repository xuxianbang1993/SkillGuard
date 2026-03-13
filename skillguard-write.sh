#!/bin/bash
# skillguard-write.sh
# SkillGuard Write — Claude Code PreToolUse Hook Write/Edit 工具写入守卫
# 调用时机：Claude Code 准备执行 Write 或 Edit 工具前自动触发
# 输入：stdin 收到 JSON，格式 {"tool_name":"Write","tool_input":{"file_path":"...","content":"..."}}
#       或 {"tool_name":"Edit","tool_input":{"file_path":"...","old_string":"...","new_string":"..."}}
# 行为：若写入目标为敏感路径（安全配置/Hook/启动脚本），则拦截并警告

set -euo pipefail

# ── 读取 Hook 输入（JSON from stdin）────────────────────────
INPUT=$(cat)

# 提取文件路径
if command -v jq &>/dev/null; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
    # 对 Write 工具额外提取 content 用于检测注入
    if [ "$TOOL_NAME" = "Write" ]; then
        CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
    else
        # Edit 工具提取 new_string
        CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    fi
else
    FILE_PATH=$(echo "$INPUT" | grep -oP '"file_path"\s*:\s*"\K[^"]+' | head -1)
    TOOL_NAME=$(echo "$INPUT" | grep -oP '"tool_name"\s*:\s*"\K[^"]+' | head -1)
    CONTENT=""
fi

# 若无法解析路径，放行
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# ── 路径标准化（处理 Windows/WSL 路径混合）───────────────────
normalize_path() {
    local p="$1"
    # 转小写、统一分隔符
    echo "$p" | tr '\\' '/' | tr '[:upper:]' '[:lower:]'
}

NORM_PATH=$(normalize_path "$FILE_PATH")

# ── 敏感路径防御列表 ─────────────────────────────────────────
# CRITICAL: 这些路径被写入可能导致安全配置被篡改
BLOCKED=0
REASON=""

# 1. Claude Code 核心配置文件
if echo "$NORM_PATH" | grep -qE '\.claude/(claude\.md|settings\.json|settings\.local\.json)$'; then
    BLOCKED=1
    REASON="Claude Code 核心配置文件"
fi

# 2. Claude Code Hooks 目录
if echo "$NORM_PATH" | grep -qE '\.claude/hooks/'; then
    BLOCKED=1
    REASON="Claude Code Hooks 目录"
fi

# 3. CLAUDE.md（项目级或全局级）
if echo "$NORM_PATH" | grep -qiE '(^|/)claude\.md$'; then
    BLOCKED=1
    REASON="CLAUDE.md 指令文件"
fi

# 4. Shell 启动脚本（持久化后门）
if echo "$NORM_PATH" | grep -qE '\.(bashrc|bash_profile|zshrc|profile|zprofile)$'; then
    BLOCKED=1
    REASON="Shell 启动脚本（持久化风险）"
fi

# 5. SSH/AWS/GPG 密钥目录
if echo "$NORM_PATH" | grep -qE '\.(ssh|aws|gnupg)/'; then
    BLOCKED=1
    REASON="密钥/凭证目录"
fi

# 6. crontab / systemd 定时任务
if echo "$NORM_PATH" | grep -qE '(crontab|cron\.d/|systemd/.*\.service|systemd/.*\.timer)'; then
    BLOCKED=1
    REASON="定时任务配置（持久化风险）"
fi

# 7. Git hooks（可植入后门到仓库）
if echo "$NORM_PATH" | grep -qE '\.git/hooks/'; then
    BLOCKED=1
    REASON="Git Hooks（仓库级持久化）"
fi

# ── 内容注入检测（对非拦截路径也检查恶意内容）───────────────
CONTENT_ALERT=""
if [ -n "$CONTENT" ] && [ "$BLOCKED" -eq 0 ]; then
    # 检测 Write/Edit 内容中的 Prompt Injection 模式
    if echo "$CONTENT" | grep -qiE 'ignore previous|override instruction|disregard|higher priority'; then
        CONTENT_ALERT="内容含指令覆盖模式（Prompt Injection）"
    elif echo "$CONTENT" | grep -qiE 'API_KEY|ANTHROPIC_KEY|Bearer.*[a-zA-Z0-9]{20,}|sk-ant-'; then
        CONTENT_ALERT="内容含凭证/密钥模式"
    elif echo "$CONTENT" | grep -qiE 'curl.*\|.*bash|wget.*\|.*sh|eval\s*\('; then
        CONTENT_ALERT="内容含危险执行模式"
    elif echo "$CONTENT" | grep -qiE 'webhook\.site|pipedream\.net|ngrok\.io|burpcollaborator'; then
        CONTENT_ALERT="内容含已知外传域名"
    fi
fi

# ── 处理拦截 ──────────────────────────────────────────────────
if [ "$BLOCKED" -eq 1 ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  🛡️  SkillGuard Write：拦截到敏感路径写入                      ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  工具：$TOOL_NAME"
    echo "║  目标：$FILE_PATH"
    echo "║  原因：$REASON"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  ⚠️  此写入已被拦截。如需手动执行，请确认操作安全后       ║"
    echo "║     告知 Claude：「放行写入」或「取消」                    ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# ── 内容警告（不拦截，但提醒用户）────────────────────────────
if [ -n "$CONTENT_ALERT" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  SkillGuard Write：内容安全警告                            ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  工具：$TOOL_NAME"
    echo "║  目标：$FILE_PATH"
    echo "║  警告：$CONTENT_ALERT"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  写入将继续，但请人工确认内容安全性                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
fi

# 放行
exit 0
