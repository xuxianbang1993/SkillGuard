#!/bin/bash
# skillguard-gate.sh
# SkillGuard Gate — Claude Code PreToolUse Hook 技能安装拦截器
# 调用时机：Claude Code 准备执行 Bash 工具前自动触发
# 输入：stdin 收到 JSON，格式 {"tool_name":"Bash","tool_input":{"command":"..."}}
# 行为：若检测到技能安装命令，拦截并启动 SkillGuard 隔离审查流水线
# 配套：skillguard-write.sh（拦截 Write/Edit 工具对敏感路径的写入）
#
# 重要：stdout 必须为纯 JSON 或空（Claude Code 要求）。所有提示信息输出到 stderr。
# 阻塞使用 exit 2（官方文档推荐），exit 0 为放行。

set -uo pipefail
# 注意：不使用 set -e，因为后台进程和条件检查会导致意外退出

# ── 清理 trap ─────────────────────────────────────────────────
cleanup() {
    # 清理可能残留的后台进程
    kill "$UPDATE_PID" 2>/dev/null || true
    kill "$DOCKER_PID" 2>/dev/null || true
}
trap cleanup EXIT
UPDATE_PID=""
DOCKER_PID=""

# ── 路径配置 ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR_LOWER=$(echo "$SCRIPT_DIR" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')
AUDIT_SCRIPT="$SCRIPT_DIR/skillguard-audit.sh"
VERSION_FILE="$SCRIPT_DIR/VERSION"
INTEGRITY_MANIFEST="$SCRIPT_DIR/checksums.sha256"

# 跨平台临时目录
SG_TMPDIR="${TMPDIR:-/tmp}"

# 审查通过凭证目录（通过审查的技能在此留下凭证，避免重复审查死循环）
APPROVED_DIR="$SCRIPT_DIR/.approved"
mkdir -p "$APPROVED_DIR" 2>/dev/null || true

# ── 跨平台 sha256 计算函数（自动归一化行尾为 LF）─────────────
compute_sha256() {
    local file="$1"
    # 归一化 CRLF → LF 后计算哈希，确保跨平台一致性
    if command -v sha256sum &>/dev/null; then
        tr -d '\r' < "$file" 2>/dev/null | sha256sum | cut -d' ' -f1
    elif command -v shasum &>/dev/null; then
        tr -d '\r' < "$file" 2>/dev/null | shasum -a 256 | cut -d' ' -f1
    else
        echo ""
    fi
}

# ── 凭证函数 ────────────────────────────────────────────────
has_valid_approval() {
    local source="$1"
    local hash
    hash=$(echo -n "$source" | compute_sha256 /dev/stdin 2>/dev/null || echo -n "$source" | sha256sum 2>/dev/null | cut -d' ' -f1 || echo "")
    # fallback: 用简单字符串哈希
    if [ -z "$hash" ]; then
        hash=$(echo -n "$source" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "$source")
    fi
    local cert_file="$APPROVED_DIR/$hash"

    if [ ! -f "$cert_file" ]; then
        return 1
    fi

    local cert_time
    cert_time=$(cat "$cert_file" 2>/dev/null || echo "0")
    local now
    now=$(date +%s)
    local age=$((now - cert_time))

    if [ $age -gt 300 ]; then
        rm -f "$cert_file"
        return 1
    fi

    rm -f "$cert_file"
    return 0
}

grant_approval() {
    local source="$1"
    local hash
    hash=$(echo -n "$source" | compute_sha256 /dev/stdin 2>/dev/null || echo -n "$source" | sha256sum 2>/dev/null | cut -d' ' -f1 || echo "")
    if [ -z "$hash" ]; then
        hash=$(echo -n "$source" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "$source")
    fi
    date +%s > "$APPROVED_DIR/$hash"
}

