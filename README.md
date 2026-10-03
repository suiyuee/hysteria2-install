# HY2

自用 Bash 脚本，适配 Debian 13.x / systemd，需要 root。无需 Python；缺少的 `curl`、`jq`、证书包和 `iproute2` 会自动安装。

## 部署

域名直接解析到服务器，关闭 CDN；放行 UDP 443、TCP 80（证书申请及续期）。

```bash
curl -fsSL https://raw.githubusercontent.com/suiyuee/hysteria2-install/main/dist/hysteria.sh -o hysteria.sh && sudo bash hysteria.sh
```

只填域名。默认最新官方核心、UDP 443、随机密码、内置“松间”网页，证书邮箱 `1094620146@qq.com`。

完成后导入 `/etc/hysteria/client/clash.yaml`，或复制 `/etc/hysteria/client/hy2.txt` 中的链接。

## 常用操作

在下载脚本的目录执行：

```bash
sudo bash hysteria.sh upgrade                         # 升级核心
sudo bash hysteria.sh reconfigure --port 63992         # 改端口，同时放行对应 UDP 端口
sudo bash hysteria.sh reconfigure --domain hy.example.com  # 改域名
sudo bash hysteria.sh --help                          # 所有参数
```

原系统重复执行保留配置。重装或换服务器后，改好域名解析再重新部署，客户端导入新节点；改域名或端口后也需更新客户端。

## 排错

```bash
systemctl status hysteria-server
journalctl -u hysteria-server -n 60 --no-pager
```

服务端配置：`/etc/hysteria/config.yaml`。

## 改代码

修改 `src/` 或 `assets/` 后执行，生成的 `dist/hysteria.sh` 不直接编辑：

```bash
bash scripts/build.sh
bash tests/test.sh
```

完整测试：在可丢弃的 Linux 测试虚拟机或 CI 中运行 `bash tests/run-linux.sh`（需要 Docker）。测试容器使用本地证书，不申请公共证书。

核心：[Hysteria](https://github.com/HyNetworks/hysteria) · 原项目：[flame1ce/hysteria2-install](https://github.com/flame1ce/hysteria2-install)
