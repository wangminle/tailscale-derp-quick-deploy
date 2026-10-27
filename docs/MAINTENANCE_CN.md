# 配置、维护入口与检查范围

本指南描述已实现的配置、检查和维护入口。证书轮换提供 prepare/apply/cancel 与同机维护任务；云端策略写入只用合成替身验收，隔离 Tailnet 真写仍待办。脚本继续以单文件运行，旧参数保留。

## 命令与兼容

| 子命令 | 旧入口/行为 |
| --- | --- |
| deploy | 无主模式 flag 的幂等部署 |
| check | --check / --dry-run，配置与环境预检 |
| health / status | --health-check，只读采样；默认文本，可 --format json |
| repair | --repair |
| uninstall | --uninstall，原 purge 参数不变 |
| recover | --recover-interrupted，只恢复持久未完成变更 |
| derpmap | 从本次已验证的在线身份输出本节点 Regions JSON 片段 |
| prepare | 生成候选证书和本节点片段，不切换正在运行的服务 |
| apply | 确认后切换本地证书；已记录自动维护且写授权就绪时同步 CertName |
| cancel | 丢弃候选，正式证书不变 |
| maintain | 同机 timer 入口：到期才换证，缺条件保留旧证书 |

子命令必须放在选项前。相同模式可以重复表达，相反模式拒绝，例如 `deploy --uninstall`、`status --repair`。`--force` 仍为旧的强制重装/重签路径，保留原换证确认要求；通常升级使用 deploy 并复用有效证书。

```bash
bash scripts/deploy_derper_ip_selfsigned.sh status --format json
bash scripts/deploy_derper_ip_selfsigned.sh --health-check
sudo bash scripts/deploy_derper_ip_selfsigned.sh repair --ip YOUR_PUBLIC_IP
sudo bash scripts/deploy_derper_ip_selfsigned.sh recover
```

health/status 的退出码：0 表示所请求范围通过，1 表示确认故障或结果写入失败，2 表示未知、采集受限或旧指标过期。未知优先于同时存在的确认故障；各层状态仍分别保留。0 的检查范围须结合 H3 字段判断。derpmap 在本地身份未验证（未知）时退出 2，身份确认失败时退出 1。

## deploy.conf

只在显式传入 `--config FILE` 时读取，不自动搜索当前目录或加载 shell。配置读取本身不会安装、重启或建立调度。优先级为默认值/环境 → 配置文件 → CLI；健康检查中未指定的参数可从部署 unit 推断。

参考 [配置示例](../examples/deploy.conf.example)。先替换公网 IP/Region/用户等实际值，再安装：

```bash
sudo install -d -m 0755 /etc/derper
sudo install -o root -g root -m 0644 examples/deploy.conf.example /etc/derper/deploy.conf
sudo bash scripts/deploy_derper_ip_selfsigned.sh deploy --config /etc/derper/deploy.conf
bash scripts/deploy_derper_ip_selfsigned.sh status --config /etc/derper/deploy.conf --format json
```

格式为逐行 `KEY=value`，必须 `CONFIG_VERSION=1`；支持空行和整行 `#` 注释，不解释引号、变量、命令或行尾注释。未知/重复字段、控制字符/NUL、shell 语法和超过64KiB文件均拒绝。root 使用时文件须归 root 且组/其他用户不可写，符号链接拒绝。业务字段仍经过原 CLI 的校验，例如 RegionName 使用英文、数字、空格、连字符和下划线。

允许的字段：`CONFIG_VERSION`、`IP_ADDR`、`DERP_PORT`、`STUN_PORT`、`CERT_DAYS`、`CERT_LEAD_DAYS`、`DERPER_VERSION`、`REGION_ID`、`REGION_CODE`、`REGION_NAME`、`RUN_USER`、`VERIFY_CLIENTS_MODE`、`SECURITY_LEVEL`、`TLS_CONNLIMIT`、`ALLOW_NON_GLOBAL_IP`、`EXTERNAL_PROBE`、`PROBE_TIMEOUT`、`PROBE_MAX_AGE`、`REQUIRE_H3`、`METRICS_MAX_AGE`、`TS_TAILNET`、`POLICY_CREDENTIAL_FILE`。后两者只给维护任务保存 Tailnet 名称和凭据文件路径，不保存 client secret。

不接受 token/AuthKey/私钥等凭据，也不从配置发起 force、uninstall、轮换或安装调度。探针凭据由适配器在独立受保护位置管理。内网测试需显式 `ALLOW_NON_GLOBAL_IP=1`，公网环境使用0。

