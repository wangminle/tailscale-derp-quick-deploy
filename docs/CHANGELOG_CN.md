# 更新日志

## [0.2.6] - 2026-06-15

### 🔧 Bug 修复

1. **derper 与 tailscaled 版本对齐（verify-clients）**
   - 启用 `-verify-clients` 时，若未显式指定 `--derper-version`，自动将 derper 对齐到本机已安装的 tailscale 版本（安装 `derper@v<TS版本>`），确保二者同源构建，避免本地 API 协议不兼容导致客户端校验异常。
   - 上游要求 derper 与 tailscaled 来自同一 Git revision；可用 `--derper-version` 显式覆盖；检测不到 tailscale 版本时保留 `latest` 并给出提示。

2. **幂等部署漏检在线旧证书**
   - 主流程状态采集新增"在线证书 vs 磁盘证书"指纹一致性校验，并将其纳入 `service_needs_reconcile`：外部替换了磁盘证书但 derper 未重启时，重跑会触发重启以加载新证书，避免服务继续提供旧证书。
   - `--health-check` 的退出码与摘要已反映在线证书状态。

3. **配置匹配校验 `-socket` 实际路径**
   - `unit_matches_desired_config` 现在不仅检查 `-socket` 是否存在，还核对其与本机探测到的 tailscaled socket 路径一致；错误的 socket 路径不再被误判为"配置一致"导致 verify-clients 静默失效。

4. **README 文档同步**
   - 修正示例 `RUN_USER="${SUDO_USER:-$USER}"` 为 `${SUDO_USER:-${USER:-$(id -un)}}`，与脚本一致（避免 `set -u` 下 `$USER` 未绑定）。
   - 更正 `--repair` 描述：会重启 derper 服务（仅重写配置/证书，不重装 derper/Go），原"不中断服务"表述不准确。

### 🧪 测试

- 回归测试扩展至 19 项，新增覆盖：`-socket` 路径漂移检测、在线证书过期触发协调、derper 版本自动对齐。

---

## [0.2.5] - 2026-06-14

### 🔧 Bug 修复

1. **最小环境与交互健壮性**
   - 修复 `USER` 未导出时在 `set -u` 下加载脚本即崩溃的问题，统一回退到 `id -un`。
   - 所有交互式 `read` 均安全处理 EOF，避免向导、Go 安装确认和 tailscaled 重启确认触发未绑定变量错误。

2. **derper 配置与客户端校验正确性**
   - systemd `ExecStart` 和手动运行示例始终通过 `-c /opt/derper/derper.json` 指定节点私钥配置。
   - 自动移除旧的空 `{}` 配置，让 derper 首次启动时生成有效节点私钥，同时保留已有有效配置。
   - `-verify-clients` 改为使用 derper 实际支持的 `-socket` 参数，不再依赖无效的 `TS_LOCAL_API_SOCKET` 环境变量。
   - 当当前 derper 不支持 `-stun-port` 时，拒绝自定义 STUN 端口，避免实际监听端口与配置、防火墙提示不一致。

3. **幂等修复与证书健康检查**
   - 证书续签、二进制重装、服务停止或目标端口未监听时，会重新协调并重启 derper，确保新文件立即生效。
   - 修复证书 SAN 检查未转义 IPv4 点号造成的误匹配。
   - 健康检查新增在线证书与磁盘证书指纹一致性校验，避免服务仍提供旧证书时产生假阳性。

4. **平台兼容与安全写入**
   - RHEL 系发行版支持通过 `update-ca-trust extract` 刷新 CA。
   - Prometheus textfile 改用同目录安全随机临时文件，避免固定 `.tmp` 路径带来的并发写入和符号链接风险。
   - 备用 `InsecureForTests` ACL 片段改为使用本次请求的 Region、IP 和 DERP 端口。
   - 新增 `.gitattributes`，强制 `.sh` 文件使用 LF 行尾。

### 🧪 测试

- 回归测试扩展至 16 项，新增覆盖：未设置 `USER`、运行状态协调、`-c`/`-socket` 参数、空配置迁移、自定义 STUN 端口拒绝、ACL 参数、向导 EOF、SAN 精确匹配、在线证书一致性和安全指标写入。
- `bash -n`、`git diff --check` 和 LF 行尾检查通过。

