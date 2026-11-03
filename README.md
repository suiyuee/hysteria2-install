# HY2

自用 Bash 脚本，适配 Debian 13.x / systemd，需要 root。无需 Python；缺少的 `curl`、`jq`、证书包和 `iproute2` 会自动安装。

## 部署

仅使用 IPv4：域名 A 记录直接解析到服务器，删除 AAAA 记录，关闭 CDN；放行 UDP 443、TCP 80（证书申请及续期）。

```bash
curl -fsSL https://raw.githubusercontent.com/suiyuee/hysteria2-install/main/hysteria.sh -o hysteria.sh && sudo bash hysteria.sh
```

只填域名。默认最新官方核心、IPv4 UDP 443、随机密码、内置“松间”网页。服务端直连出口固定 IPv4，导出的 Clash 配置关闭 IPv6，节点名只用域名。证书邮箱默认不填。

完成后导入 `/etc/hysteria/client/clash.yaml`，或复制 `/etc/hysteria/client/hy2.txt` 中的链接。

### 一台服务器多个 IPv4

每个 IPv4 配一个域名，A 记录各指向一个 IP（一个域名只能有一条 A 记录，不能共用 IP），提示时用空格分隔填写全部域名，或：

```bash
sudo bash hysteria.sh --domain hy7.example.com --domain hy8.example.com --domain hy9.example.com
```

每个域名一个节点：监听、证书验证和直连出口都绑定它的 IP。第一个域名沿用 `hysteria-server` 和 `/etc/hysteria/config.yaml`，其余为 `hysteria-server@域名` 和 `/etc/hysteria/nodes/域名.yaml`；导出文件包含全部节点。部署前逐个用该 IP 访问外网，出口不是它自己时停止部署（附加 IP 需已配置在网卡上，必要时先配置策略路由）。重新配置时列表里去掉的附加节点会被停用并删除配置，所以 `reconfigure --domain` 要写全所有域名；不带 `--domain` 时默认沿用现有全部节点。`upgrade` 重启全部节点。

## 常用操作

在下载脚本的目录执行：

```bash
sudo bash hysteria.sh upgrade                         # 升级核心
sudo bash hysteria.sh reconfigure --port 63992         # 改端口，同时放行对应 UDP 端口
sudo bash hysteria.sh reconfigure --domain hy.example.com  # 改域名
sudo bash hysteria.sh --help                          # 所有参数
```

原系统重复执行保留每个节点的密码、证书和自定义设置，同时将 HY2 监听及直连出口改为 IPv4；不会修改系统 IPv6 开关或其它服务。`upgrade` 只升级核心，已有配置切换 IPv4 请运行 `reconfigure`。重装或换服务器后，改好域名解析再重新部署，客户端导入新节点；改域名或端口后也需更新客户端。

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