## 本地二进制导入

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh deploy \
  --ip YOUR_PUBLIC_IP --binary /root/artifacts/derper \
  --derper-version v1.104.1 --binary-sha256 TRUSTED_SHA256
```

目标版本必须固定，`latest` 拒绝。先复制到 root 受控候选目录，再校验64位小端 Linux ELF 的 amd64/arm64 架构、内嵌 tailscale.com 模块版本、所需帮助能力和可选预期摘要，最后复用 B 的快照、切换和回退。不直接执行原输入路径，不自动安装 Go；本机须已有 openssl/curl/od 等运行依赖。

默认 verify-clients 仍开启，候选还必须通过正在运行的 tailscaled daemon revision 门禁。无法确认时拒绝；某些版本映射需要 Go 模块元数据查询，本地导入不承诺默认鉴权模式下完全离线。关闭校验仅适用于隔离测试。

进程名仅用于定位候选。读取版本要求进程的 real/effective/saved/fs UID 均与部署调用者一致，可执行文件属于 root 或调用者，且无组/其他用户写权限或 setuid/setgid 位；固定文件描述符后才执行版本读取。root 部署不会执行普通用户的同名程序；自定义非 root tailscaled 无法满足该检查时转人工，不自动放宽权限。

回退恢复 unit 和专用节点状态目录中普通文件的内容及存在性，包含隐藏文件和空文件。遇到链接、子目录等不支持条目时拒绝继续清理，不递归删除；清理、摘要复核或 systemd 缓存刷新失败时保留恢复集和未完成标记。

首次安装中断没有上一版二进制可恢复：显式恢复会先停止服务并确认不再运行，再移除候选和标记。无法停止时两者保留，排除拒停原因后可再次执行 `recover`。

自行计算的 SHA256 只能描述所取文件，不能认证来源。预期摘要应通过可信独立渠道获取；操作者仍需信任本地产物。无法识别版本的自编译产物拒绝。正常 deploy 更新不重签有效证书。

## 状态、指标与结果

同一次核心采集供文本、JSON、指标和 derpmap 使用。JSON schema_version=1，包含 sampled_at、last_success_at、result/reason、needs_manual_attention、layers、目标参数、证书摘要、新鲜度及写入结果。缺失摘要/时间等为 null；last_success_at 为当前请求检查范围最近通过的时间，H3 未配置时不代表外部中继最近成功。

```bash
bash scripts/deploy_derper_ip_selfsigned.sh status --format json
bash scripts/deploy_derper_ip_selfsigned.sh derpmap --region-id 900
sudo bash scripts/deploy_derper_ip_selfsigned.sh health \
  --metrics-textfile /var/lib/node_exporter/textfile_collector/derper.prom \
  --state-file /var/lib/derper-deploy/health/status.json
bash scripts/deploy_derper_ip_selfsigned.sh status --format json \
  --metrics-source /var/lib/node_exporter/textfile_collector/derper.prom --metrics-max-age 900
