# 更新日志

## [Unreleased]

## [0.2.19] - 2026-10-27

- 固定 Ubuntu 22.04/24.04 矩阵补 root C/S2 权限证据与 Python 适配器回归；手动一次性 VM 入口启用 C/D 并保存日志/生成产物/清理记录，缺少真实二进制返回 2（未验收）。
- 新增 D 真实 systemd 维护场景及仅本机使用的 HTTP fixture，覆盖稳定副本、到期/撤权、真实 restart 失败恢复、反向补偿和停用；清理包含换证归档中的旧私钥。双 Ubuntu 22.04/24.04 一次性 VM 已实际执行，D 集成因 BUG-116 未通过（已在本版本修复，需重跑 VM 才能验收）；fixture 不等于云端 GD。
- 提供可选独立 Linux 合法客户端 H3 适配器与真实验收操作包；严格核对单节点 Region、控制面指纹/服务证书、真实转发路径及 STUN，直连/其他区域返回未知。真实 Tailnet/H3 与长效兼容仍待实测。
- 修复 BUG-116：定时 `maintain` 成功后不再被主入口重新登记为 `recorded` 并重装 unit，保留 `success_replaced` 结果与用户启用意图。
- 修复 BUG-117：默认幂等部署在未改动但健康检查失败（如 LocalAPI 已确认故障）时不再跳过发布门禁、继续成功收尾；门禁失败即非零退出。
- 修复 BUG-122：verify-clients 的 LocalAPI 检查按 derper unit 的 `User=` 判断 socket 访问；调用者（常为 root）可访问而服务用户被拒绝时记为确认故障，无法证明时记为未知，不再假健康。
- 修复 BUG-118：改变 `--cert-days` 不再复用旧有效期的候选；apply 同时核对 prepare 记录的有效期，参数漂移或候选已过期、剩余不足 1 小时时拒绝并要求重新 prepare。
- 修复 BUG-119：`maintain` 无法计算证书到期时间时非零退出，记录原因并标记需人工，不再伪装成“未到提前维护日期”的 `idle`。
- 修复 BUG-120：反向补偿只有在完整策略可解析且确认没有本节点时才跳过；重复 HostName、Region 不匹配、CertName 缺失、尾随垃圾、多个根对象或其他解析失败一律记录 `needs_coordination` 转人工。
- 修复 BUG-121：卸载不再吞掉维护 service/timer 删除或 `daemon-reload` 失败；删除后核对 unit 文件、启用状态与运行状态，失败时继续其余清理但最终非零且不报告“完成”。停用自动维护失败同样非零并记录 `scheduler_state=failed`。
- 新增并注册上述缺陷的回归（审查回归 3 项、D 阶段 19 项），其中 BUG-116/121 覆盖完整 CLI 结束状态。
- 修复 BUG-111：自动换证失败后，只有确认磁盘旧证书和原运行服务的实际旧指纹恢复，才撤回云端本节点指纹；恢复未确认时保留云端并记录待协调，定时入口保留具体原因。归档失败先恢复本地再补偿，原停止服务不被拉起。
- 修复 BUG-112：主回归在非条件子 shell 内启用失败退出，父进程累计失败；内层断言不再被末尾成功输出吞掉。新增故意失败副本回归，验证退出非零且后续用例继续执行。
- 修复 BUG-113：GNU/BSD 证书日期解析固定 C locale，中文环境不再把临期证书误判为未到维护日期。
- 修复 BUG-114：手动 systemd VM 任务显式导出最终 DERPER_TEST_BINARY，预检和集成脚本使用同一路径，保留显式路径和缺失时的未验证反馈。
- 实现 D2/D4 云端安全反向补偿（DEV-008）：自动换证本地切换失败且旧身份恢复经核验时，基于最新策略与 ETag 仅撤回本工具写入的 CertName 字段，不回写整份旧策略；他人已改目标、ETag 冲突或读回未确认一律停止并转人工协调。新增本地切换失败反向补偿与他人改动阻断两项先红后绿回归。
- CI 新增固定 Ubuntu 22.04/24.04 Bash 回归矩阵，并提供 systemd PID1 一次性 VM 手动任务入口（workflow_dispatch，需自托管 disposable VM runner）；固定平台矩阵暂未包含 root 专属用例补跑。经 CHK-046～051 验收与独立复验（主 108 条 ok、D 61、双 Bash 与 ShellCheck 通过）。
- 新增并注册上述缺陷回归，补齐反向补偿和维护失败边界说明；隔离 Tailnet 真写、真实 H3、长效兼容和生产验收仍独立待办。

## [0.2.18] - 2026-10-24

- 修复遗留节点配置引起的重复迁移停启（BUG-110）：当前配置与状态目录属主/组、0600/0700权限及可读性就绪时直接复用，保留遗留副本和外层恢复材料；首次迁移、权限修复、运行用户变更仍走受保护流程。已就绪配置的unit写入只保留最终发布重启。新增 4 项 S2 回归（先红后绿）。
- 修复带接口后缀的回环监听误报（BUG-109）：ss/netstat 识别 `127.0.0.53%lo:53` 及带后缀的 IPv6 回环格式，保留非回环地址告警。同步中英文 REFERENCE 的状态目录、AF_UNIX 加固片段及迁移旧密钥副本说明（DOC-015）。新增 3 项审查回归。
- 同源模块版本解析与 derper 下载/编译增加终端跳点、已等待秒数和阶段时限，结束后显示结果与耗时。日志重定向、简易终端和 JSON 模式保留静态提示；命令 stdout、错误详情与退出码保持独立。新增 2 项主套件回归（含伪终端实时读帧）。

