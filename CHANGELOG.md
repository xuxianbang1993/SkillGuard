# SkillGuard Changelog

所有版本的功能更新和 Bug 修复记录。

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
