#!/bin/bash
# run-tests.sh
# SkillGuard 红队测试运行器 — 验证 Layer 1 检测流水线
# 用法：bash run-tests.sh
#
# 对 test-fixtures/ 下的每个文件运行 Layer 1 检测逻辑（抽取自 skill-audit.sh），
# 验证：
#   - 01-clean-skill.md → 应该 PASS（0 issues）
#   - 02~10 → 应该检测到至少 1 个问题
#
# 不启动 Docker / 火绒 / Sandbox，仅验证 Layer 1 检测能力

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/test-fixtures"

if [ ! -d "$FIXTURES_DIR" ]; then
    echo "❌ test-fixtures/ 目录不存在"
    exit 1
fi

TOTAL=0
PASSED=0
FAILED=0

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Layer 1 检测能力红队测试"
echo "  测试样本目录：$FIXTURES_DIR"
echo "═══════════════════════════════════════════════════════"
echo ""

for fixture in "$FIXTURES_DIR"/*.md; do
    [ -f "$fixture" ] || continue
    TOTAL=$((TOTAL+1))
    BASENAME=$(basename "$fixture")
    ISSUES=0

    # ── 运行所有 Layer 1 检测 ────────────────────────────

    # HTML 注释隐藏指令
    grep -rniE '<!--.*--(execute|send|read|fetch|POST|ignore|override|system|admin)' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # 权威+紧迫语言组合
    grep -rniE '(system|admin|critical|urgent).{0,50}(immediately|always|must|override)' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # 凭证关键词
    grep -rniE 'API_KEY|ANTHROPIC_KEY|Bearer|private[._]key' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # 指令覆盖
    grep -rniE 'ignore previous|override instruction|disregard|higher priority' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # 外传域名
    grep -rniE 'webhook\.site|pipedream\.net|requestbin|ngrok\.io|burpcollaborator|interact\.sh' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # Markdown 图片外传
    grep -rniE '!\[.*\]\(https?://[^)]{5,}\)' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # MCP 工具描述注入
    grep -rniE '"description"[^"]{0,20}"[^"]{0,300}(ignore|override|execute|fetch|read file|send|POST|exfil)[^"]{0,100}"' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # 中文指令覆盖
    grep -rniE "忽略.{0,20}(之前|上面|前面|以上)|覆盖.{0,20}指令|系统.{0,20}提示|无视.{0,20}(规则|限制)" "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # 日韩俄指令覆盖
    grep -rniE "前の指示を無視|이전 지시를 무시|игнорируй предыдущие" "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # Base64 混淆注入
    grep -rniE '(decode|base64|atob|btoa|b64decode).{0,100}(execute|run|eval|system|exec)' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # Hook 注入模式（settings.json + hooks + command 组合）
    grep -rniE '"hooks".*"(Pre|Post)ToolUse"|"command".*curl.*\|.*base64|hooks.*command.*exfil' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # DNS 外传命令
    grep -rniE '(ping|dig|nslookup|host)\s+.{0,50}\.(com|net|io|xyz|top)' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # 反向 Shell 模式
    grep -rniE 'bash\s+-i.*(/dev/tcp|/dev/udp)|nc\s+(-e|--exec)|mkfifo.*nc|python.*socket.*connect' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # Frontmatter 隐藏指令
    grep -rniE '^---[\s\S]{0,500}(system_prompt|instruction|role|persona|ignore|override)' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # CSS 隐藏文本
    grep -rniE '(display:\s*none|visibility:\s*hidden|font-size:\s*0|opacity:\s*0).{0,200}(ignore|override|execute|system|instruction)' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # Data URI
    grep -rniE 'data:(text|application)/(html|javascript|x-python)[;,]' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # 伪造系统消息
    grep -rniE '(\[SYSTEM\]|\[system\]|<\|im_start\|>system|<system>|role.*system.*content)' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # 环境变量外传到 URL
    grep -rniE '(ANTHROPIC|OPENAI|AWS|GITHUB|SLACK|DISCORD)_[A-Z_]*.*https?://' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # 多层编码混淆
    grep -rniE '(atob|btoa|base64|hex|charCodeAt|fromCharCode|encodeURI|decodeURI).{0,80}(atob|btoa|base64|hex|charCodeAt|fromCharCode|eval|exec)' "$fixture" &>/dev/null && ISSUES=$((ISSUES+1))

    # Python 检测（零宽/Unicode Tag/BiDi/Homoglyph）需要 python3
    if command -v python3 &>/dev/null; then
        PYCHECK=$(python3 -c "
import sys
text = open(sys.argv[1], 'r', encoding='utf-8', errors='ignore').read()
issues = 0
# Zero-width
if any(c in text for c in '\u200b\u200c\u200d\ufeff\u200e\u200f\u2060'):
    issues += 1
# Unicode Tags
if any('\U000E0000' <= c <= '\U000E007F' or '\uFE00' <= c <= '\uFE0F' for c in text):
    issues += 1
# BiDi
bidi = set('\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069\u200E\u200F\u061C')
if any(c in bidi for c in text):
    issues += 1
# Homoglyph (sample)
confusables = set('\u0410\u0412\u0421\u0415\u041D\u041A\u041C\u041E\u0420\u0422\u0425\u0430\u0435\u043E\u0440\u0441\u0443\u0445\u0455\u0456\u0458')
if any(c in confusables for c in text):
    issues += 1
print(issues)
" "$fixture" 2>/dev/null || echo "0")
        ISSUES=$((ISSUES + PYCHECK))
    fi

    # ── 判断期望结果 ────────────────────────────────
    # 01-clean 应该 0 issues，其余应该 >= 1
    if [[ "$BASENAME" == "01-clean"* ]]; then
        if [ $ISSUES -eq 0 ]; then
            echo "  ✅ $BASENAME → PASS (0 issues, expected: clean)"
            PASSED=$((PASSED+1))
        else
            echo "  ❌ $BASENAME → FAIL ($ISSUES issues, expected: 0 = false positive!)"
            FAILED=$((FAILED+1))
        fi
    else
        if [ $ISSUES -ge 1 ]; then
            echo "  ✅ $BASENAME → DETECTED ($ISSUES issues found)"
            PASSED=$((PASSED+1))
        else
            echo "  ❌ $BASENAME → MISSED (0 issues, expected: >= 1 = detection gap!)"
            FAILED=$((FAILED+1))
        fi
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  结果：$PASSED/$TOTAL 通过 | $FAILED 失败"
if [ $FAILED -eq 0 ]; then
    echo "  ✅ 所有检测样本验证通过"
else
    echo "  ❌ 存在检测缺口，请检查上述 MISSED 项"
fi
echo "═══════════════════════════════════════════════════════"
echo ""

exit $FAILED