## [0.2.17] - 2026-10-22

- 修复 BUG-101：缺少或仅有空白 `TS_TAILNET` 时不获取写授权，显式启用自动维护会报错且不安装 timer；部署配置或凭据文件提供的有效目标均可登记，并保存在定时配置中。配置文件中的 `CERT_LEAD_DAYS` 与 CLI 一样按显式值校验，越界拒绝，仍保留 CLI 覆盖和缺省短期证书收紧行为。规范 7 项已有缺陷回归名称，新增 5 项目标/提前天数回归。
- 修复验收重开项（BUG-104、BUG-107）：独立持久化调度结果，安装或启用失败跨命令、维护重试和授权恢复后仍保持未知并使部署收尾非零，成功重新启用或显式停用才解除；兼容旧失败记录。换证在更新云端指纹前和证书事务前均拒绝安装根目录符号链接。新增 4 项先红后绿回归。
- 新增 S4/D 阶段本地实现：`prepare`/`apply`/`cancel`/`maintain`。prepare 生成候选证书和本节点片段，不切换正在运行的服务；`--yes` 不能代替 `--accept-cert-rotation`。默认 365 天，长效仍用显式 `--cert-days`。
- 条件式自动维护：独立 root 凭据文件与 `derper-cert-maintain` timer；写授权、目标与调度齐全且显式 `--enable-auto-maintain` 才把 `mode=ready` 写入持久状态。`--disable-auto-maintain` 改回人工并删除 timer。GET/validate 成功不能证明可写。GitOps 标记拒绝双写。
- 策略适配用合成 HuJSON/HTTP 替身覆盖注释保留、旧指纹冲突、ETag 冲突、POST 超时先读回、他人改目标停止自动回退。失败只记本机 journal 和持久状态，不承诺零中断。隔离 Tailnet 真写与独立客户端复验仍待办。
- 修复证书事务与策略维护的本地缺陷（BUG-082～095）：成功 apply 归档旧证书，不再在下次命令自动回滚；首次登记保留原访问策略；OAuth JSON、ETag 和 HTTP 状态在同一次调用中传递；读回按节点身份取 CertName；apply 绑定 prepare 的目标；下一周期签发新证书；切换后核验服务和加载指纹；timer 启用成功后才记 ready，并保存节点与维护参数；临时授权未知不撤销已启用登记。
- 补齐维护安装的写入与调度边界（BUG-096～099）：维护 unit 和稳定脚本拒绝符号链接并原子替换；`target.conf` 保留内网放行、运行用户和客户端校验；`cancel` 在没有公网 IP 时仍可丢弃候选；每天的 `maintain` 不重复打印部署向导；`--purge-all` 删除维护副本。
- 继续收口换证与维护边界（BUG-100、BUG-102～108）：复制正式证书前拒绝符号链接；换证失败回滚后重新启动并验证原服务；`--disable-auto-maintain` 优先于历史授权；已就绪的 deploy 也会处理启停；timer 安装失败不再报已就绪；过期证书进入维护；未显式指定时，默认提前天数不会拒绝短于 30 天的证书。

## [0.2.16] - 2026-10-22

- 补齐首次安装直接恢复分支（BUG-067）：先确认停止，再清理二进制和标记；停止/恢复失败保留材料，避免包装层重复清理。真实systemd RefuseManualStop故障与独立CLI重试已验。
- 修复探针忽略TERM导致无限阻塞（BUG-071）：1秒宽限后强杀，主进程先退出时也清理同组子进程。
- 加固状态和指标结果写入（BUG-072～074）：检查祖先属主/权限、拒绝目录/链接目标，禁止状态/指标输入输出的路径及硬链接别名冲突。
- 成功历史绑定目标与检查范围（BUG-075，JSON新增scope_id），配置RegionID复用CLI安全整数值域（BUG-076）。补齐缺openssl时仍阻断已确认端口故障的门禁分支（BUG-066），修正新降级日志的Bash3.2变量边界。

- 修复同名进程探测中的 root 执行风险（BUG-080）：核对进程 UID 及可执行文件属主/权限，固定文件描述符后再读取运行版本；拒绝普通用户伪装的 tailscaled。
- 修复回退残留新 unit 和附加状态却报成功（BUG-081）：恢复普通文件集合及存在性，包含隐藏/空状态文件；拒绝递归清理未知目录，核对最终摘要，inactive/absent 意图也刷新 systemd；失败保留标记。新增回归及真实用户证据，并补一次性 VM 的 absent-unit 回退验收。

