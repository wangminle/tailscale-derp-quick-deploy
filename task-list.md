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
| BUG-017 | 修复 | 无 timeout 时 resolve_derper_module_version / install_derper 用空数组 runner=() 在 Bash 3.2~4.3 + set -u 下崩溃 | 2026-09-20 10:53 | 2026-09-20 11:10 | 已修复 | 本机 Bash 3.2 实测 "${runner[@]}" 报 runner[@]: unbound variable。两处改走已有 _timeout_run；核查文档声称支持无 timeout 环境。tests 覆盖缺失 timeout 的模块查询与 install_derper。 |
| BUG-018 | 修复 | --install-healthcheck-cron 与 --health-check 同用、以及 --tls-connlimit 配 --health-check/--check 被静默忽略 | 2026-09-20 10:53 | 2026-09-20 11:10 | 已修复 | main() 在 HEALTH_CHECK 分支提前 exit，cron 永不安装；只读模式也不调用 apply_tls_connlimit。validate_arg_combos 现硬拒绝这些组合。 |
| BUG-019 | 修复 | --tls-connlimit 0 不卸载已装规则；健康检查 cron 路径未加引号；GOPROXY 含 direct 时代理全不可达仍中止 | 2026-09-20 10:53 | 2026-09-20 11:10 | 已修复 | 显式 --tls-connlimit 0 调用 remove_tls_connlimit，省略选项仍不改动已有规则；cron 用 printf %q 转义 self/ip/metrics；precheck_go_network 在 GOPROXY 含 direct 时警告后交由 Go 直连，不自动切换第三方代理。 |
| BUG-020 | 修复 | Bash 64 位算术溢出可让超大端口/天数/RegionID/connlimit 通过范围校验 | 2026-09-20 11:11 | 2026-09-20 11:40 | 已修复 | 本机复现 18446744073709552059 折成 443。decimal_in_closed_range 按去零后的十进制字符串比较；证书天数上限 365000，connlimit 上限 1000000。 |
| BUG-021 | 修复 | 健康检查 cron 只保存 IP，自定义端口/校验模式/安全级别按默认值匹配 unit 导致误报不健康 | 2026-09-20 11:11 | 2026-09-20 11:40 | 已修复 | cron 写入 --derp-port/--stun-port/--security-level 以及 --no-verify-clients 或 --force-verify-clients；--health-check 未显式传参时从 unit 推断。 |
| BUG-022 | 修复 | nftables 限流 flush/删除通用 inet derper 表，可能破坏同名既有规则 | 2026-09-20 11:11 | 2026-09-20 11:40 | 已修复 | 改用 inet derper_tls_connlimit；旧 inet derper 仅按 comment derper-tls-connlimit 删规则，不 flush/不删表。 |
| BUG-023 | 修复 | CI 审查回归必挂：test_certificate_rollback 未 stub systemctl，GitHub Actions（Ubuntu 有真实 systemctl、非 root 运行）下 rollback_cert_update 的 daemon-reload 被 polkit 拒绝（Interactive authentication required）返回 1，子 shell set -e 退出；本地 mac/容器无 systemctl 时 command -v 守卫跳过，故本地全过、CI 必现 | 2026-09-20 11:19 | 2026-09-20 11:24 | 已修复 | 为 test_certificate_rollback 与 test_real_certificate_write_failure 补 systemctl stub（daemon-reload 返回 0，其余返回 1），与套件内其他测试一致；脚本本身不改——真实部署路径的回滚均在 require_root 之后执行。用“daemon-reload 被拒”的 systemctl shim 复现 GA 条件：修复前本地稳定复现 CI 报错，修复后 Bash 3.2/5.2 × 有/无 shim 共 5 种组合全过（主套件 76/76、审查回归 13/13）。 |
| BUG-024 | 修复 | 证书 SAN 匹配缺前边界：新 IP 是旧 IP 子串（如 1.2.3.4 → 11.2.3.4）时误判旧证书有效而跳过重签，derper manual 模式按新 IP 找不到证书文件导致服务启动失败 | 2026-09-20 11:27 | 2026-09-20 12:23 | 已修复 | scripts/deploy_derper_ip_selfsigned.sh:1290/1292 的 grep -E 在 ip_re 前只要求冒号+空白；建议加 ([^0-9.]\|^) 前边界或按逗号逐项精确比对。；SAN 改为 cert_text_san_has_ip 按逗号拆项精确比对；回归 test_cert_san_matches_literal_ip_only 覆盖 3.4.5.6 vs 13.4.5.6。 |
| BUG-025 | 修复 | post_deploy_extras（--tls-connlimit/cron 安装）失败会经 EXIT trap 回滚一个已通过健康验证的证书+服务部署 | 2026-09-20 11:27 | 2026-09-20 12:23 | 已修复 | commit_cert_update 在 post_deploy_extras 之后才执行（main 3877-3917）；无 nft/iptables 主机上 --tls-connlimit 100 会撤销已成功部署。建议验证通过后就地 commit，extras 失败只报告。；各部署分支在 extras 前 commit_cert_update；run_post_deploy_extras 失败只报告不回滚。commit 同时清 CERT_TRANSACTION_ACTIVE。 |
| BUG-026 | 修复 | systemd unit 非原子写入且写 SERVICE_PATH 不防符号链接：写入窗口被 SIGKILL 留截断 unit；证书路径都有 refuse_symlink 而 unit 没有 | 2026-09-20 11:27 | 2026-09-20 12:23 | 已修复 | scripts/deploy_derper_ip_selfsigned.sh:2642（cat >）、1697（cp -p 恢复）；建议同目录临时文件 + mv -f 原子替换，写前 refuse_symlink。；新增 atomic_install_file/atomic_copy_file：同目录 mktemp+mv，写前 refuse_symlink。write_systemd_service、rollback_cert_update、rollback_previous_unit 均改走原子替换。 |
| BUG-027 | 修复 | openssl 或 ss/netstat 缺失时健康服务被误判“启动失败”并触发回滚，错误信息指向“安全选项不兼容”，方向性误导 | 2026-09-20 11:27 | 2026-09-20 12:23 | 已修复 | scripts/deploy_derper_ip_selfsigned.sh:2252（openssl 缺失直接 return 1）、2248-2249（无 ss/netstat 时端口判定恒失败）；依赖安装失败设计上不中止。建议检测工具缺失时明确提示并跳过/硬依赖化。；service_verified_running 在无 ss/netstat/openssl 时警告并跳过对应核验，仍要求 active+MainPID；启动失败文案不再默认归咎安全选项。 |
| BUG-028 | 修复 | uninstall 不清理 derper.service.certs-rollback 事务备份：残留旧私钥，且卸载后首次重新部署会因 recover_cert_update 重启已删服务失败而误报错误退出一次 | 2026-09-20 11:27 | 2026-09-20 12:23 | 已修复 | uninstall_derper（3393-3451）全程未触碰备份目录；recover_cert_update 的 systemctl restart 失败应降级为警告。；uninstall_derper 删除 SERVICE_PATH.certs-rollback；recover 在 unit 缺失时跳过重启，重启验证失败降为警告。 |
| BUG-029 | 修复 | service_verified_running 的 ((tries++)) 在 bash≥4 + set -e 下首值 0 返回 1，是哑弹：当前调用点恰在条件上下文未爆，未来以普通语句调用即无声中止 | 2026-09-20 11:27 | 2026-09-20 12:23 | 已修复 | scripts/deploy_derper_ip_selfsigned.sh:2240；改 ((++tries)) 或 tries=$((tries+1))。；((tries++)) 改为 tries=$((tries + 1))，避免 bash≥4 + set -e 在 tries=0 时中止。 |
| BUG-030 | 修复 | resolve_run_user 的 deployed_user=$(read_derper_unit_content \| awk …) 无 \|\| true：unit 存在但不可读（chmod 600/非 root --check）时 pipefail + set -e 静默退出，无任何脚本自身报错 | 2026-09-20 11:27 | 2026-09-20 12:23 | 已修复 | scripts/deploy_derper_ip_selfsigned.sh:3663；同文件 check_derper_status、infer_ip_from_existing_deployment 均已写 \|\| true，此处漏。；read_derper_unit_content 的 cat 加 \|\| true；resolve_run_user 管道补 \|\| true，与 check_derper_status/infer_ip 一致。 |
| BUG-031 | 修复 | 测试状态泄漏掩盖断言：test_healthcheck_cron_conflicts_with_uninstall 设 INSTALL_HEALTHCHECK_CRON=1 不复位，后续 test_tls_connlimit_conflicts_with_readonly_modes 被 cron 互斥规则先拒绝，删掉 tls 校验测试仍绿 | 2026-09-20 11:27 | 2026-09-20 12:23 | 已修复 | tests/test_deploy_script.sh:1139-1146 等；另有多处 mock 函数（command/curl/ss/nft 等）以全局形式泄漏，靠执行顺序侥幸不炸；建议统一子 shell 包裹或 teardown unset -f。；互斥/mock 测试改子 shell；tls 冲突断言必须命中 tls-connlimit 文案，避免被 cron 互斥误绿。 |
| BUG-032 | 修复 | _timeout_run 后备路径（无 timeout(1) 环境，正是 BUG-017 声称支持的场景）killer 子 shell 被杀后 sleep 被孤儿化，继续持有命令替换管道写 FD：$( ) 调用方阻塞满整个超时时长——本机复现 0.5 秒命令在 $( ) 中卡满 4 秒；resolve_derper_module_version 在 $( ) 中调用，无 timeout 主机每次部署/修复必卡 60 秒，install_derper 路径遗留 sleep 900 孤儿 15 分钟 | 2026-09-20 13:35 | 2026-09-20 14:36 | 已修复 | scripts/deploy_derper_ip_selfsigned.sh:992。最小修复：killer 子 shell 输出重定向 ( sleep "$secs" && kill "$pid" ) >/dev/null 2>&1 &，sleep 不再持有管道；或子 shell 内 trap TERM 时连 sleep 一起杀。BUG-017 修复把更多调用点改走该函数，使此缺陷从死代码变成必走路径。；killer 子 shell 已重定向 stdout/stderr。回归测试：无 timeout 时命令替换内 4 秒预算的 echo 实测 37ms（回退重定向前 4138ms 变红）。 |
| BUG-033 | 修复 | 变异测试证明两处修复无测试钉住：回退 BUG-025 的 main() commit/extras 顺序、删掉 BUG-030 的 \|\| true，两套测试仍全绿 | 2026-09-20 13:35 | 2026-09-20 14:36 | 已修复 | test_run_post_deploy_extras_keeps_verified_deploy 只测单元消息不测 main 顺序，建议加 main 级集成测试；test_resolve_run_user_survives_unreadable_unit 在条件上下文调用，errexit 被禁用导致假绿，建议子 shell 普通语句 + ERR trap。另：test_review_regressions.sh 循环 harness 失败时无 not ok 输出（低）。；已加 test_main_commits_certs_before_post_deploy_extras（awk 钉住 extras 调用前必须 commit）；test_resolve_run_user 改为普通语句+ERR trap，变异删除 pipeline 或 cat 的 \|\| true 均变红。审查套件 harness 失败时输出 not ok 加函数名。 |

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
| ADJ-008 | 调整 | 版本号 0.2.10 → 0.2.11 | 2026-09-20 12:27 | 2026-09-20 12:27 | 已完成 | SCRIPT_VERSION / VERSION / README / REFERENCE / CHANGELOG 统一为 0.2.11（2026-09-20）。收录 [[BUG-017]]~[[BUG-031]]、[[DOC-004]] [[DOC-005]] [[TST-004]]~[[TST-006]]。 |
| ADJ-009 | 调整 | 版本号 0.2.11 → 0.2.12 | 2026-09-20 14:52 | 2026-09-20 14:52 | 已完成 | SCRIPT_VERSION / VERSION / README / REFERENCE / CHANGELOG 统一为 0.2.12（2026-09-20）。收录 [[BUG-032]] [[BUG-033]]、[[DOC-006]]、[[TST-007]]、[[CHK-008]] [[CHK-009]]。CHANGELOG 0.2.11 小节恢复为已提交内容（84 项、CHK-004～007），0.2.11 之后的新修复移入新增 0.2.12 小节。 |

