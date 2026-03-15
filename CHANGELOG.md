# SkillGuard Changelog

所有版本的功能更新和 Bug 修复记录。

---

## [5.6.2] - 2026-03-15

### 修复
- **安装脚本 hooks 写入无验证**（CRITICAL）：`一键配置.sh` 写入 hooks 后从未回读 `settings.json` 确认写入成功，导致脚本报告"配置完成"但 hooks 实际缺失。新增回读验证步骤，逐一确认 Bash/Write/Edit 三个 PreToolUse hook 存在
- **最终状态报告编造**（CRITICAL）：Docker、火绒、Sandbox 等组件状态基于中间变量假设，而非安装完成后实际运行命令确认。最终汇总改为重新执行 `docker info`、`Get-Process`（火绒）、`docker images`、`docker sandbox ls` 等命令获取真实状态
- **非交互模式缺失**（HIGH）：Docker 镜像构建和红队测试的 `read -p` 交互提示在 Claude Code Bash 工具中无法使用，导致自动安装被阻塞。新增 `--yes` / `-y` 参数跳过所有交互提示
- **Hook 目标文件验证**：回读验证后额外检查 hook 路径指向的 `.sh` 文件是否确实存在
- **火绒检测增强**：最终验证使用 PowerShell `Get-Process` 检查火绒进程是否实际运行，而非仅检查文件是否存在

### 改进
- 安装脚本用法更新：`bash 一键配置.sh --yes`（非交互自动安装）
- 最终报告明确标注"以下均为运行命令确认，非假设"

---

## [5.6.1] - 2026-03-15

### 修复
- **跨平台 SHA256 校验失败**（CRITICAL）：Windows Git 默认 `core.autocrlf=true` 将 LF 转为 CRLF，导致文件哈希改变、完整性校验失败，用户无法安装
- **行尾归一化**：`compute_sha256()` 和 `generate-checksums.sh` 现在先 `tr -d '\r'` 再计算哈希，确保 Windows/Linux/macOS 一致
- **添加 `.gitattributes`**：强制 `*.sh` 和 `checksums.sha256` 使用 LF 行尾（`eol=lf`），从 Git 层面杜绝行尾问题
- **仓库行尾混乱**：归一化所有 `.sh` 文件为 LF（此前 `uninstall.sh` 为 CRLF，其余为 LF）
- **Python 检测误判**（HIGH）：Windows 的 `python3` 可能是 Microsoft Store 重定向 stub（exit code 49），所有脚本改为先 `--version` 验证再使用，覆盖 6 个文件 8 处调用

---

## [5.6] - 2026-03-15

### 安全修复
- **白名单注释绕过**（CRITICAL）：自身命令白名单从字符串包含改为精确 SkillGuard 目录路径匹配，防止 `cmd #skillguard` 绕过
- **rm 白名单过宽**（CRITICAL）：删除命令只匹配精确的 SkillGuard 安装目录路径
- **路径遍历绕过**（HIGH）：write.sh 路径规范化增加 `..` 和 `.` 解析，防止 `../../.claude/settings.json` 绕过
- **Python 路径注入**（MEDIUM）：uninstall.sh 的 Python 代码改用 sys.argv 传递路径，防止单引号注入

### 修复
- **VERSION_FILE 未定义崩溃**（CRITICAL）：`VERSION_FILE` 定义从第 191 行移到第 31 行（`verify_self_integrity()` 之前）
- **stdout 污染**（P0）：所有 echo 输出改为 stderr（`>&2`），stdout 保持纯净（Claude Code 要求 stdout 为纯 JSON）
- **exit 1→exit 2**：所有阻塞操作从 `exit 1` 改为 `exit 2`（Claude Code 官方推荐的阻塞 exit code）
- **macOS sha256sum**（HIGH）：新增 `compute_sha256()` 函数，自动 fallback 到 `shasum -a 256`
- **is_skill_install 大小写**（HIGH）：技能安装检测改为 `grep -qiE`（大小写不敏感）
- **sed BSD 兼容**（HIGH）：所有 `sed` 使用 POSIX 兼容语法（`[[:space:]]` 替代 `\s`，`[[:space:]]*` 替代 `\+`）
- **Linux Docker sudo 挂起**（MEDIUM）：移除 `sudo systemctl`，改为无 sudo 尝试，失败时提示用户手动操作
- **/tmp 跨平台**（MEDIUM）：使用 `${TMPDIR:-/tmp}` 替代硬编码 `/tmp`
- **hook 超时**（P1）：Bash hook 配置添加 `timeout: 300000`（300 秒），防止审查流水线被 60 秒默认超时中断
- **EXIT trap**（LOW）：gate.sh 添加 `trap cleanup EXIT` 清理孤儿后台进程
- **set -e 移除**（HIGH）：gate.sh 改用 `set -uo pipefail`（不含 `-e`），防止后台进程导致意外退出