```

普通 status 默认不写文件；指标输出和状态持久化由显式参数开启。写入使用同目录临时文件与替换，失败非零并保留旧内容。`--metrics-source` 只读检查旧指标的唯一 `derper_metrics_unixtime`，过期标 stale，无法读取/格式错/未来时间标 unknown；不能同时作为本次指标输出路径。

保留原指标；新增 `derper_h0_status`～`derper_h3_status`（1健康、0故障、-1未知、-2未检查、2不适用）、采样时间、旧指标年龄和最近成功时间。旧指标没有后台进程自行改写 stale 状态，监控端应比较当前时间与 derper_metrics_unixtime，或显式使用 --metrics-source。

原 `--install-healthcheck-cron` 继续作为安装入口，systemd 环境实际生成 timer/oneshot，显式 Bash 调用稳定副本，带默认状态文件 `/var/lib/derper-deploy/health/status.json`；已配置探针/Region/超时/内网许可也会随调度保存。不会在定时任务中自动重启或修复。

```bash
systemctl status derper-healthcheck.timer
journalctl -u derper-healthcheck.service
cat /var/lib/derper-deploy/health/status.json
```

`journal_storage` 只检查持久目录是否存在，目录存在不证明所有日志已落盘；持久化、磁盘容量和主机离线期间的通知能力须另行运维验证。当前没有站外通知。

## H0～H3 与发布门禁

| 层 | 范围 |
| --- | --- |
| H0 | 采集工具是否存在 |
| H1 | 服务、正确 PID 的 TCP/UDP 监听、证书对/有效期/SAN与在线指纹 |
| H2 | verify-clients 开启时的 tailscaled/LocalAPI 依赖（按 derper unit 的 `User=` 判断，不是调用者身份）；关闭时 not_applicable |
| H3 | 独立合法客户端对指定 Region/节点的真实 DERP 转发和 STUN 检查 |

没有探针时 H3=not_checked，基础0退出码只说明本地范围通过。`--require-h3` 让缺少 H3 的结果返回2，并阻断发布提交。显式配置探针后，其故障或未知也阻断提交。正常启动与门禁通过后才清除变更标记；失败恢复旧版本并复验，恢复失败保留材料。

探针达到超时时先发送 TERM，额外1秒后强制终止，并清理仍处于该进程组的子进程；适配器不得自行脱离进程组运行后台守护进程。缺少观测工具只允许对应能力降级，已确认的端口/PID故障仍阻断发布。

`--state-file` 和指标输出只接受普通文件目标；目标为目录或符号链接时失败。root输出路径的祖先必须归root所有、不可由组/其他用户写入且不能是链接；root所有的sticky目录（如`/tmp`）可以作为上层祖先，但最终输出目录必须受保护。使用root管理的独立结果目录，避免直接写`/tmp/status.json`或服务用户可写目录。状态输出、指标输出和指标输入不得重合，路径别名与现有硬链接也会被拒绝。

JSON新增`scope_id`，用于绑定目标IP/端口、Region、鉴权模式、H3要求、探针和指标新鲜度配置。`last_success_at`仅复用同一范围的成功历史；旧状态缺少该标识或范围改变时，历史值重置，当前检查成功后重新建立记录。

`--external-probe /绝对路径/适配器` 是自定义适配接口，不是内置 derpprobe 部署。适配器应调用位于独立已授权客户端上的真实协议检查，自己管理凭据，不能用固定成功或本地TLS代替。root 执行时适配器及全部父路径须归 root、不可由其他用户写入且无符号链接。

调用参数为 `--region-id N --ip IP --derp-port TCP --stun-port UDP`。stdout 必须仅输出以下白名单字段（以下只是报文示例，**不能当作探针实现**）：

```text
schema=1
region_id=900
ip=YOUR_PUBLIC_IP
derp_port=30399
stun_port=3478
checked_at=本次真实检查的Unix时间
derp=ok
stun=ok
```

DERP/STUN 值为 ok/failed；全通过退出0，确认失败且报告对应failed时退出1。目标、Region、端口必须匹配；重复/未知字段、错误格式、时间过期/明显超前、超时或其他退出码均为 unknown。默认超时15秒，范围1～120；默认最大年龄60秒；需要 timeout 工具，客户端时钟须同步。探针原始 stdout/stderr 不转储日志，避免凭据外泄。

当前隔离 VM 测试验证了协议解析、失败/未知门禁和回退；真实独立 Tailnet 客户端的 H3 验收、生产升级和控制面协调分别待实测，不从本地通过推断它们已完成。

可选的独立 Linux 客户端适配器为 `scripts/h3_probe.py`（Python3 标准库）。它使用现有 tailscaled LocalAPI 的合法节点身份，核对单节点 Region/地址/端口、下发指纹与服务证书、真实指定 Region 往返及 STUN 响应；无需读取私钥。直连、其他 Region、多节点歧义或传播未确认返回未知，适配器不会自动强制改路由。具体部署、可信 SSH wrapper 和真实 VM/GD/长效兼容步骤见[真实验收操作包](../tests/REAL_ACCEPTANCE.md)。本地适配器回归不代表真实 H3 已通过。

## 证书轮换与条件式自动维护

自动维护必须配置非空、非全空白的 `TS_TAILNET`，可由部署配置或独立凭据文件提供；未配置时不请求 OAuth 或策略 API，显式 `--enable-auto-maintain` 会报错且不安装 timer。有效目标会保存到定时配置。

`--lead-days` 或配置文件中的 `CERT_LEAD_DAYS` 都算显式设置，必须在最终证书有效期内，越界会拒绝。CLI 仍可覆盖配置文件中的提前天数或证书有效期；只有没有显式提供提前天数时，默认 30 天才会随短期证书自动收紧。

apply 会在更新云端指纹前检查安装根目录是否为符号链接，正式切换事务前再次检查；目录不安全时拒绝操作，保留原证书、私钥和候选。

维护状态文件单独保存 `scheduler_state`。安装或启用 timer 失败后，后续命令和维护重试仍保持未知，部署收尾返回非零；凭据恢复不会解除调度失败。修复调度条件后再次执行带 `--enable-auto-maintain` 的命令，成功安装并启用后才恢复 ready；也可用 `--disable-auto-maintain` 转回人工维护。旧版未保存独立调度字段的失败记录同样受保护。已成功安装的 timer 遇到临时授权未知时，仍保留启用意图，授权恢复后可继续维护。

`--yes` 不能代替换证确认。人工路径：

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh prepare --ip YOUR_PUBLIC_IP
sudo bash scripts/deploy_derper_ip_selfsigned.sh apply --ip YOUR_PUBLIC_IP --accept-cert-rotation
sudo bash scripts/deploy_derper_ip_selfsigned.sh cancel
```