## 检查事项

| ID | 动作 | 事项 | 发现时间 | 完成时间 | 状态 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| CHK-001 | 检查 | 代码安全审计：发现 5 个 P1 与若干 P2/P3 缺口 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已完成 | 产出 12 项修复，见 [[BUG-001]]~[[BUG-012]]；回归测试 26 → 35 项全部通过；受环境限制未做真实 Linux systemd 全链路验证。 |
| CHK-002 | 检查 | 主机/Tailnet 威胁模型评审（公网中继暴露面审计） | 2026-08-14 20:35 | 2026-08-14 20:35 | 已完成 | 结论：风险主要在主机（SSH、节点身份、补丁）而非 DERP 协议（WireGuard 端到端加密、STUN 放大系数≈1）；已落地暴露面检查、自动更新检测、服务器节点 ACL 建议、防火墙加固提示。待办见 [[OPS-001]]~[[OPS-006]]。 |
| CHK-003 | 检查 | 核验外部模型提出的 8 项部署缺陷：逐条比对已提交版本与当前工作区实现 | 2026-09-20 08:05 | 2026-09-20 08:05 | 已完成 | 结论：5 项成立且工作区已修（见 [[BUG-013]] [[BUG-014]] [[BUG-015]] [[BUG-016]] [[DEV-003]]）；check 不闭环一项现象成立但归因有误，unit_matches_desired_config 本就比对 ^User=，根因是运行用户漂移；GOPROXY 与 socket 0666 两项为设计取舍，改进项记为 [[DEV-004]] [[DEV-005]]。所有修复仍停留在工作区，HEAD 尚未提交。 |
| CHK-004 | 检查 | 逐项复核服务器截图的 8 项问题并验证修复 | 2026-09-20 08:10 | 2026-09-20 08:10 | 已完成 | docs/BUGFIX_REVIEW_20260920.md 记录逐项结论；Bash 3.2/5.2 各 63 项测试通过；独立审查发现的服务恢复、旧端点验证和迁移链接环已修复。未连接真实服务器，systemd 和网络采用故障注入。 |
| CHK-005 | 检查 | 核验外部审查提出的 3 项 0.2.10 遗留问题并修复 | 2026-09-20 10:53 | 2026-09-20 11:10 | 已完成 | 三项均成立，见 [[BUG-017]] [[BUG-018]] [[BUG-019]]。审查所称 HEAD 41af117 已过时，当前为改写历史后的 0.2.10 提交。 |
| CHK-006 | 检查 | 核验双审查器提出的 4 项 0.2.10 缺陷：3 项脚本 + 1 项 README | 2026-09-20 11:11 | 2026-09-20 11:40 | 已完成 | 检查时均未修复。随后落地 [[BUG-020]] [[BUG-021]] [[BUG-022]] 与 [[DOC-004]]。 |
| CHK-007 | 检查 | 全仓复审：5 路并行审查脚本（3969 行）、两套测试与四份文档 | 2026-09-20 11:27 | 2026-09-20 11:27 | 已完成 | 基线全绿（主套件 76 项 + 审查回归 13 项）。确认 8 项脚本/测试待修复（[[BUG-024]]~[[BUG-031]]，最高优先级为 SAN 子串误判、extras 失败回滚已验证部署、uninstall 遗留事务备份）与 3 项文档中级失实（[[DOC-005]]）；另记录约 15 项低级健壮性瑕疵（usage 文案偏严、wizard 硬编码 sudo、cron 自身路径未校验、大写 commit 不识别、空输入哈希 e3b0c442 等），随对应条目修复时一并处理。 |
| CHK-008 | 检查 | 精审 V0.2.11（3d00643）全部 15 项修复 BUG-017~031 | 2026-09-20 12:44 | 2026-09-20 12:44 | 已完成 | 结论：未发现新的 P1/P2。验证矩阵 macOS Bash 3.2、debian:12 Bash 5.2、Bash 5.2+systemctl shim 均为 84+14 全绿。apply_tls_connlimit 默认路径无 else 的 if 返回 0，不构成 bug。三条备忘（非阻塞）：live_cert_sha256_raw 在 sha256_hex 失败后 return 0（下游空指纹仍安全失败）；--derp-port 0443 校验通过但原文写入 unit（0.2.10 前既有）；GA 个别测试未 stub systemctl is-active 产生 stderr 噪音。待办仍仅 OPS-001~006。 |
| CHK-009 | 检查 | 对 CHK-008 结论的交叉复核：逐条核验 0.2.11 修复 + 三路并行复审 diff（e7aa336..3d00643） | 2026-09-20 13:35 | 2026-09-20 13:35 | 已完成 | 11 项修复逐条核验属实（含变异测试 20/22 被测试钉住）。但发现 CHK-008 漏掉 1 项 P2：_timeout_run 后备路径孤儿 sleep 阻塞 $( ) 调用方满超时时长（本机复现，见 [[BUG-032]]）；另 2 处修复无测试钉住（[[BUG-033]]）；2 项低级文档残留（[[DOC-006]]）。 |

