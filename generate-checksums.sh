#!/bin/bash
# generate-checksums.sh
# 生成 SkillGuard 核心脚本的 SHA256 校验和 Manifest
# 用途：每次发版前运行，更新 checksums.sha256

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/checksums.sha256"

# 核心脚本列表（需要完整性保护的文件）
CORE_FILES=(
    "skillguard-gate.sh"
    "skillguard-audit.sh"
    "skillguard-write.sh"
    "一键配置.sh"
    "run-tests.sh"
    "Dockerfile.skillguard"
    "update.sh"
)

echo "=== SkillGuard 校验和生成 ==="
echo ""

# 生成 Manifest
> "$MANIFEST"
for file in "${CORE_FILES[@]}"; do
    filepath="$SCRIPT_DIR/$file"
    if [ -f "$filepath" ]; then
        hash=$(sha256sum "$filepath" | cut -d' ' -f1)
        echo "$hash  $file" >> "$MANIFEST"
        echo "  ✅ $file → ${hash:0:16}..."
    else
        echo "  ⚠️  $file 不存在，跳过"
    fi
done

echo ""
echo "Manifest 已写入：$MANIFEST"
echo "共 $(wc -l < "$MANIFEST") 个文件"
echo ""
echo "下一步：提交 checksums.sha256 到 Git 仓库"
