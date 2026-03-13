# 记忆检查点 2026-03-13

## 恢复指令
> 新会话开始时说："读取 20260313-checkpoint.md 恢复上下文"

---

## 一、项目概况

- **项目名**: SkillGuard（Claude Code 技能安装安全审查流水线）
- **路径**: `D:\Xuxianbang-Skills\SkillGuard`
- **背景**: ClawHavoc 事件（2026年2月，1184个恶意技能包）后的防御方案
- **核心文件**:
  - `skillguard-gate.sh` — PreToolUse Hook 拦截器（检测技能安装命令，触发审查）
  - `skillguard-audit.sh` — 审查主控脚本（Layer 0-3 四层扫描）
  - `README.md` — 策略文档（五层防御流程、信任层级、工具使用详情）
  - `memories.txt` — 上上次会话的审查日志（可参考但已过时）

## 二、环境信息

| 组件 | 状态 | 备注 |
|------|------|------|
| Windows 11 家庭版 | ✅ | **不支持 Windows Sandbox** |
| WSL2 + Ubuntu | ✅ | 用户名 xuxianbang |
| Docker Desktop | ✅ 29.2.1 | WSL2 后端 |
| Docker Sandbox (microVM) | ✅ | `docker sandbox ls` 验证 |
| 火绒安全 | ✅ | `C:\Program Files\Huorong\Sysdiag\bin\HipsMain.exe` |
| Windows Sandbox | ❌ | 家庭版限制，Layer 3 需改为 Docker Sandbox |

## 三、已完成的安全审查（5代理团队）

### 审查团队配置
- 4 个 Sonnet 研究代理（layer0/layer1/layer23/gate）+ 1 个 Opus 终审代理
- 全部已关闭并清理（TeamDelete 完成）

### 审查结果汇总：39 个问题

| 级别 | 数量 | 影响 |
|------|------|------|
| CRITICAL | 8 | 流水线完全失效，可被任意绕过 |
| HIGH | 16 | 大量攻击模式遗漏，隔离不完整 |
| MEDIUM | 15 | 健壮性、边缘情况 |

### 已验证 CVE
- CVE-2025-59536 (CVSS 8.7) — Claude Code hooks/MCP bypass
- CVE-2026-21852 (CVSS 5.3) — Claude Code API key exfiltration
- CVE-2025-9074 (CVSS 9.3) — Docker Desktop 本地 API 暴露
- CVE-2025-31133/52565/52881 — runc 容器逃逸
- CVE-2025-55284 — Claude Code DNS 外传
- CVE-2025-66032 — Claude Code deny list 绕过

### 三条跨层攻击链
1. **Write 工具全绕过**: Prompt Injection → Claude 用 Write 工具 → skillguard-gate.sh 不拦截 → 恶意文件直接落盘
2. **命令注入 + 主机降级**: 恶意技能名含 shell 元字符 → 未验证 → 未引号 → Docker 不可用降级主机
3. **信任前缀伪造**: anthropics/skills@evil → 前缀匹配通过 → 零检查安装

### 四个根本性架构缺陷
1. 客户端安全模型（攻击者控制输入 = 可指令绕过）
2. 无加密完整性验证（无 hash/签名）
3. 单点防御（skillguard-gate.sh 仅覆盖 Bash 工具）
4. 无运行时监控（安装后无行为监控）

## 四、修复进度

### ✅ Phase 0: 紧急修复（已完成）
| 修复 | 对应问题 | 状态 |
|------|----------|------|
| check_pattern() 参数错位 | C-01 | ✅ 函数改用 shift，6 项检测全部恢复 |
| $SKILL_SOURCE 命令注入 | C-03 | ✅ 白名单验证 `^[a-zA-Z0-9_./@-]+$` + Docker 内引号 |
| Docker 降级为主机执行 | C-04 | ✅ 不可用时 exit 1 中止 |
| is_trusted_source 前缀伪造 | C-05 | ✅ case 精确白名单 + 字符验证 |
| grep -P 不可用时零宽检测 | BUG-2 | ✅ python3 降级方案 |

### ✅ Phase 1: 核心加固（已完成）
| 修复 | 对应问题 | 状态 |
|------|----------|------|
| Unicode Tag 字符检测 (U+E0000-E007F) | C-06 | ✅ python3 遍历 |
| BiDi 双向控制字符检测 | M-10 | ✅ python3 遍历 |
| Markdown 图片外传检测 | C-07 | ✅ grep regex |
| MCP Tool 描述注入检测 | C-08 | ✅ grep regex |
| 中文指令覆盖检测 | H-13 | ✅ grep regex |
| 日韩俄指令覆盖检测 | H-13 | ✅ grep regex |
| Base64 混淆注入检测 | H-14 | ✅ grep regex |
| .claude/settings.json Hook 注入 | H-15 | ✅ find + grep |
| DNS 外传命令检测 | 补充 | ✅ grep regex |
| 反向 Shell 模式检测 | 补充 | ✅ grep regex |
| L1 判定逻辑改为按严重性 | M-03 | ✅ L1_HAS_CRITICAL 标志 |
| Docker --security-opt no-new-privileges | H-06 | ✅ |
| Docker --pids-limit 100 | H-07 | ✅ |
| Docker --user 1000:1000 | H-08 | ✅ |
| Docker --tmpfs /dev/shm 限制 | M-07 | ✅ |
| is_skill_install 正则扩展 | H-11 | ✅ npm exec/yarn dlx/pnpm dlx/直接路径 |

