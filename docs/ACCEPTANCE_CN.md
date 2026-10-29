# 公网与中继验收指南

中文 | [English](ACCEPTANCE_EN.md)

本页是操作人员的正式验收入口。安装成功、公网协议可达、控制面下发和指定 Region 的实际中继是不同结论，不能用其中一项代替另一项。

## 1. 验收前准备

- 固定目标公网 IP、TCP/UDP 端口、Region、服务用户、derper 与 tailscaled 版本。
- 使用系统 OpenSSH 并核验主机密钥；不读取节点私钥，不在命令行或日志中保存 OAuth secret。
- 将本节点片段合并到最新策略，保留 `grants`、`ssh` 和其他 Regions。不要用单节点片段覆盖整份策略。
- 保持 `verify-clients` 开启。`debug derp` 使用临时随机身份，其失败不能替代合法客户端验收。

## 2. 核对本机与下发配置

```bash
systemctl is-active derper
systemctl show derper -p MainPID -p NRestarts -p User
tailscale debug derp-map
```

确认实际进程监听目标端口，Region 只有一个被验节点，HostName/显式 IP、DERPPort、STUNPort 和 CertName 与目标一致。`netcheck` 只证明区域探测，不证明节点间中继。

## 3. 公网 TLS 与 STUN

从服务器外部网络完成以下检查：

- TLS：读取在线 DER 证书并核对 SHA256，必须与控制面 `sha256-raw:` 指纹和磁盘证书一致。
- STUN：发送带 `tailnode` SOFTWARE 与 FINGERPRINT 的 Binding 请求，验证响应类型、事务 ID、长度和映射地址。

`nc -zvu` 可能产生假阳性，不能作为 STUN 通过条件。探针实现见 `scripts/h3_probe.py` 与[维护手册](MAINTENANCE_CN.md)。

## 4. 指定 Region 合法客户端往返

在独立、已授权的 Linux 客户端上，以另一个合法节点为对端运行：

```bash
sudo python3 /opt/derper-probe/h3_probe.py \
  --region-id 901 --ip 114.67.236.43 \
  --derp-port 30399 --stun-port 3478 \
  --peer-ip 100.107.224.117 --timeout 10
```

替换示例中的 Region、地址、端口和对端。成功必须同时满足：控制面目标与证书指纹匹配、真实 disco 往返的 DERPRegionID 等于目标 Region、对端正确、STUN 有效。输出为8行协议且退出0才通过。

普通 `tailscale ping` 显示 `via DERP(<目标Region>)` 也可作为实际中继往返证据；`direct connection not established` 只表示没有建立 P2P 直连，不否定已经发生的 DERP pong。直连、其他 Region、peer relay、多节点歧义或证书未传播均记为未验，不能强行宣布目标 DERP 故障。

不要为了制造成功结果而全局封 UDP、强制路由或关闭 `verify-clients`。确需受控网络条件时，应限定在可恢复测试资源并记录变更和还原。

## 5. 健康调度验收

安装健康检查后，同时验证：

1. timer 为 enabled/active，且没有 cron 与 timer 重复调度。
2. 手动 oneshot 为 `Result=success`、`ExecMainStatus=0`。
3. 再等待一次自然触发，确认成功结果和状态文件时间戳刷新。
4. 状态文件中的配置文件路径、IP、端口和 Region 与统一目标一致。
5. derper MainPID、证书及自动维护状态没有非预期变化。

使用配置文件时，调度读取 root 管理的稳定副本；编辑该副本即可改变后续检查目标，不需要重复传 IP、端口或 Region 参数。移动原始配置文件不会删除这个稳定副本。

## 6. 保存证据与边界

记录执行时间、目标、脚本与二进制摘要、实际命令、退出码、证书指纹、journal、状态文件时间和合法客户端输出。云 API 写入、换证传播、故障注入、跨平台适配器和长效证书兼容必须分别验收，不能由一次安装或本页单项检查推断完成。
