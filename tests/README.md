# tests/ 测试套件说明

本目录是 deploy_derper_ip_selfsigned.sh 的全部回归与验收测试。产品脚本的缺陷状态以根目录 `task-list.md` 台账为准；本文件说明套件分工、命名体系与运行方式，新增用例必须遵循。

## 套件总览

| 文件 | 职责 | 运行环境 | CI | 传参单跑 | 退出码 |
| --- | --- | --- | --- | --- | --- |
| test_deploy_script.sh | 主回归套件：参数解析、环境检查、证书、unit、防火墙、健康检查、向导、main 编排与底层辅助函数（105 个注册入口，含安装进度伪终端验证和失败门禁变异回归，按领域组织） | 非 root（root 专属断言自动跳过） | ✅ | ✅ | 0 通过 / 1 有失败 |
| test_review_regressions.sh | 审查回归：历次审查反例的先红后绿用例、B 阶段行为、回环接口与加固一致性、默认发布门禁/LocalAPI服务用户请求，以及 BUG-130～143 诊断边界/维护提示/RegionID预检/健康调度/最小授权/Go构建缓存与空间门禁（93 用例） | 非 root（root/工具缺失场景输出 skip） | ✅ | ✅ | 0 通过 / 1 有失败 |
| test_s2_fixes.sh | S2 批次修复行为回归（BUG-053/055/059/060/061/070/077～081/110，24 用例），替身服务管理，含已就绪跳过、首次迁移/权限修复/恢复集保护及unit仅最终重启 | 非 root，需 gcc | ✅ | ✅ | 0 通过 / 1 有失败 |
| test_s2_evidence.sh | 真实环境证据：flock、服务用户权限、旧用户恢复、BUG-110就绪跳过/换用户/不可读拒绝，以及 root 拒绝低权限同名进程/不可信 inode | 需 root + flock + useradd + gcc | ✅（sudo） | ❌（整文件执行） | 0 通过 / 1 失败 / 2 环境不符 |
| test_c_stage.sh | C 阶段契约与行为（DEV-011/012/013）：配置白名单、新旧 CLI、ELF 导入、JSON/derpMap、H0～H3、状态与门禁（33 用例）；需 python3，ELF 用例需 gcc | 非 root；2项 root 专属用例退出 77 跳过 | ✅（含 sudo 补跑 root 用例） | ✅ | 0 通过 / 1 有失败 |
| test_d_stage.sh | D 阶段契约与行为（DEV-008）：prepare/apply/cancel、HuJSON 最小补丁、策略 API 替身、自动/人工/未知三态、启用/停用持久化与维护 unit，以及事务归档、身份绑定、OAuth/ETag/HTTP 状态、timer 参数、符号链接写入、内网放行继承、cancel/maintain 反馈、purge-all、换证回滚重启、停用优先、幂等启停、过期续期、短期证书提前天数、调度失败跨命令持久化和安装根目录链接拒绝、Tailnet 目标和配置提前天数显式校验回归及反向补偿、BUG-111 本地恢复/归档失败/停止意图、BUG-113 BSD locale、BUG-114 实际 VM 执行块回归、BUG-116/118～121 maintain 结束状态/候选有效期/到期未知/反向补偿歧义/卸载传播，以及云端已更新后重试、尚未生效候选和 maintain 停用入口回归（85 用例）；需 openssl，HuJSON 补丁需 python3 | 非 root | ✅ | ✅ | 0 通过 / 1 有失败 |
| test_systemd_integration.sh | GB及可选C/D集成：真实systemd PID1一次性VM执行发布/恢复/健康与证书维护timer，D仅用本地HTTP fixture（非GD） | 仅人工标记的一次性 VM（`DERPER_INTEGRATION_VM=1` + `/root/DERPER_DISPOSABLE_GB_VM`），否则退出 2 | 手动（自托管一次性 VM） | ❌ | 0 通过 / 1 失败 / 2 环境不符 |

| test_h3_probe.py / test_acceptance_assets.py | 独立客户端适配器（含 ping 归因、双栈地址、STUN 复核预算与旧版 Python socket.timeout 兼容）、真实Unix socket/UDP协议、HTTP fixture及CI/清理契约（26项） | Python3，Linux/macOS本地替身 | 固定矩阵 | unittest | 0通过 / 非零失败 |