cleanup_expired_approvals() {
    local now
    now=$(date +%s)
    for cert in "$APPROVED_DIR"/*; do
        [ -f "$cert" ] || continue
        local cert_time
        cert_time=$(cat "$cert" 2>/dev/null || echo "0")
        local age=$((now - cert_time))
        if [ $age -gt 300 ]; then
            rm -f "$cert"
        fi
    done
}
cleanup_expired_approvals 2>/dev/null || true

# ── 自身完整性校验（Layer: Self-Integrity）─────────────────────
verify_self_integrity() {
    # 优先：远程校验（从 GitHub 获取官方哈希）
    if command -v curl &>/dev/null; then
        local remote_checksums
        remote_checksums=$(curl -sf --max-time 5 \
            "https://raw.githubusercontent.com/xuxianbang1993/SkillGuard/main/checksums.sha256" 2>/dev/null)
        if [ -n "$remote_checksums" ]; then
            # 先检查版本差异：远程 VERSION != 本地 VERSION → 是新版本，非篡改
            local remote_ver_check
            remote_ver_check=$(curl -sf --max-time 3 \
                "https://raw.githubusercontent.com/xuxianbang1993/SkillGuard/main/VERSION" 2>/dev/null \
                | tr -d '[:space:]')
            local local_ver_check="unknown"
            if [ -f "$VERSION_FILE" ]; then
                local_ver_check=$(cat "$VERSION_FILE" | tr -d '[:space:]')
            fi
            if [ -n "$remote_ver_check" ] && [ "$remote_ver_check" != "$local_ver_check" ]; then
                echo "[SkillGuard] 新版本 v${remote_ver_check} 可用（当前 v${local_ver_check}）" >&2
                echo "[SkillGuard] 更新命令：cd $(echo "$SCRIPT_DIR" | head -c 40) && bash update.sh" >&2
                return 0
            fi
            # 版本相同，逐行比对（真正的篡改检测）
            local tampered=0
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                local expected_hash expected_file
                expected_hash=$(echo "$line" | awk '{print $1}')
                expected_file=$(echo "$line" | awk '{print $2}')
                expected_file="${expected_file#\*}"
                expected_file="${expected_file#./}"
                local local_file="$SCRIPT_DIR/$expected_file"
                if [ -f "$local_file" ]; then
                    local actual_hash
                    actual_hash=$(compute_sha256 "$local_file")
                    if [ -n "$actual_hash" ] && [ "$actual_hash" != "$expected_hash" ]; then
                        echo "[SkillGuard] 完整性校验失败：$expected_file 被篡改" >&2
                        echo "[SkillGuard] 请从 GitHub 重新克隆：git clone https://github.com/xuxianbang1993/SkillGuard" >&2
                        tampered=1
                    fi
                fi
            done <<< "$remote_checksums"
            if [ "$tampered" -eq 1 ]; then
                return 1
            fi
            return 0
        fi
    fi

    # 降级：本地 Manifest 校验
    if [ -f "$INTEGRITY_MANIFEST" ]; then
        local tampered=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local expected_hash expected_file
            expected_hash=$(echo "$line" | awk '{print $1}')
            expected_file=$(echo "$line" | awk '{print $2}')
            expected_file="${expected_file#\*}"
            expected_file="${expected_file#./}"
            local local_file="$SCRIPT_DIR/$expected_file"
            if [ -f "$local_file" ]; then
                local actual_hash
                actual_hash=$(compute_sha256 "$local_file")
                if [ -n "$actual_hash" ] && [ "$actual_hash" != "$expected_hash" ]; then
                    echo "[SkillGuard] 完整性校验失败（本地）：$expected_file 被篡改" >&2
                    tampered=1
                fi
            fi
        done < "$INTEGRITY_MANIFEST"
        if [ "$tampered" -eq 1 ]; then
            return 1
        fi
        return 0
    fi

    # 无 Manifest 且无网络，跳过校验（首次安装场景）
    return 0
}

# 执行自检（失败则拒绝所有操作）
if ! verify_self_integrity; then
    echo '{"error":"SkillGuard integrity check failed"}' >&2
    exit 2
fi

# ── 会话级版本更新检查（每次会话只检查一次）─────────────────────
UPDATE_CHECK_FLAG="$SG_TMPDIR/skillguard-update-checked-$(id -u 2>/dev/null || echo 0)"

check_for_updates() {
    if [ -f "$UPDATE_CHECK_FLAG" ]; then
        local flag_time
        flag_time=$(cat "$UPDATE_CHECK_FLAG" 2>/dev/null || echo "0")
        local now
        now=$(date +%s)
        local age=$((now - flag_time))
        if [ $age -lt 21600 ]; then
            return 0
        fi
    fi

    date +%s > "$UPDATE_CHECK_FLAG" 2>/dev/null || true

    local local_version="unknown"
    if [ -f "$VERSION_FILE" ]; then
        local_version=$(cat "$VERSION_FILE" | tr -d '[:space:]')
    fi

    if command -v curl &>/dev/null; then
        local remote_version
        remote_version=$(curl -sf --max-time 3 \
            "https://raw.githubusercontent.com/xuxianbang1993/SkillGuard/main/VERSION" 2>/dev/null \
            | tr -d '[:space:]')

        if [ -n "$remote_version" ] && [ "$remote_version" != "$local_version" ]; then
            echo "[SkillGuard] 新版本 v${remote_version} 可用（当前 v${local_version}）" >&2
            echo "[SkillGuard] 更新命令：cd $(echo "$SCRIPT_DIR" | head -c 40) && bash update.sh" >&2
        fi
    fi
}

# 异步检查（后台运行，所有输出到 stderr）
check_for_updates >&2 2>&1 &
UPDATE_PID=$!
( sleep 3 && kill "$UPDATE_PID" 2>/dev/null ) &
wait "$UPDATE_PID" 2>/dev/null || true

# ── 会话级 Docker Desktop 自动启动 ─────────────────────────────
DOCKER_START_FLAG="$SG_TMPDIR/skillguard-docker-checked-$(id -u 2>/dev/null || echo 0)"

auto_start_docker() {
    if [ -f "$DOCKER_START_FLAG" ]; then
        local flag_time
        flag_time=$(cat "$DOCKER_START_FLAG" 2>/dev/null || echo "0")
        local now
        now=$(date +%s)
        local age=$((now - flag_time))
        if [ $age -lt 21600 ]; then
            return 0
        fi
    fi
    date +%s > "$DOCKER_START_FLAG" 2>/dev/null || true

    if ! command -v docker &>/dev/null; then
        echo "[SkillGuard] Docker 未安装。Layer 2/3 不可用。" >&2
        echo "[SkillGuard] 请安装 Docker Desktop，首次安装后需重启电脑。" >&2
        return 0
    fi

    if docker info &>/dev/null 2>&1; then
        return 0
    fi

    echo "[SkillGuard] Docker 未运行，正在自动启动 Docker Desktop..." >&2
    if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "win32" ]]; then
        local docker_exe=""
        for candidate in \
            "C:/Program Files/Docker/Docker/Docker Desktop.exe" \
            "C:/Program Files (x86)/Docker/Docker/Docker Desktop.exe"; do
            if [ -f "$candidate" ]; then
                docker_exe="$candidate"
                break
            fi
        done
        if [ -n "$docker_exe" ]; then
            "$docker_exe" &>/dev/null &
            echo "[SkillGuard] Docker Desktop 已在后台启动。" >&2
        else
            echo "[SkillGuard] 未找到 Docker Desktop，请手动启动。" >&2
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        open -a "Docker" 2>/dev/null && \
            echo "[SkillGuard] Docker Desktop 已在后台启动。" >&2 || \
            echo "[SkillGuard] 无法启动 Docker Desktop，请手动启动。" >&2
    else
        # Linux: 不使用 sudo（会挂起等待密码），尝试无 sudo 或跳过
        if command -v systemctl &>/dev/null; then
            systemctl start docker 2>/dev/null && \
                echo "[SkillGuard] Docker 服务已启动。" >&2 || \
                echo "[SkillGuard] 无法启动 Docker 服务（可能需要 sudo），请手动运行：sudo systemctl start docker" >&2
        fi
    fi
}

# 异步启动（所有输出到 stderr，5 秒超时）
auto_start_docker >&2 2>&1 &
DOCKER_PID=$!
( sleep 5 && kill "$DOCKER_PID" 2>/dev/null ) &
wait "$DOCKER_PID" 2>/dev/null || true

# ── 读取 Hook 输入（JSON from stdin）────────────────────────
INPUT=$(cat)

# 提取 Bash 命令（需要 jq；若无 jq 则用 sed 降级）
if command -v jq &>/dev/null; then
    BASH_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
else
    BASH_CMD=$(echo "$INPUT" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi

# 若不是 Bash 工具或无法解析，直接放行
if [ -z "$BASH_CMD" ]; then
    exit 0
fi

# ── SkillGuard 自身命令白名单（精确路径匹配）──────────────────
# 安全：只放行确实调用 SkillGuard 目录下特定脚本的命令
BASH_CMD_NORM=$(echo "$BASH_CMD" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')

is_skillguard_self_command() {
    local cmd_lower="$1"
    local sg_dir_lower="$SCRIPT_DIR_LOWER"

    # 精确匹配：命令必须以 bash/sh + SkillGuard 目录路径 + 允许的脚本名开头
    for script_name in "一键配置.sh" "update.sh" "generate-checksums.sh" "run-tests.sh" "uninstall.sh"; do
        local script_lower
        script_lower=$(echo "$script_name" | tr '[:upper:]' '[:lower:]')
        # 匹配 "bash /path/to/skillguard/script.sh" 或 "cd /path/to/skillguard && bash script.sh"
        if echo "$cmd_lower" | grep -qF "${sg_dir_lower}/${script_lower}"; then
            return 0
        fi
    done

    # 精确匹配：python/jq 操作 settings.json 且命令中引用了 SkillGuard 目录路径
    if echo "$cmd_lower" | grep -qF "$sg_dir_lower"; then
        if echo "$cmd_lower" | grep -qE 'python.*settings.*json|jq.*settings.*json'; then
            return 0
        fi
    fi

    # 精确匹配：删除 SkillGuard 目录（必须是精确路径，不是包含字符串）
    if echo "$cmd_lower" | grep -qE "rm[[:space:]]+(-r|-rf|-f)[[:space:]]+[\"']?${sg_dir_lower}[\"']?[[:space:]]*$"; then
        return 0
    fi

    return 1
}

if is_skillguard_self_command "$BASH_CMD_NORM"; then
    exit 0
fi

# ── 检测是否为技能安装命令（大小写不敏感）────────────────────
is_skill_install() {
    local cmd="$1"
    echo "$cmd" | grep -qiE \
        'npx[[:space:]]+skills@|npx[[:space:]]+clawhub@|claude[[:space:]]+skill[[:space:]]+add|skills[[:space:]]+add|npm[[:space:]]+exec[[:space:]]+skills@|yarn[[:space:]]+dlx[[:space:]]+skills@|pnpm[[:space:]]+dlx[[:space:]]+skills@|node_modules/.bin/skills[[:space:]]+add|npx[[:space:]]+-y[[:space:]]+skills@|npx[[:space:]]+--yes[[:space:]]+skills@|npx[[:space:]]+-y[[:space:]]+clawhub@|npx[[:space:]]+--yes[[:space:]]+clawhub@'
}

if ! is_skill_install "$BASH_CMD"; then
    exit 0
fi

# ── 解析技能来源 ─────────────────────────────────────────────
SKILL_SOURCE=""
SKILL_NAME=""

# 通用提取：取 add/install 后第一个非 flag 参数
_sg_extract_after() {
    local verb="$1"
    echo "$BASH_CMD" | sed "s/.*${verb}[[:space:]][[:space:]]*//" | \
        tr ' ' '\n' | grep -v '^-' | head -1
}