- 修复无 Go 时把预发布和伪版本截成三段数字（BUG-055、BUG-070）。`v1.104.1-rc1` 不再被当成 `v1.104.1`；完整伪版本可以离线对上正在运行的 tailscaled commit。
- 修复同源门禁读取磁盘上的 tailscaled（BUG-077）。身份取自 systemd MainPID，否则取唯一的 `tailscaled` 进程，再执行 `/proc/PID/exe --version`。无法确认、进程不唯一或字段畸形时拒绝切换，不升级或降级 tailscaled。
- 修复独立迁移的恢复集只保存遗留配置（BUG-078）。回退恢复迁移前的当前节点身份和状态；当时还没有当前配置时，回退删掉迁移新建的文件，遗留文件保持不动。
- 修复恢复集只校验二进制摘要（BUG-079）。unit、配置和状态的摘要以及是否存在一并记录。载荷被改坏时校验失败，不写回正式文件，未完成标记和恢复集都保留。
- 修复本地导入失败后部署仍继续（BUG-065）：三处 `install_derper` 都显式检查返回值。Bash 3.2 不会因函数内 `|| return` 让调用方在 `set -e` 下退出，失败时会继续改证书和 unit。
- 修复发布门禁与启动验证互相矛盾（BUG-066）：缺 ss/netstat 或 openssl 时，若启动验证已降级通过且没有确认故障，不再回滚该服务。工具齐全时的未知、确认故障和 H3/指标问题仍阻断提交。
- 修复全新安装失败回滚的误报（BUG-067）：没有旧单元可恢复时，停掉半启动服务即视为回滚完成，不再提示“回退未完成”。原先在运行但没有备份时仍报未完成。
- 修复参数校验只给笼统错误、以及 check/uninstall/recover 静默收下探针和指标选项（BUG-068）。被拒绝的组合会说明原因；这些模式不读取的选项直接拒绝。
- 修复 status JSON 把合法的大 region_id 写成 null（BUG-069）。`json_number` 接受到 2^53-1，与 RegionID 上限一致。
- 修正维护文档的退出码范围（DOC-012）：0/1/2 只描述 health/status。derpmap 在本地身份未验证时退出 2，身份确认失败时退出 1。
- 新增 C1～C3：显式版本化白名单配置、新旧 CLI 共核、本地 Linux ELF 候选导入、同次采样的 status JSON/derpMap/指标、H0～H3 与指标新鲜度、原子健康状态及发布门禁。探针是独立合法客户端适配接口，缺真实 H3 时明确未验，不增加 Bash 主动修复循环。
- 修复真实 VM 复测发现的重复回退（BUG-062）：A/B 已恢复并复验后不再进入旧 unit 分支重复重启；恢复旧文件后清除坏候选的 systemd 失败计数再启动，避免刚恢复的服务因启动限流停下。
- 新增 C 阶段行为回归、真实 systemd VM 的完整 CLI 导入/JSON/配置/门禁回退验收和中英文维护指南；真实外部 H3、生产迁移及控制面维护仍单独待验。
- 修复健康检查 timer/cron 丢失显式 `--allow-non-global-ip` 的问题（BUG-061），避免内网测试部署的定时检查因 IP 参数校验失败；默认公网校验保持不变。
- 修复不带 `--ip` 的 `status --format json` / `derpmap` 会把“从已部署 unit 读取 hostname/IP”提示写入 stdout、导致机器可读输出不是合法 JSON 的问题（BUG-064）；该提示与环境检测一样改走 stderr。
- 修复 Bash 3.2（UTF-8 locale）下 `$VAR` 紧跟全角标点被当作变量名导致 `set -u` 中止、以及 `json_quote` 对非 ASCII 输出乱码的问题（BUG-063）；测试同步适配 macOS 可移植性。
- GB 集成测试改用一次性 Ubuntu VM 中的真实 systemd、DERP 进程和 TLS 复验，覆盖启动失败回退、SIGKILL 后显式恢复、恢复失败留备份、停止意图、证书与身份复用，以及生成健康任务的执行和清理。此测试需显式环境许可和 VM 标记，拒绝覆盖已有部署。
- 测试套件结构统一：主套件与审查回归改为累计失败计数并支持传参单独运行用例，审查回归用例清单数组化；跳过提示统一为 `skip -` 前缀，不再混入 ok 计数；新增外部探针路径信任检查的负例（相对路径/符号链接/不可执行/目录/不存在）；CI 以 root 运行 S2 真实 flock/权限证据套件，ShellCheck 覆盖扩展到全部测试文件；新增 `tests/README.md` 固化套件分工、命名体系与运行矩阵。
- 文档调整：中英文更新日志从仓库根目录移回 `docs/`（`docs/CHANGELOG_CN.md`、`docs/CHANGELOG_EN.md`）；README 明确 REFERENCE 即详细用户指南，文档目录说明同步更新。

## [0.2.15] - 2026-10-21

### ✨ 功能

1. **单步发布回退与安装树权限（BUG-036、BUG-037、DEV-006 的本地部分）**
    - 升级、回退、迁移、轮换和卸载共用 flock。构建写入候选目录，校验通过后才替换正式二进制。
    - 固定 root 恢复集与同盘暂存。未校验的暂存不会覆盖唯一备份。未完成标记阻断普通覆盖，只能用 `--recover-interrupted` 显式恢复，记录按白名单读取，不 source/eval，也不自动接着做未完成的步骤。
    - 坏候选、写入失败不报成功。首次安装失败不伪造上一版本。原停止的服务恢复后仍停止。无法确认 tailscaled daemon revision 时不切换，也不升级或降级 tailscaled。
    - 安装树归 root。节点私钥迁到状态目录并保持原字节。证书目录若是符号链接则拒绝。systemd 只对节点状态目录放开写入。
    - 恢复配置和状态时不跟随目标符号链接；状态目录本身是符号链接则直接拒绝。以 root 写入时先把该目录临时收归 root，结束后交还运行用户。
    - 默认开启 verify-clients 时，候选模块版本与正在运行的 tailscaled commit 按伪版本末尾 12 位或 `go list -m` 解析出的发布标签比较。对不上或无法确认则不切换，也不升级或降级 tailscaled。
    - 回退先确认 derper 已停止，再写回旧文件，并按原运行意图启动。停止、启动或复验失败都保留未完成标记。
    - 不重建二进制的迁移在停服前建立恢复集和 migrate 标记。停服后失败会按原意图拉起，并保留标记供显式恢复。迁移后的节点配置属主改为运行用户，权限 0600。root 下会核对该用户能否读取。
    - 标准 `tailscale commit: <hash>` 输出按完整字段名解析，不再误读第二字段而拒绝同源候选；缺失、畸形或来源不符仍拒绝（BUG-055）。
    - 升级中的迁移复用原恢复集，重复迁移不会用候选覆盖唯一旧版本，也不会提前清除外层标记；最终服务验证后统一提交（BUG-059）。
    - 回退按旧 unit 的用户恢复状态目录与证书组权限，旧用户可读取节点身份和旧 IP 私钥；不改变调用方目标用户和 IP（BUG-060）。

