# tests/ 测试套件说明

本目录是 deploy_derper_ip_selfsigned.sh 的全部回归与验收测试。产品脚本的缺陷状态以根目录 `task-list.md` 台账为准；本文件说明套件分工、命名体系与运行方式，新增用例必须遵循。

## 套件总览

| 文件 | 职责 | 运行环境 | CI | 传参单跑 | 退出码 |
| --- | --- | --- | --- | --- | --- |
| test_deploy_script.sh | 主回归套件：参数解析、环境检查、证书、unit、防火墙、健康检查、向导、main 编排与底层辅助函数（104 用例，含安装进度的伪终端验证，按领域组织） | 非 root（root 专属断言自动跳过） | ✅ | ✅ | 0 通过 / 1 有失败 |
| test_review_regressions.sh | 审查回归：历次审查反例的先红后绿用例（BUG-014～058 主要条目）、B 阶段 b1/b2/b3 行为、BUG-109 回环接口后缀及中英文加固示例与实际 unit 一致性（68 用例） | 非 root（root/工具缺失场景输出 skip） | ✅ | ✅ | 0 通过 / 1 有失败 |
| test_s2_fixes.sh | S2 批次修复行为回归（BUG-053/055/059/060/061/070/077～081/110，24 用例），替身服务管理，含已就绪跳过、首次迁移/权限修复/恢复集保护及unit仅最终重启 | 非 root，需 gcc | ✅ | ✅ | 0 通过 / 1 有失败 |
| test_s2_evidence.sh | 真实环境证据：flock、服务用户权限、旧用户恢复、BUG-110就绪跳过/换用户/不可读拒绝，以及 root 拒绝低权限同名进程/不可信 inode | 需 root + flock + useradd + gcc | ✅（sudo） | ❌（整文件执行） | 0 通过 / 1 失败 / 2 环境不符 |
| test_c_stage.sh | C 阶段契约与行为（DEV-011/012/013）：配置白名单、新旧 CLI、ELF 导入、JSON/derpMap、H0～H3、状态与门禁（33 用例）；需 python3，ELF 用例需 gcc | 非 root；2项 root 专属用例退出 77 跳过 | ✅（含 sudo 补跑 root 用例） | ✅ | 0 通过 / 1 有失败 |
| test_d_stage.sh | D 阶段契约与行为（DEV-008）：prepare/apply/cancel、HuJSON 最小补丁、策略 API 替身、自动/人工/未知三态、启用/停用持久化与维护 unit，以及事务归档、身份绑定、OAuth/ETag/HTTP 状态、timer 参数、符号链接写入、内网放行继承、cancel/maintain 反馈、purge-all、换证回滚重启、停用优先、幂等启停、过期续期、短期证书提前天数、调度失败跨命令持久化和安装根目录链接拒绝、Tailnet 目标和配置提前天数显式校验回归（52 用例）；需 openssl，HuJSON 补丁需 python3 | 非 root | ✅ | ✅ | 0 通过 / 1 有失败 |
| test_systemd_integration.sh | GB 集成：真实 systemd PID1 的一次性 VM 中执行完整发布/回退/恢复/生成任务 | 仅人工标记的一次性 VM（`DERPER_INTEGRATION_VM=1` + `/root/DERPER_DISPOSABLE_GB_VM`），否则退出 2 | ❌（VM 门禁） | ❌ | 0 通过 / 1 失败 / 2 环境不符 |

## 命名体系

- **文件名**：`test_<对象或批次>.sh`。主套件按对象（deploy script）；批次套件按交付批次（s2_fixes、c_stage）或用途（review_regressions、s2_evidence、systemd_integration）。文件重命名会同时牵动 CI 与台账引用，除非整批重组否则不改名。
- **用例函数名**：三种前缀，各自归属固定：
  - `test_bug<台账ID>_<行为>`：钉住某个已关闭缺陷的反例（如 `test_bug061_scheduled_healthcheck_keeps_non_global_ip_opt_in`），台账 ID 与根目录 task-list.md 一一对应；
  - `test_b1_ / test_b2_ / test_b3_<行为>`：B 阶段工作包级行为（锁/候选发布/安装树），对应 DEV-006 的三个子包；
  - `test_<领域>_<行为>`：无单一缺陷编号的领域行为（主套件全部用例与 C 阶段多数用例），名称描述可观察行为而非实现（如 `test_json_outputs_keep_stdout_clean_when_ip_inferred`）。
- **辅助函数**：`fail`（输出 `not ok -` 并使当前用例失败）、`ok`（仅主套件，用例成功时输出可读摘要）、`skip`（输出 `skip -`，不按通过计数）。

## Harness 约定（全部套件统一）

1. **子 shell 隔离**：每个用例在独立子 shell 中执行（`DERPER_TEST_MODE=1 source` 产品脚本 + `mktemp -d` 临时目录 + EXIT 清理），用例间不泄漏函数与变量。
2. **累计失败计数**：一个用例失败不中止整个套件，全部执行完输出 `not ok - <用例名>` 清单并以退出码 1 结束（主套件与审查回归自本轮起由首败即停改为计数制，与 s2_fixes/c_stage 一致）。
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
# 一次性 VM（不接入 CI，见 tests/test_systemd_integration.sh 头部说明）：
DERPER_INTEGRATION_VM=1 DERPER_TEST_BINARY=/root/derper bash tests/test_systemd_integration.sh
```

主套件与审查回归建议在 Bash 5 环境（Linux/WSL/debian:12 容器）执行完整套件，macOS Bash 3.2 用于兼容性抽查（见台账 TST-002）。
