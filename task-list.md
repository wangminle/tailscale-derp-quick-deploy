# 任务跟踪列表

记录本项目所有任务：代码 bug、bug 转需求、新增需求、需求调整、功能开发、代码审查、测试数据、文档维护、配置运维等。

> 说明：本文件是当前项目的任务清单。所有新增事项、状态变更和完成记录都应同步写入本文件。
> 字段说明：动作字段只允许以下 8 个固定枚举：修复、开发、优化、调整、规划、检查、文档、运维。
> 时间说明：发现时间和完成时间分开记录，格式为 YYYY-MM-DD HH:MM，使用机器本地时区的 24 小时制时间；未完成事项的完成时间填 -。
> 状态说明：Bug 未完成用待修复，通用未完成用待办（或待开发），进行中/已完成/已修复/已关闭/已解决按语义选用；条目互引用 [[BUG-001]] 语法。
> 归并规则：审计、复核、核查、审查、验证、评估统一记为“检查”；重构、清理统一记为“优化”；方案、梳理统一记为“规划”；记录类文档事项统一记为“文档”。

## 代码 Bug

| ID | 动作 | 问题描述 | 发现时间 | 完成时间 | 状态 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| BUG-001 | 修复 | 证书生成存在符号链接覆盖风险（P1）：derper 账户可将 <IP>.key 预埋为符号链接，诱导 root 重签时沿链接覆盖任意文件 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已修复 | certs 目录及证书/私钥保持 root 所有、服务用户仅组内只读；写入前 refuse_symlink 拒绝符号链接；同目录随机临时文件 + mv 原子替换；setup_service_user 每次 chown 后重新收紧。涉及 harden_cert_dir / generate_selfsigned_cert / 证书迁移分支。 |
| BUG-002 | 修复 | 指纹获取失败时自动降级输出 InsecureForTests: true（P1，上游明确仅用于单元测试） | 2026-08-14 20:35 | 2026-08-14 20:35 | 已修复 | finalize_deployment_report 改为失败并要求排查 TLS，绝不输出 InsecureForTests；删除 print_acl_snippet_insecure。 |
| BUG-003 | 修复 | 自定义 STUN 端口没有写进 derpMap（P1）：--stun-port 40000 时客户端仍按默认 3478 发 STUN | 2026-08-14 20:35 | 2026-08-14 20:35 | 已修复 | print_acl_snippet_cert 增加 STUNPort 字段输出。 |
| BUG-004 | 修复 | 服务实际启动失败仍可能返回成功（P1）：只检查 systemctl start/restart 即时返回值 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已修复 | service_verified_running 强制验证 active 状态、TLS/STUN 端口监听、TLS 握手成功、MainPID 存活。 |
| BUG-005 | 修复 | 失败回滚只恢复 unit 文件，没有重启并验证旧服务（P1） | 2026-08-14 20:35 | 2026-08-14 20:35 | 已修复 | rollback_previous_unit 恢复旧 unit 后重新启动旧服务并再次健康验证；新装失败则停止服务。 |
| BUG-006 | 修复 | --repair 帮助称“不重装 derper”，但版本不一致时会重新下载并替换二进制 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已修复 | 帮助/README/REFERENCE 文案与行为对齐：默认不重装，二进制与对齐目标版本不一致时重装。 |
| BUG-007 | 修复 | 公网 IP 校验不完整：100.64.0.0/10、文档地址段、组播、保留地址等无警告通过 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已修复 | ipv4_address_class 完整分类；正式部署拒绝非全局可路由地址，内网测试需显式 --allow-non-global-ip。 |
| BUG-008 | 修复 | RegionID 范围过宽：9007199254740993 也能通过，上游要求 JS 安全整数且 900-999 保留给用户自建区域 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已修复 | 上限收紧到 9007199254740991（2^53-1）；900-999 之外警告；前导零按十进制解析。 |
| BUG-009 | 修复 | 参数组合无互斥校验：--purge 单独用不清理、--metrics-textfile 单独用被忽略、--force+--repair 静默取一个分支 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已修复 | validate_arg_combos 硬错误：purge 需配合 uninstall、metrics-textfile 需配合 health-check、force/repair/uninstall/check 互斥。 |
| BUG-010 | 修复 | Prometheus 指标缺少总体健康与在线证书一致性指标：证书不一致时 derper_up 仍为 1 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已修复 | 新增 derper_healthy（总体健康）与 derper_cert_live_match（在线/磁盘证书一致性）。 |
| BUG-011 | 修复 | 极简 Linux 依赖不完整：Go 兜底安装调用 tar，但 install_deps 不检查 tar | 2026-08-14 20:35 | 2026-08-14 20:35 | 已修复 | install_deps 增加 tar 检查与安装。 |
| BUG-012 | 修复 | verify-clients“同源 revision”并未真正保证：只把版本号转成语义标签，自定义构建/发行版补丁版可能非同源 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已修复 | ts_commit 优先读取 tailscale version 的 tail commit 对齐到同一 Git revision；取不到时退化标签并警告；derper_binary_needs_install 支持伪版本包含 commit 即视为匹配。 |
| BUG-013 | 修复 | 自签证书生成后因 cnf_tmp 未初始化，在 set -u 下崩溃 | 2026-09-20 07:41 | 2026-09-20 07:41 | 已修复 | 初始化 key_tmp、cert_tmp、cnf_tmp；Bash 5.2 已复现修复前 unbound variable，修复后完整回归通过；覆盖 addext 与配置文件签发、降级时三种临时文件创建失败及清理。Bash 3.2 完整回归通过。 |
| BUG-014 | 修复 | 证书更新缺少事务回滚：mv 替换证书后若链接/权限/配置步骤失败，留下新证书 + 旧兼容链接的半成品状态；且 check 四项全过时 repair 直接 return，永不修复符号链接与权限 | 2026-09-20 07:41 | 2026-09-20 07:41 | 已修复 | begin/rollback/commit_cert_update 磁盘事务 + repair_cert_layout 幂等重建链接与权限 + EXIT trap cleanup_deployment 失败回滚并重启旧服务；本次审查复核确认，tests/test_review_regressions.sh 在 Bash 5.2 下 11 项全过。；后续复核补齐：恢复操作保留不可变快照，可在恢复中断后重试；服务回滚按旧 unit IP/端口验证；旧符号链接迁移改为复制内容，避免链接环；权限错误不再静默吞掉。 |
| BUG-015 | 修复 | verify-clients 版本对齐误判：commit 与已安装版本用子串匹配，当 commit 恰为发布标签时 have=1.102.4 永不含 40 位 commit，导致每次 repair 都重新编译 derper | 2026-09-20 07:41 | 2026-09-20 07:41 | 已修复 | 伪版本改为比对末尾 12 位 revision；新增 resolve_derper_module_version 用 go list -m 解析 commit 对应的规范标签；解析失败保守重装并提示。本次审查复核确认，见 [[BUG-012]] 的后续修正。 |
| BUG-016 | 修复 | 运行用户漂移：非交互 root 部署只检查 CREATE_DEDICATED_USER，显式 --use-current-user 被静默改为 derper 专用账户；已部署实例再次执行会破坏性改属主，并使 --check 的目标配置匹配恒为 0 | 2026-09-20 07:41 | 2026-09-20 07:41 | 已修复 | 新增 RUN_USER_EXPLICIT 与 resolve_run_user：显式参数优先，其次继承已部署 unit 的 User=，仅首次非交互 root 部署才默认专用账户；--check 增加输出已部署用户。unit_matches_desired_config 本就比对 ^User=，故本条同时闭合了 check 与 repair 的幂等判定。 |