### 🔧 Bug 修复

1. **完全卸载清理健康检查稳定副本（BUG-053）**
    - `--uninstall --purge-all` 同时删除稳定程序与 status，并清理空目录；普通卸载和 `--purge` 仍保留。只删除本脚本创建的文件，保留其他用户文件；拒绝符号链接目录，删除失败返回非零。

### 🧪 测试

- 新增 `tests/test_s2_fixes.sh` 的 8 项行为回归，先确认修复前失败、修复后通过，覆盖标准 daemon 输出、升级与迁移组合、失败标记、旧用户恢复及完全卸载（含文件和空目录删除失败）；已接入 CI。`tests/test_s2_evidence.sh` 增加真实双用户回退后节点配置和私钥可读检查，在一次性 Ubuntu 容器通过。
- `tests/test_review_regressions.sh` 从 46 项扩充到 65 项：新增 B1/B2/B3 回退与迁移用例（双进程锁、坏候选不替换、停服意图不拉起、首次安装失败不伪造上一版本、回退恢复配置与状态、复验失败保留恢复集、构建超时不动正式二进制、迁移失败复验、安装树符号链接拒绝），以及 BUG-054～058 定向用例（恢复不跟随状态符号链接、状态目录链接拒绝、同源候选通过 daemon 门禁、回退换回旧进程且停止失败保留标记、纯迁移失败保留标记、迁移配置交给运行用户）。root 下跳过无法模拟的权限断言；主套件 104 项与审查回归在 macOS Bash 3.2 与 Linux Bash 5.2 均通过。

本版收录 0.2.14（Build0280）提交之后的 S2/B 阶段工作区改动；修复记录见仓库根目录 `task-list.md`（BUG-036、BUG-037、BUG-053～BUG-060、DEV-006 本地部分、TST-013～TST-016、CHK-020～CHK-023）。B 阶段的 VM 故障注入仍由 `tests/test_systemd_integration.sh` 在一次性 Ubuntu VM 上执行，本机未跑该门禁。

---

## [0.2.14] - 2026-10-21

### 🔧 Bug 修复

1. **端口冲突按协议判断，端口归属只认 PID 字段（BUG-040、BUG-043、BUG-044、BUG-048）**
   - DERP 只检查 TCP（含 tcp6），STUN 只检查 UDP（含 udp6）。UDP 占用同号端口不再被报成 TCP 冲突；TCP 占用 STUN 端口号也不再阻断 UDP。
   - 端口归属同时核对协议与进程：移除同名进程兜底，存在 MainPID 时监听进程必须严格一致；同端口另一种协议上的 derper 不能抵消外来监听。
   - `port_listening_owned_by_derper` 与 `current_derper_owns_ports` 只认 ss 的 `pid=<PID>` 或 netstat 的 `<PID>/程序名`。MainPID 恰好等于 Send-Q 或 Recv-Q（例如 128）时，外来 nginx/unbound 占用会被报冲突，不再放行。

2. **矛盾主模式在副作用前拒绝（BUG-041）**
   - `--health-check` 与 `--check`/`--dry-run`/`--repair`/`--force`/`--uninstall` 互斥。`--health-check --uninstall` 不再进入卸载。
   - 单独的健康检查、修复、卸载，以及部署附带 `--install-healthcheck-cron`，保持可用。

3. **数字参数校验后写成规范十进制**
   - 通过范围校验的端口、证书天数、RegionID、连接上限会去掉前导零，derpMap 不再输出 `0443`、`0900` 这类值。

4. **健康检查退出码与 verify-clients 依赖判定（BUG-038）**
   - 退出码 0 健康，1 已确认故障，2 未知；任意非 0 都表示未通过，旧的 cron 和 `if ! --health-check` 调用方不受影响。
   - 实际探测 tailscaled LocalAPI HTTP 状态：verify-clients 开启而 tailscaled 未运行，或 403/401 明确鉴权被拒时 `TS_LOCALAPI_OK=0`、退出码 1、总体健康指标为 0；无法连接或调用者权限不足时记为未知，退出码 2。

5. **限流规则失败不再被当成成功（BUG-035）**
   - nft 的清空和添加放进同一次 `nft -f` 提交。提交失败时不改动已有规则，并返回非零。
   - iptables 先把新规则装进临时链。临时链失败时不改正式链；正式链替换失败时恢复旧规则。恢复也失败时说明保护不完整，不宣称成功。
   - 读取既有链快照失败时直接报错中止并保留原规则，不执行 `-F` 与虚假恢复。

6. **显式移除限流失败（含混合后端残留）严格向外传播错误（BUG-046）**
   - `--tls-connlimit 0` 在全部失败或混合后端任一后端（如 nft）删除失败导致规则残留时，均输出残留警告并返回非零错误码。

7. **证书与私钥错配会阻止重启（BUG-039）**
   - 用公钥比较 RSA 和 EC 证书对。不匹配时不重启；有备份则先恢复备份，否则要求显式 `--accept-cert-rotation` 才重签。