# 按优先级匹配多种安装命令格式
if echo "$BASH_CMD" | grep -qiE 'skills@.*add[[:space:]]'; then
    # npx skills@latest add <source>
    SKILL_SOURCE=$(_sg_extract_after "add")
elif echo "$BASH_CMD" | grep -qiE 'clawhub@.*install[[:space:]]'; then
    # npx clawhub@latest install <source>
    SKILL_SOURCE=$(_sg_extract_after "install")
elif echo "$BASH_CMD" | grep -qiE 'skills?[[:space:]]+add[[:space:]]'; then
    # claude skills add <source> / skills add <source>
    SKILL_SOURCE=$(_sg_extract_after "add")
fi

# 从来源提取技能名称（兼容 URL / owner/repo / owner/repo@skill）
if [ -n "$SKILL_SOURCE" ]; then
    _sg_norm=$(echo "$SKILL_SOURCE" | \
        sed 's|https\?://github\.com/||' | \
        sed 's|https\?://clawhub\.ai/||' | \
        sed 's|\.git$||')
    if echo "$_sg_norm" | grep -q '@'; then
        SKILL_NAME=$(echo "$_sg_norm" | sed 's/.*@//')
    else
        SKILL_NAME=$(echo "$_sg_norm" | sed 's|.*/||')
    fi
    unset _sg_norm