## 调整事项

| ID | 动作 | 事项 | 发现时间 | 完成时间 | 状态 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| ADJ-001 | 调整 | 版本号 0.2.7 → 0.2.8 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已完成 | SCRIPT_VERSION / 根目录 VERSION / CHANGELOG / REFERENCE 统一为 0.2.8（2026-08-14）。 |
| ADJ-002 | 调整 | 受限网络下增加下载边界与 Go 模块代理诊断 | 2026-09-20 08:10 | 2026-09-20 08:10 | 已完成 | curl 连接与总超时、重试；有 timeout 时查询限 60 秒、构建限 900 秒；尊重已有代理，不自动切换第三方代理或关闭校验。截图网络故障为环境相关，未在真实大陆服务器复现。 |
| ADJ-003 | 调整 | socket 权限修复避免试探性重启 tailscaled，并验证最终访问权限 | 2026-09-20 08:10 | 2026-09-20 08:10 | 已完成 | 保留持久 socket unit/ACL 及显式应急开关；0666 不是默认无鉴权 API 的证据，上游支持 peer credentials；详见核查文档。 |
| ADJ-004 | 调整 | 版本号 0.2.9 → 0.2.10 | 2026-09-20 09:25 | 2026-09-20 09:25 | 已完成 | SCRIPT_VERSION / VERSION / CHANGELOG / REFERENCE / README 统一为 0.2.10（2026-09-20），收录 [[BUG-013]]~[[BUG-016]]、[[DEV-003]]、[[ADJ-002]]、[[ADJ-003]]。 |
| ADJ-005 | 调整 | .gitignore 增加 plans/ 规划讨论文档目录 | 2026-09-20 09:58 | 2026-09-20 09:58 | 已完成 | 原仅忽略 plan/，实际目录为 plans/，讨论稿与审查记录不纳入版本控制。 |
| ADJ-006 | 调整 | 从版本库取消跟踪已提交的 plans/ 文件 | 2026-09-20 10:20 | 2026-09-20 10:20 | 已完成 | git rm --cached 取消跟踪 5 个文件，本地保留；.gitignore 增加 plans/。已并入未推送的 V0.2.10-Build0179，不另开 commit。 |
| ADJ-007 | 调整 | 从 git 历史彻底清除 plans/ 并 force-with-lease 推送 main | 2026-09-20 10:25 | 2026-09-20 10:25 | 已完成 | git filter-repo 移除 plans/ 路径；过期 reflog 并 gc prune 清除 41af117 等悬空提交；git push --force-with-lease origin main。本地文件保留。docs/DEFECT_ANALYSIS 旧路径不在本次清除范围。 |