## 测试数据

| ID | 动作 | 事项 | 发现时间 | 完成时间 | 状态 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| TST-001 | 检查 | 回归测试套件 26 → 35 项扩展 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已完成 | tests/test_deploy_script.sh；新增：STUNPort ACL、指纹缺失安全失败、非公网 IP 拒绝、RegionID 范围、参数组合校验、证书符号链接拒绝、commit 对齐/伪版本匹配、derper_healthy/derper_cert_live_match、暴露面检测、自动更新检测、服务器节点 ACL 建议。bash -n 通过。 |
| TST-002 | 检查 | 回归测试需在 Bash 5 环境执行：macOS 自带 Bash 3.2 不把 local 未赋值变量视为 unset，set -u 类缺陷在本机永远测不出 | 2026-09-20 08:05 | 2026-09-20 09:45 | 已完成 | 已实测：Bash 3.2 下 local a; rm -f "$a" 正常通过，Bash 5.2 下报 a: unbound variable 并退出，这正是 [[BUG-013]] 在服务器必现而本地漏测的原因。建议测试套件在 debian:12 等 Bash 5 容器中执行，或在 CI 固定该环境。；[[CHK-004]] 已在 Bash 3.2/5.2 各跑过一轮；仓库仍无 CI 固定 Bash 5，故保持待办。；.github/workflows/tests.yml 在 Ubuntu（Bash 5）跑主套件与审查回归；get_installed_derper_version 在无 strings 时回退 grep -a，避免极简镜像漏检。 |
| TST-003 | 检查 | 新增 tests/test_review_regressions.sh 覆盖证书事务、用户继承、commit 对齐与轮换确认 | 2026-09-20 08:10 | 2026-09-20 09:25 | 已完成 | 与主套件 tests/test_deploy_script.sh 并列；文档与版本 0.2.10 同步时记账。CI 仍建议在 Bash 5 容器执行，见 [[TST-002]]。 |
| TST-004 | 检查 | 主套件新增 7 项覆盖 timeout 缺失、参数互斥、connlimit 0、cron 引号与 GOPROXY direct | 2026-09-20 10:53 | 2026-09-20 11:10 | 已完成 | tests/test_deploy_script.sh 64 → 71；审查回归 13 项仍全过。本机 Bash 3.2 两套均 exit 0。 |
| TST-005 | 检查 | 主套件新增溢出、cron 完整参数、unit 推断、nft 专属表与 README 示例回归 | 2026-09-20 11:11 | 2026-09-20 11:40 | 已完成 | tests/test_deploy_script.sh 71 → 76；审查回归 13 项仍全过。bash -n 与 git diff --check 通过。 |
| TST-006 | 检查 | 主套件新增 SAN 子串/原子 unit/空指纹/cron 路径/用户解析/extras 提交/缺工具跳过/向导选项校验；审查回归新增 restart 失败降级警告 | 2026-09-20 12:23 | 2026-09-20 12:23 | 已完成 | tests/test_deploy_script.sh 76 → 84；test_review_regressions.sh 13 → 14。互斥测试改子 shell，tls 冲突必须命中 tls-connlimit 文案。bash -n 与 git diff --check 通过。 |
| TST-007 | 检查 | 主套件新增 timeout 后备不阻塞、main commit/extras 顺序；加固 resolve_run_user 与 CHANGELOG/REFERENCE 文档断言 | 2026-09-20 14:36 | 2026-09-20 14:36 | 已完成 | tests/test_deploy_script.sh 84 → 86；test_review_regressions.sh 仍 14 项但 harness 失败会打印 not ok。变异：回退 killer 重定向、对调 commit/extras、删除两处 \|\| true 均使对应测试变红。 |