fi

if [ -z "$SKILL_SOURCE" ]; then
    echo "[SkillGuard] 无法解析技能来源，请手动审查后安装。" >&2
    echo "[SkillGuard] 原始命令：$BASH_CMD" >&2
    exit 2
fi

# ── 快速通道判断（官方技能跳过审查）───────────────────────────
is_trusted_source() {
    local src="$1"
    local org_repo="${src%%@*}"
    local skill_name="${src##*@}"

    if [[ ! "$skill_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 1
    fi

    case "$org_repo" in
        "anthropics/skills")
            return 0
            ;;
        "vercel-labs/ai-sdk-skills")
            return 0
            ;;
    esac
    return 1
}

if is_trusted_source "$SKILL_SOURCE"; then
    echo "[SkillGuard] 官方技能快速通道：$SKILL_SOURCE，跳过审查。" >&2
    exit 0
fi

# ── 审查通过凭证检查（防止重复审查死循环）──────────────────────
if has_valid_approval "$SKILL_SOURCE"; then
    echo "[SkillGuard] 审查凭证有效，放行安装：$SKILL_SOURCE（凭证已消费）" >&2
    exit 0
fi

# ── 非官方来源：启动隔离审查流水线 ──────────────────────────────
echo "[SkillGuard] 拦截到技能安装请求：$SKILL_SOURCE" >&2
echo "[SkillGuard] 非官方来源，启动隔离审查流水线..." >&2