## 检查事项

| ID | 动作 | 事项 | 发现时间 | 完成时间 | 状态 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| CHK-001 | 检查 | 代码安全审计：发现 5 个 P1 与若干 P2/P3 缺口 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已完成 | 产出 12 项修复，见 [[BUG-001]]~[[BUG-012]]；回归测试 26 → 35 项全部通过；受环境限制未做真实 Linux systemd 全链路验证。 |
| CHK-002 | 检查 | 主机/Tailnet 威胁模型评审（公网中继暴露面审计） | 2026-08-14 20:35 | 2026-08-14 20:35 | 已完成 | 结论：风险主要在主机（SSH、节点身份、补丁）而非 DERP 协议（WireGuard 端到端加密、STUN 放大系数≈1）；已落地暴露面检查、自动更新检测、服务器节点 ACL 建议、防火墙加固提示。待办见 [[OPS-001]]~[[OPS-006]]。 |
| CHK-003 | 检查 | 核验外部模型提出的 8 项部署缺陷：逐条比对已提交版本与当前工作区实现 | 2026-09-20 08:05 | 2026-09-20 08:05 | 已完成 | 结论：5 项成立且工作区已修（见 [[BUG-013]] [[BUG-014]] [[BUG-015]] [[BUG-016]] [[DEV-003]]）；check 不闭环一项现象成立但归因有误，unit_matches_desired_config 本就比对 ^User=，根因是运行用户漂移；GOPROXY 与 socket 0666 两项为设计取舍，改进项记为 [[DEV-004]] [[DEV-005]]。所有修复仍停留在工作区，HEAD 尚未提交。 |
| CHK-004 | 检查 | 逐项复核服务器截图的 8 项问题并验证修复 | 2026-09-20 08:10 | 2026-09-20 08:10 | 已完成 | docs/BUGFIX_REVIEW_20260920.md 记录逐项结论；Bash 3.2/5.2 各 63 项测试通过；独立审查发现的服务恢复、旧端点验证和迁移链接环已修复。未连接真实服务器，systemd 和网络采用故障注入。 |