真实VM、隔离GD/H3及长效兼容的逐步操作见[真实验收操作包](REAL_ACCEPTANCE.md)。本地Python回归不能替代真实Tailnet证据。

## 命名体系

- **文件名**：`test_<对象或批次>.sh`。主套件按对象（deploy script）；批次套件按交付批次（s2_fixes、c_stage）或用途（review_regressions、s2_evidence、systemd_integration）。文件重命名会同时牵动 CI 与台账引用，除非整批重组否则不改名。
- **用例函数名**：三种前缀，各自归属固定：
  - `test_bug<台账ID>_<行为>`：钉住某个已关闭缺陷的反例（如 `test_bug061_scheduled_healthcheck_keeps_non_global_ip_opt_in`），台账 ID 与根目录 task-list.md 一一对应；
  - `test_b1_ / test_b2_ / test_b3_<行为>`：B 阶段工作包级行为（锁/候选发布/安装树），对应 DEV-006 的三个子包；
  - `test_<领域>_<行为>`：无单一缺陷编号的领域行为（主套件全部用例与 C 阶段多数用例），名称描述可观察行为而非实现（如 `test_json_outputs_keep_stdout_clean_when_ip_inferred`）。
- **辅助函数**：`fail`（输出 `not ok -` 并使当前用例失败）、`ok`（仅主套件，用例成功时输出可读摘要）、`skip`（输出 `skip -`，不按通过计数）。

## Harness 约定（全部套件统一）

1. **子 shell 隔离**：每个用例在独立子 shell 中执行（`DERPER_TEST_MODE=1 source` 产品脚本 + `mktemp -d` 临时目录 + EXIT 清理），用例间不泄漏函数与变量。
2. **累计失败计数**：主套件在非条件子 shell 中启用 `errexit`，父进程捕获并累计退出码；禁止把用例放进 `if` 或 `||` 条件而抑制内层失败。BUG-112 用必然失败的副本确认退出非零且后续用例继续执行。一个用例失败不中止整个套件，全部执行完输出 `not ok - <用例名>` 清单并以退出码 1 结束（主套件与审查回归自本轮起由首败即停改为计数制，与 s2_fixes/c_stage 一致）。
3. **跳过语义**：环境不具备（root、python3、flock、Unix socket 等）时输出 `skip - <原因>`，不得计入通过；root 专属用例用退出码 77 标记并由 CI 的 sudo 步骤单独补跑；一次性 VM 套件整体以退出码 2 表示“环境不符”，不能当失败或通过。
4. **单用例运行**：可运行的套件支持 `bash tests/<套件>.sh <测试函数名> [...]` 只执行指定用例，用于定位与变异验证。
5. **注册防死函数**：新增用例必须同时登记进文件尾部的用例列表（`cases=(` / `tests=(` / `selected=(`）；只定义不注册的用例永远不会被执行。
6. **断言可观察行为**：断言输出/退出码/文件效果，不只断言函数或字符串存在（见台账 BUG-033 的教训）。

## 覆盖映射（台账 ID → 套件）

