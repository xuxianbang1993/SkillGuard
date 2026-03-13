#!/bin/bash
# skillguard-gate.sh
# SkillGuard Gate — Claude Code PreToolUse Hook 技能安装拦截器
# 调用时机：Claude Code 准备执行 Bash 工具前自动触发
# 输入：stdin 收到 JSON，格式 {"tool_name":"Bash","tool_input":{"command":"..."}}
# 行为：若检测到技能安装命令，拦截并启动 SkillGuard 隔离审查流水线
# 配套：skillguard-write.sh（拦截 Write/Edit 工具对敏感路径的写入）

set -euo pipefail

# ── 路径配置 ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/skillguard-audit.sh"

# 审查通过凭证目录（通过审查的技能在此留下凭证，避免重复审查死循环）
APPROVED_DIR="$SCRIPT_DIR/.approved"
mkdir -p "$APPROVED_DIR" 2>/dev/null || true

# ── 凭证函数 ────────────────────────────────────────────────
# 检查技能是否有有效的审查通过凭证（30 分钟时效）
has_valid_approval() {
    local source="$1"
    # 用 SHA256 哈希作为文件名（避免特殊字符问题）
    local hash
    hash=$(echo -n "$source" | sha256sum | cut -d' ' -f1)
    local cert_file="$APPROVED_DIR/$hash"

    if [ ! -f "$cert_file" ]; then
        return 1  # 无凭证
    fi

    # 检查时效（30 分钟 = 1800 秒）
    local cert_time
    cert_time=$(cat "$cert_file" 2>/dev/null || echo "0")
    local now
    now=$(date +%s)
    local age=$((now - cert_time))

    if [ $age -gt 1800 ]; then
        rm -f "$cert_file"  # 过期，删除
        return 1
    fi

    return 0  # 有效
}

# 颁发审查通过凭证
grant_approval() {
    local source="$1"
    local hash
    hash=$(echo -n "$source" | sha256sum | cut -d' ' -f1)
    date +%s > "$APPROVED_DIR/$hash"
}