## 文档维护

| ID | 动作 | 事项 | 发现时间 | 完成时间 | 状态 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| DOC-001 | 文档 | 文档同步至 0.2.8 并补齐上游限制与主机加固说明 | 2026-08-14 20:35 | 2026-08-14 20:35 | 已完成 | README（上游自建 DERP 限制、主机与 Tailnet 加固 5 条、新参数与新指标）、CHANGELOG_CN/EN、REFERENCE_CN/EN。 |
| DOC-002 | 文档 | 文档同步至 0.2.10：证书轮换确认、运行用户继承、commit 对齐与 GOPROXY 行为 | 2026-09-20 09:25 | 2026-09-20 09:25 | 已完成 | README 中英参数表补 --accept-cert-rotation / --yes；REFERENCE 补齐专用用户、安全级别、derper-version 与轮换确认；CHANGELOG_CN/EN 新增 0.2.10；核查记录 docs/BUGFIX_REVIEW_20260920.md 标注对应版本。；0.2.10 文档已补 --tls-connlimit / --install-healthcheck-cron / GOPROXY 预检 / socket 恢复 / GitHub Actions。 |
| DOC-003 | 文档 | 同步 --tls-connlimit 0 / cron 互斥 / GOPROXY direct 回退说明 | 2026-09-20 10:53 | 2026-09-20 11:10 | 已完成 | README 中英参数表、REFERENCE_CN/EN、CHANGELOG_CN/EN 0.2.10 条目已更新。 |
| DOC-004 | 文档 | README 中英补 --cert-days/--derper-version，正式示例改公网 IP 占位符，场景表改为可执行组合 | 2026-09-20 11:11 | 2026-09-20 11:40 | 已完成 | TEST-NET-3 203.0.113.10 不再作为正式 --ip 示例；ACL 输出样例仍可用文档地址。CHANGELOG_CN/EN 已记 11–14。 |
| DOC-005 | 文档 | 文档三处中级失实：REFERENCE_EN “Dedicated derper user” 示例误用 --use-current-user（标题与内容对调）；REFERENCE_CN:431/EN:399 证书目录所有权写成 derper:derper（实际 root:组只读）；README:1021 与 CHANGELOG_CN/EN:59 链接指向不存在的 docs/BUGFIX_REVIEW_20260920.md（实际在 plans/） | 2026-09-20 11:27 | 2026-09-20 12:23 | 已完成 | 顺带修正低级项：README “2100+ 行”实际约 3900 行；--use-current-user“等价于 --user $USER”说法不准（sudo 下实为 SUDO_USER）；usage 与 REFERENCE 中 --metrics-textfile “必须与 --health-check 一起使用”偏严（实现允许配 --install-healthcheck-cron）。；REFERENCE_EN 专用用户示例改为 --dedicated-user；证书目录改为 root:服务组 750/密钥 640；断链改为指向 task-list.md。顺带：README 约 4100 行、SUDO_USER 文案、metrics-textfile 允许配 cron、wizard 无 sudo 的 root 容器、选择题校验、cron 校验脚本路径、大写 commit、空指纹 e3b0c442 拒绝。 |
| DOC-006 | 文档 | DOC-005 残留两处低级文档问题：CHANGELOG_CN/EN 0.2.10 历史条目（现 :78）仍引用未入库的 docs/BUGFIX_REVIEW_20260920.md（文件在 plans/ 且已被 git 历史清除）；REFERENCE_CN:256/EN:221 的 --cert-days 未标注有效范围 1–365000（README 已标注） | 2026-09-20 13:35 | 2026-09-20 14:36 | 已完成 | 历史条目属行内代码而非可点链接，严重度低；建议改为指向 task-list.md（CHK-004～CHK-009）或加注文件位于未入库 plans/。；CHANGELOG 0.2.10 历史条目改为指向 task-list.md（CHK-004～CHK-009）；REFERENCE 中英与 usage 的 --cert-days 补 1–365000；test_readme 同时钉住 CHANGELOG 断链与范围文案。 |

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
