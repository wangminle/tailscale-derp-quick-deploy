# 更新日志

## [2.0.3] - 2026-01-25

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

## [2.0.2] - 2025-12-26

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

## [2.0.0] - 2025-11-10

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

1. **[账户与安全策略详解](docs/ACCOUNT_AND_SECURITY.md)**
   - 三种账户模式对比
   - 安全级别详解
   - 常见故障处理
   - 最佳实践清单

2. **[测试套件](tests/README.md)**
   - 集成测试脚本
   - 10+ 测试用例
   - CI 集成示例

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

## [2.0.1] - 2025-11-10

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

> 说明：上述代码层微调均为向后兼容性更新，不改变 2.0.0 的功能边界，仅修正文案与默认策略表述，并强化参数校验。

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
| 测试 | 无 | 集成测试套件 |

---

**贡献者**：感谢架构师的专业建议  
**更新日期**：2026-01-25  
**版本**：2.0.3
