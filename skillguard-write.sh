#!/bin/bash
# skillguard-write.sh
# SkillGuard Write — Claude Code PreToolUse Hook Write/Edit 工具写入守卫
# 调用时机：Claude Code 准备执行 Write 或 Edit 工具前自动触发
# 输入：stdin 收到 JSON
# 行为：若写入目标为敏感路径，则拦截并警告
#
# 重要：stdout 必须为纯 JSON 或空。所有提示信息输出到 stderr。
# 阻塞使用 exit 2。

set -uo pipefail

# ── 读取 Hook 输入（JSON from stdin）────────────────────────
INPUT=$(cat)

# 提取文件路径和工具名
if command -v jq &>/dev/null; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
    if [ "$TOOL_NAME" = "Write" ]; then
        CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
    else
        CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    fi
    OLD_STRING=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
else
    FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    TOOL_NAME=$(echo "$INPUT" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    CONTENT=""
    OLD_STRING=""
fi

# 若无法解析路径，放行
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# ── 路径标准化（处理 Windows/WSL 路径混合 + 解析 .. 防遍历）──
normalize_path() {
    local p="$1"
    # 转小写、统一分隔符
    p=$(echo "$p" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')
    # 解析 .. 和 . 防止路径遍历绕过
    # 移除 /./
    p=$(echo "$p" | sed 's|/\./|/|g')
    # 移除 /../ (简化处理)
    while echo "$p" | grep -q '/[^/][^/]*/\.\./'; do
        p=$(echo "$p" | sed 's|/[^/][^/]*/\.\./|/|')
    done
    # 移除末尾 /. 或 /..
    p=$(echo "$p" | sed 's|/\.$||; s|/\.\.$||')
    echo "$p"
}

NORM_PATH=$(normalize_path "$FILE_PATH")

# ── SkillGuard 自身目录路径 ────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORM_SCRIPT_DIR=$(normalize_path "$SCRIPT_DIR")

# ── 敏感路径防御列表 ─────────────────────────────────────────
BLOCKED=0
REASON=""

# 1. Claude Code 核心配置文件
if echo "$NORM_PATH" | grep -qE '\.claude/(claude\.md|settings\.json|settings\.local\.json)$'; then
    # 卸载放行：Edit 工具移除 SkillGuard hooks（old_string 含 skillguard，new_string 不含）
    if [ "$TOOL_NAME" = "Edit" ] && [ -n "$OLD_STRING" ]; then
        if echo "$OLD_STRING" | grep -qi "skillguard"; then
            if ! echo "$CONTENT" | grep -qi "skillguard"; then
                exit 0  # 放行卸载操作
            fi
        fi
    fi
    # 安装放行：Write settings.json 且内容包含 skillguard hooks（安装/更新场景）
    if [ "$TOOL_NAME" = "Write" ] && [ -n "$CONTENT" ]; then
        if echo "$CONTENT" | grep -qi "skillguard"; then
            if echo "$NORM_PATH" | grep -qE 'settings\.json$'; then
                exit 0  # 放行 SkillGuard 安装配置写入
            fi
        fi
    fi
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

# 8. SkillGuard 自保护（防止篡改审计脚本本身）
if echo "$NORM_PATH" | grep -qF "$NORM_SCRIPT_DIR/"; then
    if ! echo "$NORM_PATH" | grep -qF "$NORM_SCRIPT_DIR/.approved/"; then
        BLOCKED=1
        REASON="SkillGuard 自保护（禁止修改审计脚本）"
    fi
fi

# ── 内容注入检测（对非拦截路径也检查恶意内容）───────────────
CONTENT_ALERT=""
if [ -n "$CONTENT" ] && [ "$BLOCKED" -eq 0 ]; then
    if echo "$CONTENT" | grep -qiE 'ignore previous|override instruction|disregard|higher priority'; then
        CONTENT_ALERT="内容含指令覆盖模式（Prompt Injection）"
    elif echo "$CONTENT" | grep -qiE 'API_KEY|ANTHROPIC_KEY|Bearer.*[a-zA-Z0-9]{20,}|sk-ant-'; then
        CONTENT_ALERT="内容含凭证/密钥模式"
    elif echo "$CONTENT" | grep -qiE 'curl.*\|.*bash|wget.*\|.*sh|eval[[:space:]]*\('; then
        CONTENT_ALERT="内容含危险执行模式"
    elif echo "$CONTENT" | grep -qiE 'webhook\.site|pipedream\.net|ngrok\.io|burpcollaborator'; then
        CONTENT_ALERT="内容含已知外传域名"
    fi
fi

# ── 处理拦截（输出到 stderr，exit 2 阻塞）──────────────────────
if [ "$BLOCKED" -eq 1 ]; then
    echo "[SkillGuard Write] 拦截敏感路径写入" >&2
    echo "[SkillGuard Write] 工具：$TOOL_NAME | 目标：$FILE_PATH" >&2
    echo "[SkillGuard Write] 原因：$REASON" >&2
    echo "[SkillGuard Write] 如需手动执行，请告知 Claude「放行写入」或「取消」" >&2
    exit 2
fi

# ── 内容警告（不拦截，但提醒用户）────────────────────────────
if [ -n "$CONTENT_ALERT" ]; then
    echo "[SkillGuard Write] 内容安全警告：$CONTENT_ALERT" >&2
    echo "[SkillGuard Write] 工具：$TOOL_NAME | 目标：$FILE_PATH" >&2
    echo "[SkillGuard Write] 写入将继续，请人工确认内容安全性。" >&2
fi

# 放行
exit 0