## 测试数据

| ID | 动作 | 事项 | 发现时间 | 完成时间 | 状态 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| TST-001 | 检查 | 回归测试套件 26 → 35 项扩展 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已完成 | tests/test_deploy_script.sh；新增：STUNPort ACL、指纹缺失安全失败、非公网 IP 拒绝、RegionID 范围、参数组合校验、证书符号链接拒绝、commit 对齐/伪版本匹配、derper_healthy/derper_cert_live_match、暴露面检测、自动更新检测、服务器节点 ACL 建议。bash -n 通过。 |
| TST-002 | 检查 | 回归测试需在 Bash 5 环境执行：macOS 自带 Bash 3.2 不把 local 未赋值变量视为 unset，set -u 类缺陷在本机永远测不出 | 2026-09-20 08:05 | 2026-09-20 09:45 | 已完成 | 已实测：Bash 3.2 下 local a; rm -f "$a" 正常通过，Bash 5.2 下报 a: unbound variable 并退出，这正是 [[BUG-013]] 在服务器必现而本地漏测的原因。建议测试套件在 debian:12 等 Bash 5 容器中执行，或在 CI 固定该环境。；[[CHK-004]] 已在 Bash 3.2/5.2 各跑过一轮；仓库仍无 CI 固定 Bash 5，故保持待办。；.github/workflows/tests.yml 在 Ubuntu（Bash 5）跑主套件与审查回归；get_installed_derper_version 在无 strings 时回退 grep -a，避免极简镜像漏检。 |
| TST-003 | 检查 | 新增 tests/test_review_regressions.sh 覆盖证书事务、用户继承、commit 对齐与轮换确认 | 2026-09-20 08:10 | 2026-09-20 09:25 | 已完成 | 与主套件 tests/test_deploy_script.sh 并列；文档与版本 0.2.10 同步时记账。CI 仍建议在 Bash 5 容器执行，见 [[TST-002]]。 |

## 文档维护

| ID | 动作 | 事项 | 发现时间 | 完成时间 | 状态 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| DOC-001 | 文档 | 文档同步至 0.2.8 并补齐上游限制与主机加固说明 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已完成 | README（上游自建 DERP 限制、主机与 Tailnet 加固 5 条、新参数与新指标）、CHANGELOG_CN/EN、REFERENCE_CN/EN。 |
| DOC-002 | 文档 | 文档同步至 0.2.10：证书轮换确认、运行用户继承、commit 对齐与 GOPROXY 行为 | 2026-09-20 09:25 | 2026-09-20 09:25 | 已完成 | README 中英参数表补 --accept-cert-rotation / --yes；REFERENCE 补齐专用用户、安全级别、derper-version 与轮换确认；CHANGELOG_CN/EN 新增 0.2.10；核查记录 docs/BUGFIX_REVIEW_20260920.md 标注对应版本。；0.2.10 文档已补 --tls-connlimit / --install-healthcheck-cron / GOPROXY 预检 / socket 恢复 / GitHub Actions。 |

## 功能开发