---

## [0.2.4] - 2026-05-19

### 🔧 Bug 修复

1. **恢复脚本可执行性**
   - 将部署脚本恢复为 LF 行尾，修复 CRLF 导致 `bash -n` 和 `--help` 无法运行的问题。

2. **幂等与修复逻辑增强**
   - 默认跳过安装前会检查 unit 是否与本次目标参数一致，包括 IP、DERP/STUN 端口、运行用户、安全级别和客户端校验。
   - `--repair` / `--force` 允许当前 derper 服务占用目标端口，避免把自身监听误判为冲突。
   - 重写 systemd unit 后会 restart 已运行服务，确保证书和 ExecStart 变更立即生效。

3. **健康检查和指标修正**
   - `--health-check` 将配置漂移、证书异常纳入非 0 退出条件。
   - Prometheus 增加 `derper_desired_config_ok`，`derper_verify_clients` 改为读取已部署 unit 的真实状态。

4. **卸载范围说明与清理补全**
   - `--uninstall --purge-all` 额外清理 `/etc/derper/derper.env` 和脚本创建的 tailscaled socket drop-in。
   - 防火墙规则和用户/组账户仍需人工确认，避免误删用户自维护配置。

### 🧪 测试

- 新增 `tests/test_deploy_script.sh`，覆盖 LF 行尾、脚本可 source、配置漂移检测和自身端口占用豁免。
- 当前仓库提供轻量回归测试脚本；尚未引入完整集成测试套件。

---

## [0.2.3] - 2026-01-25

### 🔧 Bug 修复

1. **参数缺值友好报错**
   - 修复 `--ip`、`--derp-port` 等需要值的参数如果忘记跟参数值时，脚本会因 `shift 2` 直接崩溃退出的问题
   - 新增 `require_arg_value()` 函数，对所有需要值的选项统一做缺参拦截并打印清晰错误 + usage
   - 现在会输出友好的 `[错误] 参数 --ip 需要一个值` 而不是神秘的 shift 错误

2. **IP 地址八进制解析问题**
   - 修复 IP 地址字段以 0 开头时（如 `192.168.08.1`）bash 算术运算将其解释为八进制导致的解析错误
   - `08` 或 `09` 这样的值会被 bash 认为是无效八进制而报错
   - 使用 `$((10#$octet))` 强制十进制解析，彻底避免此问题
   - 影响范围：`validate_settings()` 和 `deployment_wizard()` 中的 IP 校验逻辑

3. **`--security-level` 无效值处理**
   - 修复传入无效安全级别（如 `--security-level invalid`）时静默回退到 `standard` 的问题
   - 现在会明确报错：`[错误] 无效的安全级别：invalid` 并列出可选值

### 📝 技术细节

- 所有修改均为**向后兼容**，不改变现有参数和使用方式
- 语法检查 `bash -n` 通过
- 脚本总行数：约 2210 行

---

## [0.2.2] - 2025-12-26

### 🔧 Bug 修复

1. **`--check/--health-check` 模式容错改进**
   - 修复 `detect_public_ip()` 和 `validate_settings()` 内部使用 `exit` 导致无法继续输出后续检查信息的问题
   - 改为使用 `return` 交由调用方决定是否退出，`--check` 模式下即使探测失败也能输出完整诊断信息

2. **Prometheus 指标写入错误处理**
   - 修复 `--metrics-textfile` 在目标路径不可写时触发 `set -e` 直接退出的问题
   - `write_prometheus_metrics()` 改为失败返回错误码 + 输出警告，不再导致整个脚本中止
   - 调用方根据返回值决定是否打印"写入成功"或"写入失败"提示

3. **systemd unit 文件生成优化**
   - 修复空变量（如 `config_flag`、`verify_flag`）导致 ExecStart 行出现多余反斜杠续行的问题
   - 使用数组动态构建命令参数，生成更整洁的单行 ExecStart
   - 修复 `SupplementaryGroups` 为空时产生多余空行的问题

4. **变量作用域修复**
   - `socket_path` 变量提升到函数级别初始化，避免后续引用时潜在的未定义问题

### 🎨 用户体验改进

1. **`--check` 输出优化**
   - 公网 IP 为空时显示 `<未探测到>` 而非空白，避免误导用户

