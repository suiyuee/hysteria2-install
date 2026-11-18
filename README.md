# HY2

个人自用的 Hysteria2 配置与维护脚本，按个人服务器环境编写。

仅作个人备份与维护，不提供通用部署教程、兼容性保证或使用支持。

## 自用速查

Debian 13.x / systemd，在服务器 root 终端、脚本所在目录执行。域名 A 记录直指服务器，关闭 CDN、删除 AAAA；放行 TCP 80、UDP 443，使用 IPv6 优先节点时另放行 UDP 444。

```bash
bash hysteria.sh --domain hy.example.com  # 首次部署，替换为自己的域名
bash hysteria.sh upgrade                 # 升级核心
bash hysteria.sh reconfigure             # 沿用现有配置，不做外部检测
bash hysteria.sh reconfigure --port 63992 --v6-port 63993  # 改端口，需同步放行
bash hysteria.sh reconfigure --check-connectivity  # 按需检测 IPv6 和多 IP 出口
bash hysteria.sh --help                  # 查看全部参数
```

不查询节点地区，名称默认取域名第一段，可在客户端手动改名。外部连通性检测默认关闭：只检查本机 IPv6 路由，保留有路由的已有 IPv6 节点，不自动新增；确认需要时使用 `--check-connectivity`。多 IPv4 的实际出网地址也仅在开启该选项时验证。下载核心、证书申请等必要外联仍会发生。

多个域名重复传入 `--domain`；重新配置时若指定域名，需写全要保留的域名，否则会删除被省略的附加节点。

客户端配置：`/etc/hysteria/client/clash.yaml`；节点链接：`/etc/hysteria/client/hy2.txt`。改域名或端口后更新客户端。

```bash
systemctl status hysteria-server
journalctl -u hysteria-server -n 60 --no-pager
```

核心：[Hysteria](https://github.com/HyNetworks/hysteria) · 原项目：[flame1ce/hysteria2-install](https://github.com/flame1ce/hysteria2-install)

后台部署和订阅同步见 [服务器管理](worker/README.md)。
