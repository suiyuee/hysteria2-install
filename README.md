# HY2

自用 Bash 脚本，适配 Debian 13.x / systemd，需要 root。无需 Python；缺少的 `curl`、`jq`、证书包和 `iproute2` 会自动安装。

## 部署

客户端通过 IPv4 接入：域名 A 记录直接解析到服务器，删除 AAAA 记录，关闭 CDN；默认放行 UDP 443 和 TCP 80（证书申请及续期）；启用 IPv6 优先节点时再放行 UDP 444。

```bash
curl -fsSL https://raw.githubusercontent.com/suiyuee/hysteria2-install/main/hysteria.sh | sudo bash -s -- --domain hy.suiyuee.top
```

将命令中的域名换成自己的。DNS 未就绪时每 5 秒重试，生效后自动继续；可用 Ctrl+C 取消，或加 `--dns-wait 180` 限时等待。默认最新官方核心、随机密码、内置“松间”网页。每个域名都导出 IPv4 节点（默认 UDP 443）。脚本检查公网 IPv6 路由，并通过 IPv6 直连 Cloudflare 或 Google 的 HTTPS 服务。任一探测成功，才为每个域名额外导出 IPv6 优先节点。没有公网 IPv6 路由时只部署 IPv4；有路由但 HTTPS 探测失败时，只保留所选域名已有的 IPv6 节点。带 `(IPv6)` 的节点优先走 IPv6（默认 UDP 444），目标域名只有 A 记录时自动走 IPv4。服务器需要能通过 IPv6 出网，客户端只需能通过 IPv4 连服务器。IPv6 优先按目标域名解析结果选路，已有 AAAA 但 IPv6 线路故障时不会重试 IPv4。客户端直接提交 IP 时按该 IP 连接。证书邮箱默认不填。

完成后导入 `/etc/hysteria/client/clash.yaml`，或复制 `/etc/hysteria/client/hy2.txt` 中的链接。

### 一台服务器多个 IPv4

每个 IPv4 配一个域名，A 记录各指向一个 IP（一个域名只能有一条 A 记录，不能共用 IP），提示时用空格分隔填写全部域名，或：

```bash
sudo bash hysteria.sh --domain hy7.example.com --domain hy8.example.com --domain hy9.example.com
```

每个域名的 IPv4 节点：监听、证书验证和直连出口都绑定它的 IP。第一个域名沿用 `hysteria-server` 和 `/etc/hysteria/config.yaml`，其余为 `hysteria-server@域名` 和 `/etc/hysteria/nodes/域名.yaml`；对应的 IPv6 优先实例为 `hysteria-server@_v6-域名`，回落 IPv4 时也使用该域名绑定的 IP。部署前逐个用该 IP 访问外网，出口不是它自己时停止部署（附加 IP 需已配置在网卡上，必要时先配置策略路由）。重新配置时列表里去掉的附加节点会被停用并删除配置，所以 `reconfigure --domain` 要写全所有域名；不带 `--domain` 时默认沿用现有全部节点。`upgrade` 重启全部节点。

## 常用操作

使用管道部署时，把操作和参数接在 `bash -s --` 后面即可。已下载脚本也可以执行：

```bash
sudo bash hysteria.sh upgrade                         # 升级核心
sudo bash hysteria.sh reconfigure --port 63992 --v6-port 63993  # 分别指定并放行两个 UDP 端口
sudo bash hysteria.sh reconfigure --domain hy.example.com  # 改域名
sudo bash hysteria.sh --help                          # 所有参数
```

服务器开通 IPv6 后，执行 `reconfigure` 重新检测并生成第二条链接，两个节点共用原域名、证书和密码。IPv6 优先节点默认使用主端口加一（主端口为 65535 时取 65534）；只重配其他设置时保留已有端口。`upgrade` 只升级核心。重装或换服务器后，改好域名解析再重新部署，客户端导入新节点；改域名或端口后也需更新客户端。

## 排错

```bash
systemctl status hysteria-server
journalctl -u hysteria-server -n 60 --no-pager
```

服务端配置：`/etc/hysteria/config.yaml`；附加节点在 `/etc/hysteria/nodes/`，日志用 `journalctl -u hysteria-server@域名`。

## 改代码

直接修改 `hysteria.sh`，检查：`bash tests/check.sh`。

完整测试：在可丢弃的 Linux 测试虚拟机或 CI 中运行 `bash tests/check.sh --container`（需要 Docker）。

核心：[Hysteria](https://github.com/HyNetworks/hysteria) · 原项目：[flame1ce/hysteria2-install](https://github.com/flame1ce/hysteria2-install)