2. **向导模式 IP 验证增强**
   - IP 字段范围检查改为 `(( octet < 0 || octet > 255 ))`，逻辑更完整

### 📝 技术细节

- 所有修改均为**向后兼容**，不改变现有参数和使用方式
- 语法检查 `bash -n` 通过
- 脚本总行数：约 2180 行

---

## [0.2.0] - 2025-11-10

### 🎯 重大改进

#### 1. 智能账户管理 🆕

**新增参数**：
- `--dedicated-user`: 强制创建专用 derper 系统账户（生产推荐）
- `--use-current-user`: 使用当前用户运行（个人环境友好）

**智能行为**：
- 自动检测执行环境（sudo 用户 vs 真实 root）
- Root 直接执行会触发警告并提供安全建议
- 三种账户模式灵活适配不同场景

**权限处理**：
- 优先使用 systemd socket drop-in（最规范）
- 回退到 ACL（setfacl）
- 移除不安全的 chmod 666 自动回退
- 权限不足时提供清晰的四种解决方案

#### 2. 分级安全加固 🆕

**新增参数**：
- `--security-level {basic|standard|paranoid}`: 三级安全配置

**安全级别对比**：

| 级别 | 加固项数量 | 适用场景 | 兼容性 |
|------|-----------|---------|--------|
| **basic** | 3 项 | 旧系统、嵌入式 | 最高 |
| **standard** | 11 项 | 生产环境（推荐） | 良好 |
| **paranoid** | 15 项 | 高安全要求 | 需验证 |

**自动回退**：
- paranoid 级别启动失败时自动禁用 MemoryDenyWriteExecute
- 部署后显示 systemd 安全评分

#### 3. 配置向导模式 🆕

**新增子命令**：
```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh wizard
```

**特性**：
- 交互式问答引导配置
- 自动生成适合场景的部署命令
- 安全的模板替换（避免 eval 注入）
- 命令保存到 `derper_deploy_cmd.sh`

#### 4. 非交互模式 🆕

**新增参数**：
- `--yes`: 自动确认所有选择
- `--non-interactive`: 禁用所有交互提示

**适用场景**：
- CI/CD 管道
- Ansible/Terraform 等自动化工具
- 无人值守部署

#### 5. 环境变量配置管理 🆕

**新增功能**：
- 自动创建 `/etc/derper/derper.env` 模板
- systemd service 集成 `EnvironmentFile`
- 支持 Headscale 等第三方验证服务

**示例配置**：
```bash
# /etc/derper/derper.env
TS_AUTHKEY=tskey-auth-xxxxxx
DERP_VERIFY_CLIENT_URL=https://headscale.example.com/verify
```

#### 6. Socket 权限错误友好提示 🆕

**改进前**：
```
[警告] 将临时放宽 tailscaled socket 权限到 0666
```

**改进后**：
```
╔══════════════════════════════════════════════════════════════╗
║          ⚠️  tailscaled socket 权限不足                      ║
╚══════════════════════════════════════════════════════════════╝

推荐解决方案（按优先级排序）：

方案 1：使用 systemd socket 覆盖（最安全，持久化） ✅
  mkdir -p /etc/systemd/system/tailscaled.socket.d
  cat > /etc/systemd/system/tailscaled.socket.d/10-derper-localapi.conf <<'EOF'
[Socket]
SocketGroup=tailscale
SocketMode=0660
EOF
  ...

方案 2：使用 ACL（灵活，需 acl 包）
  ...

方案 3：使用当前用户运行 derper（简单，适合个人环境）
  ...

方案 4：临时放宽权限（不推荐，仅紧急情况）
  bash $0 --relax-socket-perms [其他参数]
```

### 📚 新增文档

1. **账户与安全策略详解**（计划中）
   - 三种账户模式对比
   - 安全级别详解
   - 常见故障处理
   - 最佳实践清单

### 🔧 参数变更

**新增参数**：
```bash
--dedicated-user          # 强制创建专用账户
--security-level LEVEL    # 安全级别：basic|standard|paranoid
--relax-socket-perms      # 允许放宽 socket 权限（显式开关）
--yes, --non-interactive  # 非交互模式
wizard                    # 向导子命令
```

**参数影响**：
- 移除了自动 `chmod 666` 的隐式行为
- `--relax-socket-perms` 必须显式指定才会放宽权限