8. **证书目录无搜索权限记为未知而非故障（DOC-008）**
   - 证书目录不可读或不可检索时，明确判定为未知（`CERT_CHECK_UNKNOWN=1`，退出码 2），避免误报证书缺失或命名不兼容。

9. **健康检查任务不再依赖源脚本的执行位（BUG-034）**
   - 安装 root 可管理的稳定副本，并用 `bash` 显式调用。源脚本是 0644、之后源码目录被移走，任务仍可执行。

10. **健康检查 timer 安装严格校验，失败保留旧调度并完整回滚（BUG-042、BUG-047、BUG-049、BUG-050、BUG-051）**
    - 严格检查 unit 目录冲突、临时文件写入、mv 原子替换、daemon-reload 与 enable 每一个步骤。任一步失败清理残留并保留旧 cron，返回非零。
    - 建立完整调度与程序事务快照（`rollback_healthcheck_transaction`）：已有 timer 更新失败时完整恢复原有 service/timer 单元文件、原有稳定副本程序与旧调度状态，并重新 reload systemd，调度与稳定副本均不丢失。
    - 已有稳定副本、service、timer、cron 或 status 必须先完整快照；任一必要备份失败立即停止，原文件保持不变。复制后用 cmp（或大小）校验快照；回滚用 `.bak` 与 `.missing` 区分「有原件」和「原本就没有」，避免安装失败时删掉仍在运行的健康检查。
    - 从 cron 迁到 timer 后检查旧 cron 是否仍在。只读挂载或 immutable 导致删不掉时，回滚新 timer/status 并返回非零。回退到 cron 时同样检查旧 timer/service；删不掉则撤销新 cron，避免两套每五分钟调度同时跑。
    - 修改已有 timer 或迁移调度之前记录 active/enabled，回滚时分别恢复两个状态；原本停止的不会被拉起，原本禁用的不会被启用。
    - 恢复复制、权限、清理或 systemd 操作失败会返回错误并保留快照目录，不再声称「已有调度保持原样」；文件恢复不完整时不会启动 timer。

11. **systemd ExecStart 路径转义规范化（BUG-045）**
    - ExecStart 参数使用双引号包裹与转义，不再复用 Bash 的 `printf %q`，消除 systemd unknown escape 警告。

12. **健康检查单次采集优化与核心大函数职责解耦（DEV-009）**
    - `main` 与 `health_check_report` 消除重复状态收集，文字、指标与退出码复用同一次采集结果。
    - 维持单文件自包含交付模式不变，在单文件内按职责解耦三大核心函数：
      - `write_systemd_service`：解耦参数准备、用户/socket 权限配置、纯 unit 渲染与发布验证/回滚；
      - `install_healthcheck_cron`：解耦命令生成、unit/cron 模板渲染与调度事务回滚；
      - `health_check_report`：解耦单次采集、控制台文本渲染与 Prometheus 指标导出。

### 📖 文档

- 打 tag 改为管理后台或 `tailscale up --advertise-tags`，并写明 verify-clients 需要服务器能看到合法客户端。
- socket 0666 不再称为应急状态。127.0.0.0/8（含 127.0.0.53）不再被说成非回环地址。
- README 与 REFERENCE 中英同步到本版行为：`--install-healthcheck-cron` 优先写 systemd timer 并以 bash 调用稳定副本、失败回滚且幂等；`--uninstall` 同时删除 timer/cron（`/usr/local/lib/derper-deploy` 稳定副本保留）；`--tls-connlimit` 安装/移除失败的返回语义；健康检查退出码 0/1/2 与指标写入失败时退出码 1；示例输出改为现行文案，Prometheus 指标样例补全 `derper_healthy`、`derper_check_unknown`、`derper_metrics_unixtime` 等全部导出项。

### 🧪 测试

- `tests/test_review_regressions.sh` 从 28 项扩充到 46 项：协议端口冲突与归属、矛盾主模式副作用、前导零规范化、健康退出码、nft/iptables 失败保留旧规则与快照读取失败、LocalAPI 403、证书错配与目录无权限、调度备份失败保留原 unit、Send-Q/Recv-Q 不充当 PID、cron/timer 互相删除失败时撤销新调度、回滚恢复 timer 原运行状态、恢复复制失败保留快照。root 下跳过无法模拟的权限断言，缺 python3 或禁止 Unix socket 时跳过 LocalAPI 403 用例。主套件 LocalAPI 探活使用独立探测路径，并在服务写出就绪标记后才连接，accept 与等待都有超时，EXIT 会清理子进程；故意延迟服务启动仍能完成探活。主套件 104 项在禁止 Unix socket 的沙箱与允许 socket 的环境均通过。

本版合并了 2026-10-20～21 开发期间的工作区版本 0.2.14～0.2.17（均未单独发布）；修复记录见仓库根目录 `task-list.md`（BUG-034～BUG-052、DOC-007～DOC-008、ADJ-015～ADJ-020）。

---

## [0.2.13] - 2026-10-20

### 📖 文档与仓库结构

1. **中英文更新日志迁移至仓库根目录**
   - `docs/CHANGELOG_CN.md` / `docs/CHANGELOG_EN.md` 移动为根目录 `CHANGELOG_CN.md` / `CHANGELOG_EN.md`；README 中英链接、部署脚本头部注释与测试断言同步更新。
   - README 中英新增「文档目录约定」，CLAUDE.md 新增同源约定：`docs/` 放产品使用文档，`plans/` 放需求与设计，`checkpoints/` 放审查/调研/执行记录（后两者不纳入版本控制），更新日志与任务台账在仓库根目录。