| ID | 动作 | 事项 | 发现时间 | 完成时间 | 状态 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| DEV-001 | 开发 | 可选限速：nftables/iptables connlimit 限制单 IP 并发 TLS 连接 | 2026-08-14 20:35 | 2026-09-20 09:45 | 已完成 | 应对 TLS 握手洪水/连接耗尽；或直接依赖云厂商免费基础 DDoS 防护。；新增 --tls-connlimit N：nftables 优先，否则 iptables connlimit；0 关闭；uninstall 删除 DERPER-CONNLIMIT / nft table inet derper。 |
| DEV-002 | 开发 | 可选：提供一键安装健康检查 cron 的脚本参数（如 --install-healthcheck-cron） | 2026-08-14 20:35 | 2026-09-20 09:45 | 已完成 | 与 [[OPS-005]] 互补；需评估参数冲突与卸载行为。；新增 --install-healthcheck-cron，写入 /etc/cron.d/derper-healthcheck（每 5 分钟 --health-check --ip --metrics-textfile）；与 uninstall/check 互斥；uninstall 删除 cron。 |
| DEV-003 | 开发 | 证书指纹轮换显式确认：新增 --accept-cert-rotation，--yes 不再代替该确认 | 2026-09-20 07:41 | 2026-09-20 07:41 | 已完成 | confirm_cert_rotation 在替换证书前先打印新指纹的 ACL 片段并要求输入 rotate；非交互需显式 --accept-cert-rotation，否则中止且保留原证书。受 derpMap CertName 单值限制，ACL 更新与服务重启之间的窗口只能靠变更窗口规避。 |
| DEV-004 | 开发 | Go 工具链与模块代理连通性预检：go.dev/dl 与 GOPROXY 默认值在大陆网络常不可达，失败前需先快速探测并给出 --goproxy 建议 | 2026-09-20 08:05 | 2026-09-20 09:45 | 已完成 | 现状仅有 curl 超时重试与 go install timeout 900 秒兜底，失败前仍可能长时间干等。建议 ensure_go/install_derper 前用 curl -I --max-time 5 探测下载源与代理，失败即报错并提示显式代理；不自动切换第三方代理或关闭 GOSUMDB，避免削弱供应链校验。；precheck_go_network 在 go install 前 5 秒探测 GOPROXY；ensure_go 下载前探测 go.dev/dl；失败提示 --goproxy，不自动切换代理。 |
| DEV-005 | 开发 | --relax-socket-perms 退出时恢复 tailscaled socket 权限：chmod 666 后无恢复动作，公网中继上会把本地 API 长期暴露为 world 可写 | 2026-09-20 08:05 | 2026-09-20 09:45 | 已完成 | 建议改权限前记录原 mode，注册 EXIT 恢复，并在部署报告与健康检查中持续告警；优先路径（tailscaled.socket drop-in SocketGroup=tailscale/0660 与 setfacl）已可覆盖绝大多数场景。；relax_socket_world_writable 记录原 mode，cleanup_deployment EXIT 恢复；健康检查与部署报告对 0666 告警。 |

## 配置运维

| ID | 动作 | 事项 | 发现时间 | 完成时间 | 状态 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| OPS-001 | 运维 | 云安全组最小化：入方向仅放行 DERP TLS + STUN 端口，22/tcp 不对 0.0.0.0/0 开放 | 2026-08-14 20:35 | - | 待办 | 收益最大的一步；需在云厂商控制台核对默认安全组。 |
| OPS-002 | 运维 | SSH 收敛：优先只走 Tailscale（sshd 只监听 tailscale IP），或限源 IP + 禁用密码登录 | 2026-08-14 20:35 | - | 待办 | 兜底：derpMap OmitDefaultRegions=false 时官方中继仍可用；保留云 VNC/控制台作为最后通道。 |
| OPS-003 | 运维 | 服务器节点打 tag:derper-server 并在 ACL 中最小授权 | 2026-08-14 20:35 | - | 待办 | tailscale set --tags=tag:derper-server + tagOwners 声明；不把该 tag 写入任何 src 放行规则。 |
| OPS-004 | 运维 | 启用操作系统自动安全更新（unattended-upgrades / dnf-automatic） | 2026-08-14 20:35 | - | 待办 | 脚本健康检查已能检测并告警（check_automatic_updates）。 |
| OPS-005 | 运维 | 安装健康检查 cron：--health-check --ip <IP> --metrics-textfile <路径> | 2026-08-14 20:35 | - | 待办 | 建议显式 --ip 避免每次探测外网；可配合 node_exporter textfile collector。 |
| OPS-006 | 运维 | 部署 derpprobe 做协议级监控 | 2026-08-14 20:35 | - | 待办 | 上游建议对自建 DERP 做协议级监控，弥补健康检查仅覆盖进程/端口/握手的局限。 |
