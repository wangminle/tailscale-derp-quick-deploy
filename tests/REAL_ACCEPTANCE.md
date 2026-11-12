# S0～S4 真实验收操作包

本文件描述可执行步骤，**不是通过报告**。本地回归/HTTP fixture不能关闭真实GD/H3。先完成一次性VM，再在同一隔离Tailnet完成GD/H3/长效兼容。生产迁移另列，不使用现网节点做失败注入。所有日志保存在本地checkpoints，策略正文/凭据/私钥不提交Git，不贴到聊天。

## 当前进度（2026-10-28）

当前工作区已在 Ubuntu 22.04/24.04 一次性 KVM 客体通过未放宽断言的正式 C/D 套件，两平台各 23 条成功输出、退出 0，包含 `success_replaced` 结束状态、恢复、停用和清理；root C 各 2 项、S2 真实权限/锁各 5 项通过。Debian WSL 补验 ShellCheck 和 root C；京东云普通用户回归及回环 TLS/STUN、用户级 systemd 实验通过。源码与测试产物摘要已核对，状态见根目录 task-list.md 的 TST-032。

此次结果未覆盖真实云端策略写入、合法客户端指定 Region 转发或长效客户端兼容；0.2.20 提交已有[成功的 GitHub 固定矩阵记录](https://github.com/wangminle/tailscale-derp-quick-deploy/actions/runs/40688160233)，当前 0.3.0 工作区尚未由该运行覆盖。VM 中的停用场景直接调用 `apply_auto_maintain_policy`，不能单独作为 BUG-129 完整 `maintain --disable-auto-maintain` 命令的真实 VM 证据（该入口已有 D 阶段本地回归）。同样，BUG-127 的失败后重试和 BUG-128 的未来证书拒绝目前由本地回归证明。后续补验这些精确故障路径时应单独留证，不能由通用 C/D 成功外推。

当前暂缺专用 Tailnet、Region 和独立客户端；第二步及后续步骤待资源就绪后执行。第一步保留为复现说明，无需因文档更新重复创建 VM。

## 第一步：提供一次性VM（需要用户准备资源）

准备两台**可销毁、无DERP部署**的Ubuntu22.04和24.04 VM。必须systemd PID1、虚拟机（普通容器/WSL不能替代）、root权限、2GB内存和可用网络。告知SSH主机别名、架构；不要发送私钥。普通固定矩阵CI在GitHub托管runner运行，真实PID1套件使用独立一次性VM/自托管runner。

在VM安装依赖，并准备与你计划验证版本一致、来源已核对的真实derper可执行文件（示例测试版本v1.104.1，不用脚本假冒）：

```bash
sudo apt-get update
sudo apt-get install -y bash ca-certificates curl openssl iproute2 python3 util-linux procps coreutils
sudo install -o root -g root -m 755 /你已核验的derper产物 /root/derper
sudo touch /root/DERPER_DISPOSABLE_GB_VM
```

把当前源码的scripts/、tests/、VERSION复制到VM独立目录，例如/root/derper-acceptance；不要复制凭据或整个checkpoints。若通过CI运行，runner必须以能读取/root/derper并通过root门禁的身份执行，且有self-hosted、disposable-vm标签。随后：

```bash
sudo -i
cd /root/derper-acceptance
env DERPER_INTEGRATION_VM=1 DERPER_INTEGRATION_C=1 DERPER_INTEGRATION_D=1 \
  DERPER_TEST_BINARY=/root/derper DERPER_TEST_ARTIFACTS=/root/derper-evidence \
  bash tests/test_systemd_integration.sh > /root/derper-acceptance.log 2>&1
rc=$?
printf 'suite_exit=%s\n' "$rc"
cat /root/derper-evidence/cleanup.txt
```

0才表示所选场景和清理通过；1为失败；2为环境不符/未验。失败时也取回整个evidence目录及顶层日志，不立即删除VM。应有environment.txt（系统/脚本/产物摘要）、journal.txt、generated-units、C/D产物、fingerprints与cleanup.txt。确认无残留后销毁VM并记录资源清理。D使用127.0.0.1 HTTP fixture，只证明真实systemd编排，不能作为云端GD。脚本会改默认安装路径，仅限此一次性VM。

固定Ubuntu22.04/24.04的shell/root矩阵须在实际GitHub workflow执行并保存job链接、commit/工作树摘要和日志。0.2.20已取得成功运行；当前0.3.0含后续修复，需提交后单独运行，不能直接沿用旧提交的结果。

## 第二步：准备隔离Tailnet和合法客户端（需要用户准备/授权）

提供以下**非敏感信息**：隔离Tailnet名称、明确允许修改的测试RegionID/节点IP/TCP/UDP端口、DERP测试机及两个客户端SSH别名/客户端Tailnet IP、版本。确认是隔离资源并允许本节点字段写入、测试换证/短暂中断和失败注入后，再执行下一步。

- DERP测试机的tailscaled及两个独立客户端都加入同一隔离Tailnet；保留verify-clients开启，derper/tailscaled实际revision兼容。服务器peer map能看到两客户端。
- Region中只放一个被验DERP节点，地址使用显式IPv4/IPv6或与目标完全相同的数字IP HostName，保留官方其他区域与既有策略。H3适配器会拒绝多节点歧义；同一节点同时下发IPv4和IPv6时，客户端可能经另一地址中继，适配器无法证明目标地址可用，会返回unknown。需要验证某一地址时，测试节点只应下发该地址族，或接受该项记为未验证。
- 在测试机本地按examples/policy-api.env.example创建root0600凭据文件，使用隔离Tailnet的OAuth client credentials和明确policy_file权限。凭据不粘聊天、不写命令行参数、不放deploy.conf。静态token无法确认scope时保持unknown，不绕过授权判断。
- 用户/管理员在后台核对最小权限及必要依赖scope；GitOps策略先走仓库流程，不让脚本双写。生产Tailnet不用于本轮。

## 第三步：真实H3适配器与指纹传播

将scripts/h3_probe.py安装在**独立Linux客户端A**的root可信路径（例如/opt/derper-probe/h3_probe.py，root0755）；已有tailscaled处于Running，客户端B是可见的独立合法对端。无需读取节点私钥或创建随机DERP身份。

```bash
sudo python3 /opt/derper-probe/h3_probe.py \
  --region-id 测试RegionID --ip 测试DERP公网IP --derp-port 测试TCP端口 \
  --stun-port 测试UDP端口 --peer-ip 客户端B的TailnetIP --timeout 10
```

成功需同时确认：当前控制面下发的单节点Region/地址/端口匹配；下发CertName与服务DER证书摘要一致；真实tailscaled disco往返结果的DERPRegionID是本Region；对端为B；STUN Binding响应事务及映射地址有效。 stdout为8行协议、退出0。确认故障退出1；直连、其他Region、陈旧指纹、LocalAPI不可用等退出2/不输出成功报告。它不会强制改路由，直连并非DERP故障，只是未取得所需证据。

若一直直连/走官方区域：在**可销毁客户端**由管理员采用可撤销且限定目标的测试网络条件，使A/B实际通过被验Region；记录变更和还原。不要在生产客户端全局封UDP，也不要把关闭verify-clients后的debug derp成功作为替代。可先启动新测试客户端观察首次实际DERP往返；只有返回指定Region才收证。探针不自动改网络、不保证选择目标Region。

在DERP测试机可安装专用root管理的SSH wrapper作为--external-probe，固定远端主机/程序/peer；先登记SSH host key并配置非交互只允许运行该探针的访问。示意（替换所有占位值）：

```bash
#!/bin/bash
exec /usr/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=3 \
  h3-client-a /usr/bin/python3 /opt/derper-probe/h3_probe.py --peer-ip 100.64.0.2 "$@"
```

上述wrapper调用普通OpenSSH，不是`tailscale ssh`，不要求开启Tailscale SSH。

wrapper及全部祖先root所有、不可组/其他用户写，不能链接；不要把远端凭据放在参数。探针10秒预算加SSH连接应小于产品--probe-timeout（可显式设20），两机时钟同步。使用status --external-probe /root可信wrapper --require-h3 --format json复核H3=healthy并留证；调用参数还应显式给定本次目标配置。

实现基于上游[v1.104.1 LocalAPI](https://github.com/tailscale/tailscale/blob/v1.104.1/client/local/local.go)和[STUN协议实现](https://github.com/tailscale/tailscale/blob/v1.104.1/net/stun/stun.go)，LocalAPI返回类型可能随版本变化；本地替身通过不等于已实测此版本。适配器只输出目标与本次结果，不转储节点密钥/策略。

## 第四步：GD真实策略写入与恢复（与H3同一环境）

先备份本地配置/证书和原策略到root本地私密目录，记录目标字段、ETag、证书摘要、服务PID/版本；不把原策略作为自动恢复载荷上传。每例完成后核对其他Region/注释/规则不变；保存脱敏差异与摘要，不保存token。

| 顺序 | 真实操作 | 通过条件/后续 |
| --- | --- | --- |
| G1 基线 | 读取策略、validate、独立客户端H3 | GET/validate仅证明可读/可验证；原指纹/服务/实际客户端吻合 |
| G2 人工准备/取消 | prepare后记录候选与片段；cancel；在隔离机补验尚未生效/过期候选 | 云端/正式证书/进程不变；失效候选应用被拒且重新prepare不复用，取消只删候选 |
| G3 首次登记 | 仅另一个隔离空目标上，先确认write_ready并显式登记自动维护授权，再prepare/apply追加本节点 | 不覆盖官方或其他节点；冲突拒绝；客户端确实收到该Region。已有登记则记录不适用，另用隔离空目标完成本例 |
| G4 真实轮换 | 先在本次目标配置下显式deploy --enable-auto-maintain并确认ready，再prepare/apply；故障用例前停止timer避免并发 | 真POST/If-Match读回；云端/磁盘/运行证书一致，A/B重新H3确认新指纹已传播；保留旧事务 |
| G5 并发保护 | 管理员在隔离目标制造ETag变化/目标字段被他人修改 | 不覆盖他人字段；停止自动回退并needs_coordination；保留人工修复材料 |
| G6 写入超时 | 在隔离测试机用经review的单次故障注入，使真实POST已到达但响应丢失 | 先GET读回再决定继续；最多一次预期正向写，无盲目重签或整份回写。注入方案先审阅，不在生产网络试验 |
| G6b 写后读回失败/中断 | 真实POST成功后仅令读回失败或在本地切换前中断；记录云端新指纹与本地旧指纹，再重试同一候选 | 指定Region/唯一目标确认后完成本地切换，不重复提交；歧义或目标变化仍拒绝。与G6同样先审阅注入方案 |
| G7 本地切换失败 | 真实POST成功后令新服务首次restart失败、旧服务可恢复 | 旧磁盘及实际服务身份确认后才以最新ETag反向撤回本工具字段；读回旧值，H3恢复 |
| G8 旧服务也恢复失败 | 在隔离VM限制两次启动，再解除限制 | 保留云端新指纹、标记needs_coordination/needs_manual，不误报完整恢复；管理员核对实际身份后协调字段并恢复H3 |
| G9 撤权与timer | 显式启用；未到期运行、到期运行；撤销凭据再运行；执行maintain --disable-auto-maintain并卸载 | 真timer/稳定副本/target/到期和失败语义正确；撤权不提前换证；停用命令退出0、intent=disabled且timer移除，后续无参数maintain不得换证；卸载后无调度/凭据泄漏；journal与状态一致 |

注意：单独`apply --accept-cert-rotation`只确认人工本地切换，并不自动获得API同步授权，不能拿它记录G4真POST证据。人工路径应由管理员先按候选片段同步策略，再apply接受切换窗口并用H3复验；该路径与API写入验收分别留证。自动分支须有效write_ready且有本次明确启用/历史登记的授权；命令应始终带同一测试目标配置。G9验证实际timer前再显式启用，不能把故障注入期暂停timer误当生产维护策略。

G5～G8的注入必须限制在本轮明确的目标/请求，管理员有备用管理通道；届时由执行人先提供实际可审阅命令。本文件给出验收要求，不凭空声明故障已发生或把本地fixture结果记成真云端。

## 第五步：长效兼容矩阵

默认365天和用户明确选择的长效值分别跑。建议先检验3650天；若交付声称支持更长寿命，须增加对应值，不从3650天推断1000年客户端兼容。测试表逐格填实际版本/结果/证据路径：

| 环境 | 证书寿命 | 实际derper/tailscaled/客户端版本 | 加载+下发pin+H3 | 成功轮换/传播 | 失败回退+H3 | 证据 |
| --- | --- | --- | --- | --- | --- | --- |
| 隔离Linux客户端A/B，支持版本组合1 | 365天 | 待填写 | 待验 | 待验 | 待验 | - |
| 同上 | 3650天或实际承诺值 | 待填写 | 待验 | 待验 | 待验 | - |
| 另一个声明支持的客户端版本/系统（如Windows） | 同上两档 | 待填写 | 待验 | 待验 | 待验 | - |

Linux适配器不能替代Windows客户端实证。Windows应保存自己实际下发配置和真实指定Region往返输出；输出只有direct/netcheck时仍未验。不必无依据扩大支持版本范围，但已声明范围内不能留空。

## 关闭任务前核对

真实VM两平台、GD各场景、真实H3与传播、长效矩阵必须分别有通过/失败/不适用理由及原始本地证据。记录具体脚本/derper摘要、版本/时刻/目标/退出码、清理与恢复结果；当前工作树或版本改变时核对是否需重验。届时更新TST-019及对应真实验收条目，最后才关闭DEV-007/008。S5生产部署/发布和S6可选ACME不在本轮自动执行。