2. **`.gitignore` 配合目录分工调整**
   - 新增 `checkpoints/` 忽略规则（保留 `records/` 旧规则兼容本地历史文件）；`.claude/` 维持整体忽略，仅作为本地会话配置。

### 🧪 测试

- 主套件断言中英文 CHANGELOG 必须位于仓库根目录，且文档不得再链接 `docs/CHANGELOG_*` 旧路径或缺失的审查文件。

本版不含部署脚本功能变更，BUG-034～BUG-041 仍待修复；2026-10-20 审查与规划记录见仓库根目录 `task-list.md`（CHK-011～CHK-015、ADJ-010～ADJ-013）。

---

## [0.2.12] - 2026-09-20

### 🔧 Bug 修复

1. **无 `timeout(1)` 主机上命令替换被孤儿 `sleep` 卡满整个超时**
   - `_timeout_run` 后备路径的 killer 子 shell 重定向 stdout/stderr，孤儿 `sleep` 不再持有 `$( )` 管道写端；此前无 timeout 主机每次模块查询必卡 60 秒，install 路径还会遗留 15 分钟的 `sleep 900` 孤儿。

### 📖 文档

2. **usage/REFERENCE 补 `--cert-days` 范围；CHANGELOG 历史条目断链校正**
   - usage 与 REFERENCE 中英的 `--cert-days` 标注范围 1–365000；usage 示例改公网 IP 占位符。
   - CHANGELOG 0.2.10 历史条目的失效审查链接改为指向 `task-list.md`（CHK-004～CHK-009）。

### 🧪 测试

- 主套件新增 2 项：无 timeout 时命令替换不被卡满超时、main 必须先 commit 证书再执行 extras；`resolve_run_user` 断言改为普通语句 + ERR trap，回退修复即变红。
- 主套件 `tests/test_deploy_script.sh` 86 项；`tests/test_review_regressions.sh` 14 项，harness 失败时输出 `not ok` 加函数名。
- GitHub Actions `.github/workflows/tests.yml` 在 Ubuntu（Bash 5）上跑两套测试。
- 审查记录见仓库根目录 `task-list.md`（CHK-004～CHK-009）。

---

## [0.2.11] - 2026-09-20

### 🔧 Bug 修复

1. **证书 SAN 改为精确比对，extras 失败不再回滚已验证部署**
   - SAN 按逗号拆项精确匹配 IP，避免 `3.4.5.6` 命中 `13.4.5.6`。
   - 服务验证通过后立即 `commit_cert_update`；`--tls-connlimit`/cron 失败只报告，不撤销证书。
   - 卸载删除 `.certs-rollback`；unit 原子写入并拒绝符号链接；缺 ss/openssl 不再误报启动失败。

2. **超大数值不再靠 Bash 64 位算术做范围校验**
   - 端口、证书天数、RegionID、`--tls-connlimit` 改为去前导零后的十进制字符串比较，避免 `2^64+443` 一类溢出被当成合法小数。

3. **无 `timeout` 时空数组崩溃；GOPROXY 含 `direct` 时预检过严**
   - 改走已有 `_timeout_run`，避免 Bash 3.2~4.3 在 `set -u` 下对空数组 `"${runner[@]}"` 崩溃。
   - GOPROXY 含 `direct` 且代理全不可达时警告并交由 Go 直连，不再中止。

4. **参数互斥与 cron/限流行为对齐实现**
   - `--install-healthcheck-cron` 与 `--health-check` 互斥；显式 `--tls-connlimit` 不能配只读模式；显式 `0` 移除已装规则。
   - cron 固化完整部署参数，并用 `printf %q` 转义路径；nftables 改用脚本专属表 `inet derper_tls_connlimit`。

### 📖 文档

5. **README/REFERENCE 与实现对齐**
   - 补齐 `--cert-days`/`--derper-version`；正式示例改公网 IP 占位符；专用用户示例、证书目录所有权、断链与 `--metrics-textfile` 文案已校正。

### 🧪 测试

- 主套件 `tests/test_deploy_script.sh` 84 项；`tests/test_review_regressions.sh` 14 项。
- GitHub Actions `.github/workflows/tests.yml` 在 Ubuntu（Bash 5）上跑两套测试。
- 审查记录见仓库根目录 `task-list.md`（CHK-004～CHK-007）。

---

## [0.2.10] - 2026-09-20

### 🔧 Bug 修复

1. **自签证书生成在 Bash 5 + `set -u` 下崩溃**
   - `cnf_tmp` 仅在 openssl `-addext` 失败的降级分支赋值；现代 openssl 成功后走到 `rm -f "$cnf_tmp"` 会因未绑定变量退出。已初始化 `key_tmp`/`cert_tmp`/`cnf_tmp`。macOS Bash 3.2 测不出此缺陷。

2. **证书替换半成品无法回滚**
   - `mv` 换掉密钥/证书后若链接、权限或配置失败，会留下新证书配旧兼容路径。现用磁盘事务备份，失败或进程被杀后 `--repair` 可恢复；有效证书不再提前返回，仍校准权限与别名。

3. **verify-clients 按 commit 对齐时每次都重编译**
   - 已安装模块版本常是规范标签（如 `v1.102.4`）或 12 位伪版本，不能用 40 位 commit 做子串匹配。现比对伪版本末尾 revision，并用 `go list -m` 把 commit 解析为规范版本。

4. **显式 `--use-current-user` 被非交互 root 默认覆盖**
   - 未指定用户时继承已部署 unit 的 `User=`；仅首次、未显式指定的非交互 root 部署才默认专用账户。`--check` 同时展示目标用户与已部署用户。