prepare 只写入 `$DEPLOY_STATE_DIR/cert-rotation/` 的候选和片段，不切换正在运行的服务。改变 `--cert-days` 不会复用旧有效期的候选。apply 在确认后切换本地证书；目标 IP、Region、端口、证书有效期或已记录的 Tailnet 与 prepare 不一致，或候选已过期、剩余不足 1 小时时拒绝，须重新 prepare。成功切换后旧证书归档到 systemd unit 旁的 `.certs-archive`，只有未完成事务才会在下次命令自动恢复。服务原先在运行时，切换后要确认进程仍在运行且实际加载的指纹与新证书一致，否则恢复旧证书并不记为已应用。未配置云端写授权时，部署摘要会说明人工维护步骤，安装本身不失败。

自动模式下，本地切换失败后，只有确认磁盘旧证书与原运行服务的实际旧指纹都已恢复，才基于最新策略和 ETag 反向撤回本节点 CertName；原先停止的服务保持停止。若无法确认旧服务恢复，脚本保留云端指纹并记录 `unknown / needs_coordination / needs_manual=1`，定时入口也保留该原因，需人工协调。云端只有在策略可解析且确认没有本节点时才跳过补偿；重复 HostName、Region 不匹配、CertName 缺失或策略无法解析一律转人工，不把空值当成“无需补偿”。证书归档失败时同样先处理本地恢复，再决定云端补偿，不等到退出清理才恢复。

云端 secret 放在独立文件，不写入日志或 derper 环境。默认路径 `/etc/derper/policy-api.env`，root 所有、权限 0600，字段仅 `TS_TAILNET`、`TS_API_CLIENT_ID`、`TS_API_CLIENT_SECRET`、`TS_API_BASE`、`TS_API_TOKEN`、`POLICY_SOURCE`。维护配置可以记录该文件路径，但不记录 secret。`POLICY_SOURCE=gitops` 时脚本拒绝直接写云端，避免与仓库发布双写。GET 或 validate 成功不能证明可写。自动提交要求 GET 带回 ETag，并用 `If-Match` 提交；HTTP 412 或 validate 错误都不会切换本地证书。

显式 `--enable-auto-maintain` 且写授权齐全时，脚本把维护程序原子复制到部署状态目录，写出带节点、端口、有效期、提前天数、内网放行、运行用户、客户端校验和凭据路径的 `target.conf`，再 `daemon-reload` 并 `enable --now`。unit 与脚本副本拒绝符号链接。timer 执行的是部署状态目录里的脚本副本而不是原脚本；升级部署脚本后需再次执行带 `--enable-auto-maintain` 的命令刷新副本，否则定时任务会继续运行旧版脚本。timer 已启用且处于 active 之后，才把自动维护记为 ready。启用失败保持未知，不宣称已就绪。`--disable-auto-maintain` 才撤销登记并删除 timer；删除失败返回非零并记录 `scheduler_state=failed`。一次临时授权未知不会取消已启用意图。`cancel` 只丢弃候选，不要求公网 IP，也不打印部署向导。每天的 `maintain` 不重复打印安装说明，成功换证后也不重新登记调度或覆盖 `success_replaced`。普通卸载保留维护副本；`--purge-all` 才删除该副本和 `target.conf`。卸载 derper 时也会删除维护 unit 和证书归档；`daemon-reload` 失败，或 unit 文件、启用、运行状态残留时退出非零，不报告完成。每次执行会重验条件；确定未到期或条件不足不替换旧证书。无法计算到期时间时非零退出，记录原因并标记需人工，不写成 `idle`。已成功应用的候选不会在下一周期复用。失败只记本机 journal 和 `$(deploy_state_root)/maintenance/status`。当前没有站外通知。隔离 Tailnet 的真实策略写入与独立客户端复验仍待办。
