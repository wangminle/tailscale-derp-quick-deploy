# Agent 安装准备约定

中文 | [English](AGENT_INSTALL_EN.md)

先按[安装业务闭环](INSTALL_WORKFLOW_CN.md)明确目标。普通用户预检和构建可以先完成；需要sudo且无法非交互执行时，准备好可审阅入口后由用户在自己的终端验证身份一次。不索要聊天中的密码、私钥或OAuth secret，不为方便安装设置全局免密sudo。

管理连接使用系统OpenSSH客户端与服务器sshd，可经Tailnet的100.x地址传输；不使用独立的Tailscale SSH功能，不调用`tailscale ssh`，不为部署添加`tailscale up/set --ssh`。只读检查`tailscale debug prefs`中的RunSSH即可区分服务端功能是否开启；不要将完整prefs写入日志。发现已有RunSSH=true时先说明该既有配置，不擅自关闭以免影响其他用户的管理通道。

## Go 工具链与摘要

从`https://go.dev/dl/?mode=json&include=all`读取官方元数据，按明确版本、系统和架构精确选择唯一archive，使用其中的filename、size和sha256。不要假设`goVERSION.OS-ARCH.tar.gz.sha256`是有效摘要端点；它可能返回HTML。

推荐顺序：

1. 固定所需Go版本，下载官方JSON并保留原件；校验条目唯一、文件名无路径分隔符、SHA256为64位十六进制。
2. 从`https://go.dev/dl/`下载该filename；连接与总时限有界。失败保留日志，不把部分文件当作完成。
3. 核对文件大小及SHA256，成功后才解包、执行；预下载文件也必须校验。
4. 若服务器访问官方下载元数据失败，可在可信本机经HTTPS读取并传送已核验摘要/包，记录来源。不要改用未知镜像或关闭完整性校验。
5. 构建固定的derper模块版本，保留GOPROXY/GOSUMDB与构建信息；实际执行commit到模块版本的解析。版本显示`ERR-BuildInfo`时结合`go version -m`核对模块来源，不靠显示字符串猜测同源。

本仓库的产品脚本已有Go fallback包的固定摘要校验；本节约束Agent另行预构建工具链的流程，不改变产品的来源校验要求。

## 所有命令共用同一目标

以`examples/deploy.conf.example`为模板，在明确位置保存无秘密的配置。它是白名单数据文件，不是shell脚本；不要`source`，也不要把token填入其中。固定Region、名称、IP、TCP/UDP、RUN_USER、VERIFY_CLIENTS_MODE、版本和安全级别后，每条命令都带同一个`--config`。

```bash
# target.conf已按真实资源填写，保存路径以本次操作记录为准。
target=/root/derper-install/target.conf
script=/root/derper-install/repo/scripts/deploy_derper_ip_selfsigned.sh
common=(--config "$target")
bash "$script" check "${common[@]}"
# 二进制来源/摘要需先核验，root复制到私有目录后再次校验。
bash "$script" deploy "${common[@]}" --binary /root/derper-install/derper \
  --binary-sha256 EXPECTED_SHA256 --non-interactive
bash "$script" status "${common[@]}" --format json
bash "$script" derpmap "${common[@]}"
```

也可以在单次辅助入口使用同一个Bash参数数组，但必须覆盖完整目标；不能部署时传Region名称、查询时遗漏而展示默认my-derp。GOPROXY/GOSUMDB不在配置白名单时另加到构建/导入所需的命令环境；不关闭GOSUMDB。

每次使用固定源码包与摘要，不从用户可写路径直接执行未经确认的root程序；在root私有目录校验后再解包和运行。不要重新执行只允许首次安装的入口来做日常状态检查。新辅助入口和报告不能覆盖历史原始证据。

## 完成与后续动作

安装输出以最终目标摘要为准；上游示例Region900不覆盖实际参数。将节点片段合并到最新策略，保留其他规则与Regions，核对下发后再测试。把公网TLS/STUN与合法客户端H3分别记录。没有H3或自动维护授权时，如实交接未验范围和人工维护责任，不制造成功报告，也不擅自改变现网网络条件。

自动换证的管理员操作见[授权与安装指南](AUTO_MAINTENANCE_CN.md)。Agent不能把本机登录、获取令牌或维护状态ready写成云端换证全部通过；必须区分后台授权、服务器启用、首次真实轮换和客户端传播四项证据。