### ⚠️ 行为变化

5. **证书指纹轮换必须显式确认**
   - 替换已有证书前预览新 ACL。交互模式输入 `rotate`；非交互必须加 `--accept-cert-rotation`。`--yes` 不再代替该确认。该选项表示接受切换窗口，不表示脚本已替用户更新 ACL。

6. **socket 权限不再试探性重启 `tailscaled`**
   - 优先持久 socket unit / ACL；`--relax-socket-perms` 仍是显式应急开关。文件模式 0666 本身不能证明 LocalAPI 无鉴权。

7. **受限网络增加超时边界与代理预检**
   - curl 增加连接/总超时与重试；有 `timeout` 时模块查询限 60 秒、构建限 900 秒。构建前用 5 秒探测 GOPROXY（及需要时的 `go.dev/dl`），失败立即提示 `--goproxy`，不自动切换第三方代理，也不关闭 GOSUMDB。

8. **`--relax-socket-perms` 退出时恢复原权限**
   - chmod 666 前记录原 mode，脚本 EXIT 时恢复；健康检查与部署报告在 socket 仍为 0666 时告警。

### ✨ 功能

9. **可选 TLS 连接上限 `--tls-connlimit N`**
   - 用 nftables 或 iptables `connlimit` 限制单 IP 并发 DERP TLS 连接；`0` 表示关闭。`--uninstall` 删除对应规则。

10. **一键健康检查 cron `--install-healthcheck-cron`**
    - 写入 `/etc/cron.d/derper-healthcheck`（每 5 分钟 `--health-check --ip … --metrics-textfile …`）。不能与 `--uninstall`/`--check` 同用；卸载时删除该 cron。

### 🧪 测试

- 主套件 `tests/test_deploy_script.sh` 64 项；`tests/test_review_regressions.sh` 13 项。
- GitHub Actions `.github/workflows/tests.yml` 在 Ubuntu（Bash 5）上跑两套测试。
- 审查记录见仓库根目录 `task-list.md`（CHK-004～CHK-009）；规划讨论稿在本地 `plans/`（不纳入版本库）。

---

## [0.2.9] - 2026-08-14

### 🔧 Bug 修复

1. **`ensure_go` 接受过旧的发行版 Go**
   - Ubuntu 22.04 / Debian 12 的 apt `golang-go` 常为 1.18，不支持 `GOTOOLCHAIN=auto`，构建会失败。现在要求工具链 `>= 1.21`，过旧则安装官方 Go 1.22.6。

2. **`get_installed_derper_version` 误抓 Go 工具链版本**
   - 第三级裸 semver 回退会先匹配二进制里的 `go1.22.6`，把工具链版本当成 derper 版本，导致该重装时误判已对齐。已删除该回退。

3. **旧部署缺 STUN 时 `--force`/`--repair` 被自家端口卡死**
   - 端口预检改为按端口判断是否由 derper 占用；仅有 TLS、没有 STUN 的旧实例不再把自身 DERP 端口当成冲突。他人占用的 STUN 仍会拒绝。

4. **`--repair` 证书重签未复用迁移逻辑**
   - 仅命名不兼容（`fullchain.pem` → `<IP>.crt`）时，`--repair` 与默认路径一样先迁移、保留指纹，而不是无谓重签。

5. **drop-in 重启 `tailscaled.socket` 缺少 SSH 保护**
   - 与重启 `tailscaled` 一致：检测到当前 SSH 走 Tailscale（`100.x` / `fd7a:115c:a1e0:`）时，非交互模式跳过 socket 重启并提示稍后在非 Tailscale 会话执行。

6. **向导 `exec` 泄漏临时目录**
   - `exec` 替换进程时 EXIT trap 不会运行；执行前先 `release_tmpdir`。

7. **健康检查每次外网探测 IP**
   - `--health-check`（cron）不再打外网 IP API，优先从已部署 unit 的 `-hostname` 读取；已指定 `--ip` 时也不会再探测。

8. **向导产物 `derper_deploy_cmd.sh` 未忽略**
   - 已加入 `.gitignore`。

- 回归测试扩展至 46 项。

## [0.2.8] - 2026-08-14

### 🔒 安全修复

1. **证书生成符号链接覆盖风险（P1）**
   - 证书目录与 `<IP>.crt`/`<IP>.key` 保持 root 所有，服务用户仅通过组权限只读；节点私钥状态（`derper.json`）仍位于服务用户可写的安装目录。
   - 重签/迁移前先收紧证书目录，写入前拒绝符号链接路径，全部通过同目录随机临时文件 + `mv` 原子替换（`mv` 不沿符号链接写入）；`openssl-derper.cnf` 临时配置不再落入安装目录。
   - `setup_service_user` 每次 `chown -R` 后重新收回证书目录所有权，避免服务账户重获写权限。

2. **不再回退到 `InsecureForTests`（P1）**
   - 指纹获取失败时不再输出 `InsecureForTests: true` 的 derpMap，而是部署失败并要求排查 TLS；上游明确该字段仅用于单元测试。

3. **公网 IP 校验补全**
   - 新增完整 IPv4 分类（私有/CGNAT 100.64/10、回环、链路本地、文档 TEST-NET、组播、保留段等）；部署模式默认拒绝非全局可路由地址，内网测试需显式 `--allow-non-global-ip`。

4. **RegionID 范围收紧**
   - 上限收紧到 JavaScript 安全整数（2^53-1）；900-999 之外给出警告（上游约定保留给用户自建区域）。