### 🛡️ 安全改进

1. **移除危险的默认行为**
   - ❌ 不再自动 `chmod 666 tailscaled.sock`
   - ✅ 必须显式 `--relax-socket-perms` 才会放宽

2. **Root 执行警告**
   - 检测真实 root vs sudo 执行
   - 提供安全建议并要求确认
   - 非交互模式会直接报错退出

3. **systemd 加固增强**
   - 三级可选配置
   - 自动兼容性检测和回退
   - 部署后显示安全评分

4. **环境变量隔离**
   - 敏感配置独立文件管理
   - 权限 600，仅 root 可读写

### 🧪 测试覆盖

新增测试用例：
- ✅ 参数验证（IP、端口、安全级别）
- ✅ 三种账户模式
- ✅ 三级安全配置
- ✅ 非交互模式
- ✅ Socket 权限处理
- ✅ 向导模式入口

### 📖 文档更新

- 更新 README_cn.md 快速开始章节
- 新增向导模式说明
- 新增三种典型场景示例
- 链接到详细文档

### 🔄 向后兼容性

**完全兼容**：
- 所有现有参数保持不变
- 默认行为更安全但不影响正常使用
- 旧命令可继续工作

**行为变更**（更安全）：
- Socket 权限不足时不再自动放宽（需显式 `--relax-socket-perms`）
- 这是**有意的安全改进**，旧的自动行为存在风险

### 🎯 使用建议

**生产环境**：
```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <公网IP> \
  --dedicated-user \
  --security-level paranoid \
  --derp-port 443 \
  --auto-ufw \
  --yes
```

---

## [0.2.1] - 2025-11-10

本次为“文档与文案对齐”小版本，聚焦将首页精简、技术参考下沉，并同步脚本 usage 文案与默认策略。

### 📚 文档重构（重要）
- 新增精简版中文首页：`README.md`（聚焦目标、特性、三步部署与参数要点）。
- 迁移原技术长文：
  - 原英文 README.md → `docs/REFERENCE_EN.md`
  - 原中文 README_cn.md → `docs/REFERENCE_CN.md`
- 文案统一：默认“使用当前用户”；生产环境推荐 `--dedicated-user`。
- 示例与参数表与脚本现状对齐：
  - 新增“方案 A（当前用户）/方案 B（专用用户）/向导模式”三种路径。
  - 强调 `--security-level` 三级加固和国内网络镜像参数。
- 在参考文档中补充“非交互 root 默认切换为专用账户”的说明。

### 🧩 脚本与文档的一致性（微调）
- usage 文案：更新为“`--user` 默认=当前登录用户；`--use-current-user` 为默认行为”。
- IPv4 校验：`validate_settings()` 新增 0–255 分段校验（与向导一致）。
- 非交互 root：无 `SUDO_USER` 时默认等同 `--dedicated-user`，与文档说明一致。
- 向导执行：移除 eval，改为安全的参数数组执行（已在文档声明）。

> 说明：上述代码层微调均为向后兼容性更新，不改变 0.2.0 的功能边界，仅修正文案与默认策略表述，并强化参数校验。

**个人环境**：
```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh wizard
```

**CI/自动化**：
```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <公网IP> \
  --dedicated-user \
  --non-interactive \
  --yes
```

---

## [1.x] - 2025-10-xx

### 初始版本特性

- 基于 IP 的自签名证书
- 自动部署 derper 服务
- systemd 集成
- 健康检查和指标导出
- 幂等可重入设计
- 客户端验证支持

---

**对比总结**：

| 功能 | v1.x | v2.0 |
|------|------|------|
| 账户管理 | 固定创建 derper 用户 | 智能适配三种模式 |
| 安全加固 | 固定配置 | 三级可选 |
| Socket 权限 | 自动 chmod 666 | 规范方案 + 显式开关 |
| 用户体验 | 纯命令行 | 向导模式 + 命令行 |
| 自动化 | 需手动处理交互 | 非交互模式 |
| 文档 | 基础说明 | 详细文档 + 故障处理 |
| 测试 | 无 | 轻量回归测试脚本 |

---

**贡献者**：感谢架构师的专业建议

**更新日期**：2026-06-15

**版本**：0.2.6
