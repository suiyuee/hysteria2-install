# Hysteria 2 简洁部署

输入域名，一次完成官方核心下载、正式证书申请与自动续期、内置“松间”静态页、systemd 服务和 Clash 配置导出。

支持 Debian 11+ / Ubuntu 22.04+、x86_64 / ARM64、systemd，需要 root。核心来自 [Hysteria 官方发行版](https://github.com/HyNetworks/hysteria/releases)，下载时校验官方 SHA256。

## 一键部署

先把子域名的 A/AAAA 记录直接解析到服务器，关闭 CDN 代理；云防火墙放行 UDP 443 和 TCP 80，续期也需要 TCP 80。

在服务器执行（需要 `curl`）：

```bash
curl -fsSL https://raw.githubusercontent.com/suiyuee/hysteria2-install/main/dist/hysteria.sh -o hysteria.sh && sudo bash hysteria.sh
```

只询问域名。新安装默认 UDP 443、随机强密码、内置静态页，证书通知邮箱默认 `1094620146@qq.com`。无需安装 GitHub CLI 或登录 GitHub。

下载仓库后也可运行 `sudo bash install.sh`。只下载单文件时使用 `dist/hysteria.sh`，它不依赖仓库中的其他文件。

```bash
sudo bash install.sh --domain hy.example.com --non-interactive
```

## 重复部署与升级

- **重装系统或换服务器**：域名解析改到新 IP，重新运行部署命令。生成新密码和节点链接，重新申请证书；客户端需要更新。
- **原系统重复运行**：使用已安装核心，保留密码、端口、QUIC、混淆、伪装网页；域名不变时保留 ACME 设置和证书缓存。已有内置网页文件不覆盖。
- **升级核心**：单独执行 `upgrade`，配置、服务文件和客户端导出保持原样。

```bash
sudo bash install.sh upgrade
sudo bash install.sh upgrade --version v2.12.3
sudo bash install.sh reconfigure --domain hy.example.com --non-interactive
```

`install` 是默认操作，检测到已有配置会转为 `reconfigure`。`upgrade` 和 `reconfigure` 要求存在完整安装。修改域名或端口后，重新导入导出的节点；脚本不会更新第三方订阅平台。

## 参数与输出

| 参数 | 用途 |
| --- | --- |
| `--domain hy.example.com` | 连接域名 |
| `--email you@example.com` | 覆盖证书通知邮箱 |
| `--port 63992` | 指定 UDP 端口 |
| `--masquerade-url https://example.com` | 使用外部 HTTPS 伪装网页 |
| `--builtin-site` | 切换回内置静态页 |
| `--version v2.12.3` | 新安装或升级时固定版本，默认最新稳定版 |
| `--dns-wait 180` | DNS 等待秒数 |
| `--non-interactive` | 不提问，使用参数或已有配置 |
| `--dry-run` | 检查输入并显示计划，不下载、不签发、不修改系统 |

- `/etc/hysteria/client/clash.yaml`：Clash/Mihomo 配置，开启证书验证。
- `/etc/hysteria/client/hy2.txt`：节点链接，终端也会显示。
- `/etc/hysteria/config.yaml`：服务端配置，JSON 格式，兼容 YAML。
- `/var/lib/hysteria/acme`：证书缓存与续期状态。
- `/root/hy2-backup-*`：切换前文件和权限信息。

客户端文件含密码，权限为 `600`，不要提交到公开仓库。

## 检查与故障处理

先用临时 systemd 服务验证核心和证书，成功后切换正式服务。正式服务启动失败会恢复原文件的内容、属主、属组和权限，并恢复原服务运行状态。脚本不清空防火墙、不停止其他服务、不调整系统网络参数。

域名仍走 CDN、A/AAAA 指向其他地址、TCP 80 被占用或旧配置不受支持时会停止并提示。仅支持密码认证及无混淆或 salamander 的配置导出。NAT 端口映射需自行处理。

```bash
systemctl status hysteria-server
journalctl -u hysteria-server -n 60 --no-pager
```

伪装页通过 HY2 的 HTTP/3 提供，不额外占用 TCP 443。普通浏览器未必能打开。域名和伪装页不保证绕过 UDP 限制或提高速度。

## 开发

`src/installer.py` 为逻辑源码，`assets/` 存放网页和服务模板，`scripts/build.py` 生成唯一的自包含脚本 `dist/hysteria.sh`，`tests/` 存放测试。修改源码或模板后重新构建，不直接编辑生成文件。

```bash
python3 scripts/build.py
python3 scripts/build.py --check
bash -n install.sh dist/hysteria.sh
python3 -m unittest discover -s tests -v
bash install.sh --domain hy.example.com --non-interactive --dry-run
```

仅在可丢弃的 Linux/systemd 测试虚拟机中运行集成测试（需要 Python 3、openssl、curl、iproute2 和网络）：

```bash
sudo env HY2_DISPOSABLE_VM=yes python3 tests/linux_integration.py
```

该测试安装真实官方核心，验证 QUIC 代理、配置保留、升级隔离和失败回滚。使用本地测试证书预置缓存，不向公共 CA 申请证书，不能替代真实域名首次签发测试。

基于 [flame1ce/hysteria2-install](https://github.com/flame1ce/hysteria2-install) 改造。