### ✅ Phase 2: 架构升级（已完成 2026-03-14）
| 修复 | 对应问题 | 状态 |
|------|----------|------|
| skillguard-write.sh（Write/Edit Hook 守卫） | C-02 | ✅ 拦截 7 类敏感路径 + 内容注入检测 |
| SHA256 完整性验证 | 架构 | ✅ 安装前基线 + 安装后校验 + 新增 Hook 检测 |
| Layer 3 → Docker Sandbox microVM | H-09 | ✅ 全自动：安装→日志→行为分析→销毁 |
| Windows 版本检测 + 火绒多路径 | H-09/H-03 | ✅ 自动检测环境 |
| CVE 版本预检 | 架构 | ✅ Docker/runc/Node.js 版本检查 |

### ✅ Phase 3: 持续改进（已完成 2026-03-14）
| 修复 | 状态 |
|------|------|
| Homoglyph 混淆字符检测（40+ Cyrillic/Greek/Fullwidth 映射） | ✅ |
| RAG 文档投毒检测（Frontmatter/CSS隐藏/Data URI/伪造系统消息） | ✅ |
| CVE 版本预检（Docker CVE-2025-9074 / runc CVE-2025-31133 / Node LTS） | ✅ |
| 红队测试套件（10 个样本 + run-tests.sh，10/10 通过） | ✅ |
| 环境变量外传检测 + 多层编码混淆检测 | ✅ |

### ✅ v5.1 BUG 修复（2026-03-14）
| 修复 | 说明 |
|------|------|
| 审查通过凭证机制 | 修复审查后重新安装的死循环 BUG |
| `.approved/` 凭证目录 | SHA256 哈希文件名 + 30 分钟时效 + 自动清理 |
| SAFE → 自动颁发凭证 | 用户确认后 Claude 重新执行即放行 |
| WARN → 需手动颁发 | 用户说「释放」后 Claude 执行颁发命令 |
| FAIL → 不颁发 | 恶意技能永远无法获得凭证 |

## 五、当前安全评分

| 阶段 | 评分 | 说明 |
|------|------|------|
| 初始（Phase 0 前） | 2/10 | Layer 1 全部失效，命令注入，降级绕过 |
| Phase 0 完成后 | ~5/10 | 检测恢复工作，注入消除，降级关闭 |
| Phase 1 完成后 | ~7/10 | 检测 6→16 项，Docker 加固，正则扩展 |
| Phase 2 完成后 | ~8.5/10 | 多工具 Hook + 完整性验证 + Layer 3 重建 |
| Phase 3 完成后 | ~9/10 | 24+ 检测项 + CVE预检 + 红队测试 + 凭证机制 |

## 六、关键技术细节（快速恢复用）

### check_pattern 新签名
```bash
check_pattern() {
    local desc="$1"
    shift
    result=$(grep "$@" "$SKILL_FILES" 2>/dev/null || true)
}
# 调用：check_pattern "描述" -rniE '正则表达式'
```

### Docker 容器完整参数
```bash
docker run --rm \
    --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --pids-limit 100 --user 1000:1000 --memory 256m \
    --tmpfs /tmp:size=10m,noexec --tmpfs /dev/shm:size=1m,noexec \
    -v "$SKILL_FILES:/scan:ro" skillguard
```

### 输入验证
```bash
[[ ! "$SKILL_SOURCE" =~ ^[a-zA-Z0-9_./@-]+$ ]] && exit 1
[[ ! "$SKILL_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && exit 1
```

### is_trusted_source 精确白名单
```bash
case "$org_repo" in
    "anthropics/skills") return 0 ;;
    "vercel-labs/ai-sdk-skills") return 0 ;;
esac
```

### 审查通过凭证机制（v5.1 新增）
```bash
# 凭证目录
.approved/
├── <sha256-of-source-1>   # 内容: Unix timestamp
└── <sha256-of-source-2>   # 30 分钟后自动清理

# 流程：审查 SAFE → grant_approval() → 用户确认 → Claude 重新执行 → has_valid_approval() → exit 0
```

## 七、下次会话立即执行

1. 读取此文件恢复上下文
2. Phase 0-3 + v5.1 全部完成，安全评分 ~9/10
3. 可选继续 **Phase 4+**（见 README.md 第 10 节迭代路线图）：
   - LLM-based 检测层（PromptArmor）
   - mcp-scan 集成
   - PostToolUse 监控 Hook
   - CI 自动化红队测试
3. 验证所有修改：`bash -n skillguard-audit.sh && bash -n skillguard-gate.sh`
4. 更新 README.md 反映 v4.0 的变更