### 改进
- write.sh 的 Edit 工具现在提取 `old_string` 用于精确的卸载意图识别
- gate.sh `is_skillguard_self_command()` 函数封装白名单逻辑，更易维护

---

## [5.5] - 2026-03-15

### 修复
- **Bug #1 首次安装拦截**：`grep -P`（Perl 正则）在 Windows 中文系统 GBK locale 下报错，改为 `sed` 兼容写法
- **Bug #1 Python 兼容**：`一键配置.sh` 和 `update.sh` 的 `python3` 改为 `python3/python` 自动探测（Windows Git Bash 只有 `python`）
- **Bug #2 Docker 自动启动**：会话首次触发时自动检测并拉起 Docker Desktop（已安装未运行→自动启动；未安装→提示安装并说明需重启电脑）
- **Bug #3 卸载被自身拦截**：`gate.sh` 添加 SkillGuard 自身命令白名单放行；`write.sh` 识别卸载 settings.json 写入并放行
- **远程校验误判**：新版本推送后，旧版本用户不再因远程哈希不匹配而误判为"文件被篡改"，改为提示更新
- **版本提示可见性**：更新提示从 stderr 改为 stdout，确保 Claude Code hook 输出对用户可见

### 新功能
- `uninstall.sh` 一键卸载脚本：移除 hooks + 清理临时文件 + 提示删除目录
- `gate.sh` SkillGuard 自身命令白名单：安装/更新/卸载相关命令自动放行

---

## [5.4] - 2026-03-15

### 新功能
- 自动更新检查：每次会话首次触发时从 GitHub 检测新版本，提示用户更新
- `update.sh` 一键更新脚本：`git pull` + 重新生成 checksums + 重新配置 Hook
- `CHANGELOG.md` 结构化更新日志：更新后自动输出新功能和修复内容
- `VERSION` 文件：本地版本号管理

### 改进
- `skillguard-gate.sh` 新增会话级版本检查（6 小时一次，3 秒超时，不阻塞正常使用）
- `generate-checksums.sh` 核心文件列表新增 `update.sh`
- README 新增「更新」章节，文档更新至 v5.4

---

## [5.3] - 2026-03-14

### 新功能
- 六层自保护体系：Hook 自保护 + SHA256 自检 + 远程哈希校验 + SLSA L3 + AGPL-3.0 + Release SHA256
- SLSA Level 3 供应链安全：GitHub Artifact Attestations + Sigstore 签名
- `generate-checksums.sh` 校验和生成脚本
- AGPL-3.0 开源许可证
- `.github/workflows/` CI/CD 工作流（构建 + 发布）

### 改进
- `skillguard-gate.sh` 新增远程完整性校验（从 GitHub 拉取官方哈希对比）
- `skillguard-write.sh` 新增 SkillGuard 自身文件写入保护

---

## [5.2] - 2026-03-14

### 新功能
- 一次性凭证机制：审查通过后颁发凭证，使用后立即删除
- `.approved/` 凭证目录：SHA256(source) → timestamp

### 改进
- 凭证 5 分钟自动过期清理
- 凭证颁发消息优化

---

## [5.1] - 2026-03-13

### 新功能
- 凭证放行机制（初版）
- `skillguard-audit.sh` v5.0 审查主控脚本（24+ 检测项）

### 改进
- Layer 1 扫描项扩展至 24+（含 Homoglyph、RAG 投毒、多层编码）

---

## [5.0] - 2026-03-13

### 新功能
- 四层防御流水线：火绒 AV + 语义扫描 + Docker 代码扫描 + microVM 动态测试
- `skillguard-gate.sh` PreToolUse Hook 拦截器
- `skillguard-write.sh` Write/Edit 守卫
- `一键配置.sh` 一键安装脚本（环境检测 + Hook 配置）
- `run-tests.sh` 红队测试运行器（10 个攻击样本）
- 白名单机制：`anthropics/skills` 和 `vercel-labs/ai-sdk-skills` 自动放行