# 调用审查主控脚本
bash "$AUDIT_SCRIPT" "$SKILL_SOURCE" "$SKILL_NAME"
AUDIT_EXIT=$?

# 根据审查结果决定是否放行
case $AUDIT_EXIT in
    0)
        # SAFE：审查通过，颁发凭证
        grant_approval "$SKILL_SOURCE"
        echo "[SkillGuard] 审查通过，已颁发安装凭证：$SKILL_SOURCE" >&2
        echo "[SkillGuard] 请告知 Claude「继续安装」以执行原始命令（凭证一次性）" >&2
        # 本次仍拦截，用户确认后 Claude 重新执行 → 凭证有效 → 自动放行
        exit 2
        ;;
    3)
        # WARN：有警告，等待用户决定
        echo "[SkillGuard] 审查有警告，等待用户确认。" >&2
        echo "[SkillGuard] 用户确认「释放」后，Claude 重新执行安装命令即可。" >&2
        local approval_hash
        approval_hash=$(echo -n "$SKILL_SOURCE" | compute_sha256 /dev/stdin 2>/dev/null || echo -n "$SKILL_SOURCE" | sha256sum 2>/dev/null | cut -d' ' -f1)
        echo "[SkillGuard] 手动颁发凭证：echo \$(date +%s) > \"$APPROVED_DIR/$approval_hash\"" >&2
        exit 2
        ;;
    *)
        # FAIL / MALICIOUS：拒绝安装
        echo "[SkillGuard] 安装已被拒绝：$SKILL_SOURCE" >&2
        exit 2
        ;;
esac