# 清理所有过期凭证（每次运行时顺带清理）
cleanup_expired_approvals() {
    local now
    now=$(date +%s)
    for cert in "$APPROVED_DIR"/*; do
        [ -f "$cert" ] || continue
        local cert_time
        cert_time=$(cat "$cert" 2>/dev/null || echo "0")
        local age=$((now - cert_time))
        if [ $age -gt 1800 ]; then
            rm -f "$cert"
        fi
    done
}
cleanup_expired_approvals 2>/dev/null || true

# ── 读取 Hook 输入（JSON from stdin）────────────────────────
INPUT=$(cat)

# 提取 Bash 命令（需要 jq；若无 jq 则用 grep 降级）
if command -v jq &>/dev/null; then
    BASH_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
else
    BASH_CMD=$(echo "$INPUT" | grep -oP '"command"\s*:\s*"\K[^"]+' | head -1)
fi

# 若不是 Bash 工具或无法解析，直接放行
if [ -z "$BASH_CMD" ]; then
    exit 0
fi

# ── 检测是否为技能安装命令 ───────────────────────────────────
is_skill_install() {
    local cmd="$1"
    # 覆盖所有已知的技能安装方式
    echo "$cmd" | grep -qE \
        'npx\s+skills@|npx\s+clawhub@|claude\s+skill\s+add|skills\s+add|npm\s+exec\s+skills@|yarn\s+dlx\s+skills@|pnpm\s+dlx\s+skills@|node_modules/.bin/skills\s+add|npx\s+-y\s+skills@|npx\s+--yes\s+skills@|npx\s+-y\s+clawhub@|npx\s+--yes\s+clawhub@'
}

if ! is_skill_install "$BASH_CMD"; then
    # 不是技能安装命令，放行
    exit 0
fi

# ── 解析技能来源 ─────────────────────────────────────────────
# 支持格式：
#   npx skills@latest add anthropics/skills@brainstorming -g -y
#   npx clawhub@latest install some-skill
#   npx skills@latest add owner/repo@skill-name

SKILL_SOURCE=""
SKILL_NAME=""

if echo "$BASH_CMD" | grep -qE 'skills@.*add\s+'; then
    SKILL_SOURCE=$(echo "$BASH_CMD" | grep -oP '(?<=add\s)[^\s]+' | head -1)
    SKILL_NAME=$(echo "$SKILL_SOURCE" | grep -oP '[^@]+$' | head -1)
elif echo "$BASH_CMD" | grep -qE 'clawhub@.*install\s+'; then
    SKILL_SOURCE=$(echo "$BASH_CMD" | grep -oP '(?<=install\s)[^\s]+' | head -1)
    SKILL_NAME="$SKILL_SOURCE"
fi

if [ -z "$SKILL_SOURCE" ]; then
    echo "[SkillGuard] 无法解析技能来源，请手动审查后安装。"
    echo "原始命令：$BASH_CMD"
    exit 1
fi

# ── 快速通道判断（官方技能跳过审查）───────────────────────────
is_trusted_source() {
    local src="$1"
    # 精确匹配组织/仓库名（不是前缀匹配）
    local org_repo="${src%%@*}"
    local skill_name="${src##*@}"

    # 验证技能名仅包含安全字符
    if [[ ! "$skill_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 1  # 技能名包含非法字符，不可信
    fi

    # 精确白名单（仅允许已确认的官方组织/仓库）
    case "$org_repo" in
        "anthropics/skills")
            return 0  # Anthropic 官方技能
            ;;
        "vercel-labs/ai-sdk-skills")
            return 0  # Vercel Labs 官方技能
            ;;
    esac
    return 1  # 不在白名单中，不可信
}

if is_trusted_source "$SKILL_SOURCE"; then
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  ✅ 官方技能快速通道                                   ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  来源：$SKILL_SOURCE"
    echo "║  判定：anthropics / vercel-labs 官方，跳过隔离审查      ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    # 放行原命令（不拦截）
    exit 0
fi

# ── 审查通过凭证检查（防止重复审查死循环）──────────────────────
if has_valid_approval "$SKILL_SOURCE"; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ 审查通过凭证有效，放行安装                             ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  来源：$SKILL_SOURCE"
    echo "║  状态：已通过隔离审查，凭证有效（30 分钟时效内）              ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    exit 0  # 放行原命令
fi

# ── 非官方来源：启动隔离审查流水线 ──────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  🔒 SkillGuard：拦截到技能安装请求                         ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  来源：$SKILL_SOURCE"
echo "║  判定：非官方来源，启动隔离审查流水线                        ║"
echo "║  原安装命令已暂停，待审查通过后再由你决定是否释放到本机        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# 调用审查主控脚本
bash "$AUDIT_SCRIPT" "$SKILL_SOURCE" "$SKILL_NAME"
AUDIT_EXIT=$?

# 根据审查结果决定是否放行
case $AUDIT_EXIT in
    0)
        # SAFE：审查通过，颁发凭证
        grant_approval "$SKILL_SOURCE"
        echo ""
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  ✅ 审查通过，已颁发安装凭证                               ║"
        echo "╠══════════════════════════════════════════════════════════╣"
        echo "║  来源：$SKILL_SOURCE"
        echo "║  凭证有效期：30 分钟                                      ║"
        echo "║  下次执行同一安装命令将自动放行                             ║"
        echo "╠══════════════════════════════════════════════════════════╣"
        echo "║  请告知 Claude：「继续安装」以执行原始安装命令               ║"
        echo "╚══════════════════════════════════════════════════════════╝"
        echo ""
        # 本次仍拦截（审查过程中原命令已被暂停）
        # 用户确认后 Claude 重新执行 → 凭证有效 → 自动放行
        exit 1
        ;;
    3)
        # WARN：有警告，等待用户决定
        echo ""
        echo "║  用户确认「释放」后，Claude 重新执行安装命令即可              ║"
        echo ""
        # 用户说"释放"后，需要手动颁发凭证
        # Claude 应执行：echo $(date +%s) > .approved/<hash>
        # 然后重新执行 npx 命令
        echo "[SkillGuard] 若用户确认释放，请执行以下命令颁发凭证："
        echo "  echo \$(date +%s) > \"$APPROVED_DIR/$(echo -n "$SKILL_SOURCE" | sha256sum | cut -d' ' -f1)\""
        exit 1
        ;;
    *)
        # FAIL / MALICIOUS：拒绝安装
        echo ""
        echo "⛔ 安装已被拒绝，不颁发凭证。"
        exit 1
        ;;
esac