| 台账范围 | 套件 |
| --- | --- |
| BUG-001～033（早期审计与修复，TST-009 按领域重组） | test_deploy_script.sh（描述性命名的等价断言） |
| BUG-034～052、BUG-054～058（A 批审查反例 + 复查重开项） | test_review_regressions.sh |
| B 阶段 b1/b2/b3（BUG-036/037，DEV-006） | test_review_regressions.sh（test_b1/b2/b3_*） |
| BUG-053/055/059/060/061/070/077～081（S2 修复轮） | test_s2_fixes.sh；BUG-080真实跨用户证据另在test_s2_evidence.sh |
| BUG-081 新增回归入口 | test_bug081_rollback_restores_absent_unit_and_state_set、test_bug081_cleanup_failure_keeps_marker、test_bug081_hidden_state_and_unsafe_entries、test_bug081_unit_cleanup_and_reload_failure_keep_marker；真实unit缺失回退另在test_systemd_integration.sh |
| 真实 flock/权限/双用户回退证据（TST-014/016） | test_s2_evidence.sh（root） |
| BUG-062 重复回退、C 阶段全部契约（DEV-011/012/013） | test_c_stage.sh |
| D 阶段 prepare/apply/cancel、策略替身与维护三态（DEV-008） | test_d_stage.sh |
| BUG-101～108（BUG-100 与105同源） | test_d_stage.sh 中 test_bug101_～test_bug108_ 入口；目标缺失/来源、配置提前天数、调度跨命令状态与换证边界 |
| BUG-111～114、116、118～121 | test_d_stage.sh 的 test_bug111_、test_bug113_、test_bug114_、test_bug116_、test_bug118_～test_bug121_；主套件 test_bug112_harness_propagates_inner_failures 验证真实失败传播与累计 |
| BUG-117、122、123 | test_review_regressions.sh 的 test_bug117_（默认部署门禁）、test_bug122_（LocalAPI 按 derper 服务用户判断）、test_bug123_（切换为该用户实际请求 LocalAPI，属主/权限位不作为健康依据；需 python3 与 Unix socket，否则 skip） |
| BUG-130～136 | test_review_regressions.sh 的 test_bug130_～test_bug136_；RegionID占用/同目标/多节点/显式放行/结构异常/显式IPv4/解析未知与临时Go缓存均有行为断言 |
| BUG-137 | test_deploy_script.sh 的 test_main_modes_end_to_end_orchestration 使用固定derpMap并覆盖完整入口冲突阻断；test_review_regressions.sh 的 BUG-117 main 夹具同步隔离真实Tailnet |
| BUG-138、ADJ-037 | test_review_regressions.sh 的 test_bug138_scheduled_healthcheck_preserves_config_and_region 与 test_adj037_healthcheck_uses_stable_config_only；覆盖相对/绝对配置路径、单来源稳定配置、无配置时Region继承及H3去重；test_adj037_report_health_summary_order_and_not_installed 覆盖摘要顺序和未安装状态，主套件覆盖check冲突完整总结 |
| BUG-139 | test_review_regressions.sh 的 test_bug139_readonly_go_cache_is_cleaned_and_empty_tmpdir_refused；覆盖只读Go模块缓存随退出清理，以及安全临时目录未初始化时拒绝构建 |
| BUG-140 | test_d_stage.sh 的 test_bug103_idempotent_deploy_honors_maintain_switch 固定 RegionID 预检，幂等部署用例不再读取本机真实 derpMap |
| BUG-141～143 | test_review_regressions.sh 的 test_bug141_（同地址改端口/空Nodes/未知IP）、test_bug142_（最小授权建议与双语文档）、test_bug143_（持久缓存、独立查询两文件系统空间门禁、root属主/链接拒绝及独立临时目录清理） |
| BUG-066/067、071～076 | test_c_stage.sh新增8个test_bug<ID>入口；067直接覆盖rollback_deploy_change首装分支，071含忽略TERM及父进程先退出的子进程清理，072以root补验状态/指标祖先权限，074含词法/符号/硬链接别名，075检查目标/检查范围切换。真实首装拒停及独立CLI重试另在test_systemd_integration.sh |
| GB 真实 systemd 故障注入（TST-017） | test_systemd_integration.sh（一次性 VM） |
| BUG-063 Bash 3.2 兼容 | 全部套件须在 macOS Bash 3.2 与 Linux Bash 5 双环境通过 |
| 后续新增缺陷 | 修复时按先红后绿补入对应套件，实际状态见task-list.md，不在本文复制容易过期的待修编号列表 |

## 本地运行

```bash
bash -n scripts/deploy_derper_ip_selfsigned.sh
bash tests/test_deploy_script.sh
bash tests/test_review_regressions.sh
bash tests/test_s2_fixes.sh
bash tests/test_c_stage.sh                 # 需 python3；ELF 用例需 gcc
bash tests/test_d_stage.sh                 # 需 openssl；HuJSON 补丁需 python3
sudo bash tests/test_s2_evidence.sh        # 需 root + flock
shellcheck -S error scripts/deploy_derper_ip_selfsigned.sh tests/*.sh
python3 -m unittest discover -s tests -p 'test_*.py'
# 一次性VM（CI手动入口需root disposable-vm runner；可选C/D开关）：
DERPER_INTEGRATION_VM=1 DERPER_INTEGRATION_C=1 DERPER_INTEGRATION_D=1 DERPER_TEST_BINARY=/root/derper bash tests/test_systemd_integration.sh
```

主套件与审查回归建议在 Bash 5 环境（Linux/WSL/debian:12 容器）执行完整套件，macOS Bash 3.2 用于兼容性抽查（见台账 TST-002）。