### 🔧 Bug 修复

5. **derpMap 缺少 STUNPort（P1）**
   - CertName ACL 片段补充输出 `STUNPort`，自定义 `--stun-port` 现在真正生效。

6. **服务启动验证与完整回滚（P1）**
   - 启动/重启后强制验证：active 状态、TLS/STUN 端口监听、TLS 握手成功、进程存活；失败时回滚旧 unit 并重新启动旧服务再验证，而不是只恢复文件。

7. **--repair 描述与行为一致**
   - 帮助与文档明确：`--repair` 默认不重装 derper，但已部署二进制与对齐目标版本不一致时会重装。

8. **verify-clients 同源对齐升级为 Git revision**
   - 优先读取 `tailscale version` 的 `tailscale commit`，将 derper 对齐到同一 commit；取不到时退化为版本标签并给出警告。按 commit 对齐时，已安装伪版本包含该 commit 即视为同源。

9. **参数组合互斥校验**
   - `--purge/--purge-all` 需配合 `--uninstall`、`--metrics-textfile` 需配合 `--health-check`、`--force`/`--repair`/`--uninstall`/`--check` 互斥组合直接报错，不再静默取分支。

10. **Prometheus 指标补全**
    - 新增 `derper_healthy`（总体健康）与 `derper_cert_live_match`（在线证书一致性），证书不一致时不再出现“derper_up 1 但实际不健康”的盲区。

11. **极简环境依赖补全**
    - 依赖检查新增 `tar`（Go 兜底安装需要）。

### 📚 文档

- README 补充上游自建 DERP 限制：不支持部分跨 Tailnet/节点分享场景、不应放在普通 HTTP 反向代理或全局负载均衡后、生产建议静态 IPv4+IPv6、应使用 `derpprobe` 做协议级监控。

### 🛡️ 主机与 Tailnet 暴露面审计（公网中继风险主要在主机本身）

- 部署/检查/健康检查时新增**暴露面检查**：列出除 DERP 端口外面向非回环地址的 TCP 监听（含 0.0.0.0:22 的 SSH 提示），建议单机单用途。
- 新增**自动安全更新检测**（unattended-upgrades / dnf-automatic），未启用时给出告警与开启指引。
- 防火墙提示新增主机加固建议：云安全组入方向只放行 DERP TLS + STUN 两个端口、SSH 优先走 Tailscale 或限源、出方向不要收紧（tailscaled 需连控制面/官方中继探测）、关注 `-verify-clients` 拒绝日志。
- 部署完成输出新增**服务器节点 ACL 约束建议**：给节点打 `tag:derper-server` 并在 ACL 中最小授权，做到“中继被攻破 ≠ 内网失守”。

### 🧪 测试

- 回归测试扩展至 36 项，新增覆盖：STUNPort ACL 输出、指纹缺失安全失败、非公网 IP 拒绝、RegionID 安全整数范围、参数组合校验、证书符号链接拒绝、commit 对齐与伪版本匹配、新 Prometheus 指标、暴露面检测、自动更新检测、服务器节点 ACL 建议。

---

## [0.2.7] - 2026-07-11

### 🔧 Bug 修复

1. **证书命名与上游 derper manual 模式对齐**
   - 自签证书改为生成 `<公网IP>.crt` / `<公网IP>.key`（与上游 `cmd/derper/cert.go` 一致），避免 derper 忽略脚本证书并另签一套。
   - 保留 `fullchain.pem`/`privkey.pem`/`cert.pem`/`key.pem` 兼容符号链接；旧命名在幂等修复时就地迁移，尽量不改变 CertName。
   - 健康检查与指纹计算优先使用上游命名；命名不兼容时视为不健康。

2. **版本对齐真正重装二进制**
   - 对齐目标版本后，通过 `go version -m`（或回退探测）读取已安装 derper 模块版本；不一致时重新 `go install`，无需额外 `--force`。
   - `--derper-version` 显式指定时同样会在版本漂移时重装。

3. **socket 权限处理去侵入化**
   - 先创建运行用户，再判断是否已具备读写权限（含 world-writable）；已可访问则跳过改组/重启 tailscaled/drop-in。

4. **systemd / 配置漂移 / 健康检查可靠性**
   - `StartLimitBurst`/`StartLimitIntervalSec` 移至 `[Unit]`。
   - paranoid 降级禁用 `MemoryDenyWriteExecute` 时更新注释标记；漂移检测区分完整/降级状态。
   - 写入 unit 前备份，启动失败时尝试回滚。
   - 端口归属核对 MainPID；TLS/健康探测优先本机回环，降低 NAT hairpin 误报。
   - `--check`/`--health-check` 在参数校验失败时返回非 0。
   - 运行时检查补充协议级诊断提示（`tailscale debug derp`/`netcheck`），并标明 `nc -zvu` 的局限。

### 📚 文档

- 收敛“生产级/企业级/全覆盖”表述，与测试/家用/小规模定位一致。
- 证书路径、版本对齐、CertName 轮换与健康检查边界说明已同步。
- 为脚本引入正式版本概念：`SCRIPT_VERSION`、仓库根目录 `VERSION`、`-V/--version`；REFERENCE/CHANGELOG 版本号统一为 0.2.7。

### 🧪 测试

- 回归测试扩展至 26 项，新增覆盖：上游证书命名、版本漂移重装、paranoid 降级匹配、StartLimit 分区、socket 已可访问跳过、健康检查命名要求、`--version` 与 VERSION 文件一致性。

---

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

**更新日期**：2026-10-27

**版本**：0.2.19
