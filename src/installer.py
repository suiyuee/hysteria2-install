import argparse
import copy
import stat
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

CONFIG = Path('/etc/hysteria/config.yaml')
BINARY = Path('/usr/local/bin/hysteria')
UNIT = Path('/etc/systemd/system/hysteria-server.service')
HOME = Path('/var/lib/hysteria')
EXPORT = Path('/etc/hysteria/client')
API = 'https://api.github.com/repos/HyNetworks/hysteria/releases'
DEFAULT_EMAIL = '1094620146@qq.com'
SITE = (Path(__file__).resolve().parents[1] / 'assets/index.html').read_text()
SERVICE = (Path(__file__).resolve().parents[1] / 'assets/hysteria-server.service').read_text()


def run(*args, check=True):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=check)


def prompt(label, default=''):
    try:
        with open('/dev/tty', 'r+') as tty:
            tty.write(label + (f' [{default}]' if default else '') + ': ')
            tty.flush()
            value = tty.readline().strip()
            return value or default
    except OSError:
        raise ValueError('没有交互终端，请指定 --domain 和 --non-interactive。')


def domain_name(value):
    value = value.strip().lower().rstrip('.')
    if len(value) > 253 or '.' not in value or any(
        not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', part)
        for part in value.split('.')
    ):
        raise ValueError('域名格式不正确，请只填域名，不要带 https://、端口或路径。')
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return value
    raise ValueError('需要域名，不能填写 IP。')


def load_config(path):
    if not path.exists():
        return {}
    text = path.read_text()
    try:
        data = json.loads(text)
    except ValueError:
        try:
            import yaml
        except ImportError:
            raise ValueError('读取旧 YAML 配置需要 python3-yaml，请先安装此系统软件包。')
        data = yaml.safe_load(text)
    if not isinstance(data, dict):
        raise ValueError('旧配置不是有效的对象，已停止以避免覆盖。')
    return data


def choose_settings(args, old):
    acme = old.get('acme', {})
    domains = acme.get('domains', [])
    domain = args.domain or (domains[0] if domains else '')
    email = args.email or DEFAULT_EMAIL
    if not args.non_interactive:
        if not args.domain:
            domain = prompt('连接域名（须直接解析到本机）', domain)
    domain = domain_name(domain)
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email):
        raise ValueError('请填写有效的证书通知邮箱。')
    listen = str(old.get('listen', ':443'))
    if not re.search(r':\d+$', listen):
        raise ValueError('现有配置使用端口范围或特殊监听方式，请先手动整理后再运行。')
    port = args.port if args.port is not None else int(listen.rsplit(':', 1)[-1])
    if not 1 <= port <= 65535:
        raise ValueError('端口必须在 1–65535 之间。')
    auth = old.get('auth', {})
    if old and (auth.get('type') != 'password' or not isinstance(auth.get('password'), str)):
        raise ValueError('旧服务不是密码认证，不能自动修改配置。')
    password = auth.get('password') or secrets.token_urlsafe(32)
    # Preserve unrelated server settings, including obfuscation and QUIC tuning.
    config = copy.deepcopy(old)
    config.pop('tls', None)
    config.update(listen=listen.rsplit(':', 1)[0] + f':{port}', auth={'type': 'password', 'password': password})
    if acme and domains == [domain]:
        config['acme'] = copy.deepcopy(acme)
        if args.email:
            config['acme']['email'] = email
    else:
        config['acme'] = {'domains': [domain], 'email': email, 'ca': 'letsencrypt',
                          'type': 'http', 'dir': str(HOME / 'acme')}
    if args.masquerade_url:
        url = urllib.parse.urlsplit(args.masquerade_url)
        if url.scheme != 'https' or not url.hostname or url.username or url.password:
            raise ValueError('伪装网站必须是完整 HTTPS 地址，且不能包含用户名或密码。')
        config['masquerade'] = {'type': 'proxy', 'proxy': {'url': args.masquerade_url, 'rewriteHost': True}}
    elif args.builtin_site or not old.get('masquerade'):
        config['masquerade'] = {'type': 'file', 'file': {'dir': str(HOME / 'www')}}
    obfs = config.get('obfs', {})
    if obfs and obfs.get('type') != 'salamander':
        raise ValueError('当前脚本的 Clash 导出只支持无混淆或 salamander，已停止。')
    return config


def client_files(config):
    domain = config['acme']['domains'][0]
    port = int(config['listen'].rsplit(':', 1)[-1])
    password = config['auth']['password']
    node = {'name': domain, 'type': 'hysteria2', 'server': domain, 'port': port,
            'password': password, 'sni': domain, 'skip-cert-verify': False}
    query = {'sni': domain, 'insecure': '0'}
    if config.get('obfs'):
        password_obfs = config['obfs']['salamander']['password']
        node.update({'obfs': 'salamander', 'obfs-password': password_obfs})
        query.update({'obfs': 'salamander', 'obfs-password': password_obfs})
    uri = ('hysteria2://' + urllib.parse.quote(password, safe='') + f'@{domain}:{port}/?'
           + urllib.parse.urlencode(query) + '#' + urllib.parse.quote(domain, safe=''))
    profile = {'mixed-port': 7890, 'allow-lan': False, 'mode': 'rule',
               'proxies': [node], 'proxy-groups': [{'name': '代理选择', 'type': 'select',
               'proxies': [domain, 'DIRECT']}], 'rules': [
               'IP-CIDR,127.0.0.0/8,DIRECT', 'IP-CIDR,10.0.0.0/8,DIRECT',
               'IP-CIDR,172.16.0.0/12,DIRECT', 'IP-CIDR,192.168.0.0/16,DIRECT',
               'MATCH,代理选择']}
    # JSON is valid YAML and avoids shell/YAML injection through credentials.
    return {'clash.yaml': json.dumps(profile, ensure_ascii=False, indent=2) + '\n',
            'hy2.txt': uri + '\n'}


def write_atomic(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.hy2-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(data)
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def dns_check(domain, timeout):
    local = {a['local'] for interface in json.loads(run('ip', '-j', 'addr').stdout)
             for a in interface.get('addr_info', []) if a.get('scope') == 'global'}
    until = time.monotonic() + timeout
    while True:
        try:
            resolved = {x[4][0] for x in socket.getaddrinfo(domain, None, type=socket.SOCK_STREAM)}
        except socket.gaierror:
            resolved = set()
        if resolved and resolved <= local:
            return
        if time.monotonic() >= until:
            raise ValueError(f'DNS 未就绪：{domain} 解析为 {sorted(resolved)}，本机地址 {sorted(local)}。请关闭 CDN，并检查所有 A/AAAA 记录。')
        print('等待 DNS 生效……', flush=True)
        time.sleep(10)


def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'hy2-simple-installer'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def download_binary(destination, version):
    arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(platform.machine())
    if not arch:
        raise ValueError('仅支持 x86_64 和 aarch64。')
    endpoint = '/latest' if not version else '/tags/' + urllib.parse.quote('app/' + version.removeprefix('app/'), safe='')
    release = json.loads(fetch(API + endpoint))
    asset = next((a for a in release['assets'] if a['name'] == f'hysteria-linux-{arch}'), None)
    digest = (asset or {}).get('digest', '') or ''
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        raise ValueError('官方发行包缺少 SHA256 校验信息，已停止下载。')
    url = asset['browser_download_url']
    if urllib.parse.urlsplit(url).hostname != 'github.com':
        raise ValueError('发行包下载地址不属于 GitHub。')
    data = fetch(url)
    if hashlib.sha256(data).hexdigest() != digest.split(':')[1]:
        raise ValueError('官方程序 SHA256 校验失败。')
    destination.write_bytes(data)
    destination.chmod(0o755)
    return release['tag_name']


def port_free(protocol, port):
    lines = run('ss', '-H', '-l' + protocol + 'n', f'sport = :{port}').stdout
    return not lines.strip()


def wait_ready(unit, seconds):
    deadline = time.monotonic() + seconds
    stable = 0
    while time.monotonic() < deadline:
        status = run('systemctl', 'show', unit, '-p', 'ActiveState', '-p', 'MainPID',
                     '-p', 'NRestarts', check=False).stdout
        fields = dict(line.split('=', 1) for line in status.splitlines() if '=' in line)
        if fields.get('ActiveState') in ('failed', 'inactive') or int(fields.get('NRestarts', 0)):
            break
        pid = fields.get('MainPID', '0')
        sockets = run('ss', '-H', '-lunp', check=False).stdout
        if pid != '0' and f'pid={pid},' in sockets:
            stable += 1
            if stable >= 3:
                return
        else:
            stable = 0
        time.sleep(1)
    raise RuntimeError('服务未就绪或证书签发失败。请查看 journalctl -u ' + unit + '；DNS 缓存可能尚未更新，稍后重跑即可。')


def deploy_files(files, backup):
    was_active = run('systemctl', 'is-active', 'hysteria-server', check=False).stdout.strip() == 'active'
    enabled = run('systemctl', 'is-enabled', 'hysteria-server', check=False).stdout.strip()
    metadata = {}
    existed = {}
    for index, (path, content, mode) in enumerate(files):
        existed[path] = path.exists()
        if path.is_symlink():
            raise ValueError(f'暂不自动替换符号链接：{path}')
        if path.exists():
            st = path.stat()
            metadata[path] = {'uid': st.st_uid, 'gid': st.st_gid, 'mode': stat.S_IMODE(st.st_mode)}
            shutil.copy2(path, backup / str(index))
    write_atomic(backup / 'manifest.json', json.dumps({'active': was_active, 'enabled': enabled,
        'files': [{'path': str(p), 'backup': str(i), 'existed': existed[p],
                   **metadata.get(p, {})} for i, (p, _, _) in enumerate(files)]}, indent=2))
    try:
        for path, content, mode in files:
            if isinstance(content, Path):
                path.parent.mkdir(parents=True, exist_ok=True)
                target = path.with_name(path.name + '.hy2-new')
                shutil.copyfile(content, target)
                target.chmod(mode)
                os.replace(target, path)
            else:
                write_atomic(path, content, mode)
        if any(path == CONFIG for path, _, _ in files):
            run('chown', 'root:hysteria', str(CONFIG))
        run('systemctl', 'daemon-reload')
        run('systemctl', 'reset-failed', 'hysteria-server', check=False)
        run('systemctl', 'restart', 'hysteria-server')
        wait_ready('hysteria-server', 30)
        if not existed.get(UNIT, UNIT.exists()):
            run('systemctl', 'enable', 'hysteria-server')
    except BaseException:
        for index, (path, _, _) in enumerate(files):
            if existed[path]:
                restored = path.with_name(path.name + '.hy2-restore')
                shutil.copy2(backup / str(index), restored)
                os.chown(restored, metadata[path]['uid'], metadata[path]['gid'])
                os.chmod(restored, metadata[path]['mode'])
                os.replace(restored, path)
            else:
                path.unlink(missing_ok=True)
        run('systemctl', 'daemon-reload', check=False)
        if UNIT.exists() and was_active:
            run('systemctl', 'reset-failed', 'hysteria-server', check=False)
            run('systemctl', 'restart', 'hysteria-server', check=False)
            try:
                wait_ready('hysteria-server', 30)
            except RuntimeError as exc:
                raise RuntimeError(f'已恢复文件，但原服务未恢复运行。备份：{backup}') from exc
        else:
            run('systemctl', 'stop', 'hysteria-server', check=False)
            if not existed.get(UNIT, UNIT.exists()):
                run('systemctl', 'disable', 'hysteria-server', check=False)
        if was_active and run('systemctl', 'is-active', 'hysteria-server', check=False).stdout.strip() != 'active':
            raise RuntimeError(f'已恢复文件，但原服务未恢复运行，请检查日志。备份：{backup}')
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description='HY2 简洁部署：正式证书、自动续期、内置网页和 Clash 配置。')
    parser.add_argument('action', nargs='?', choices=['install', 'upgrade', 'reconfigure'], default='install')
    parser.add_argument('--builtin-site', action='store_true', help='明确切换为内置静态页')
    parser.add_argument('--domain', help='已直接解析到此 VPS 的域名')
    parser.add_argument('--email', help='证书通知邮箱，默认 ' + DEFAULT_EMAIL)
    parser.add_argument('--port', type=int, help='默认保留现有端口，新安装为 443')
    parser.add_argument('--masquerade-url', help='可选：使用 HTTPS 网站代替内置静态页')
    parser.add_argument('--version', help='可选：固定官方版本，如 v2.12.3；默认最新稳定版')
    parser.add_argument('--non-interactive', action='store_true', help='使用参数和已有配置，不提问')
    parser.add_argument('--dry-run', action='store_true', help='只检查输入并显示计划，不下载或改动系统')
    parser.add_argument('--dns-wait', type=int, default=180, help='等待 DNS 秒数，默认 180')
    args = parser.parse_args(argv)
    if args.builtin_site and args.masquerade_url:
        parser.error('--builtin-site 和 --masquerade-url 不能同时使用')
    if args.action == 'upgrade' and any([args.domain, args.email, args.port is not None, args.builtin_site, args.masquerade_url]):
        parser.error('upgrade 只升级核心；修改配置请使用 reconfigure')
    if args.action == 'reconfigure' and args.version:
        parser.error('reconfigure 不升级核心；指定版本请使用 upgrade')
    if sys.version_info < (3, 9):
        raise ValueError('需要 Python 3.9 或更高版本。')
    if args.dns_wait < 0:
        parser.error('--dns-wait 不能为负数')
    if not args.dry_run:
        if platform.system() != 'Linux' or os.geteuid() != 0:
            raise ValueError('请在 Debian/Ubuntu 服务器上使用 root 运行。')
        os_release = Path('/etc/os-release').read_text()
        if not re.search(r'^ID=(?:"?)(debian|ubuntu)(?:"?)$', os_release, re.M):
            raise ValueError('本简洁版本支持 Debian/Ubuntu。')
        if not Path('/run/systemd/system').exists():
            raise ValueError('需要使用 systemd 的服务器。')
        lock = open('/run/hy2-install.lock', 'w')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('已有安装进程正在运行，请等待完成。')
        needed = [] if shutil.which('ss') and shutil.which('ip') else ['iproute2']
        if run('dpkg-query', '-W', '-f=${Status}', 'ca-certificates', check=False).stdout.strip() != 'install ok installed':
            needed.append('ca-certificates')
        if CONFIG.exists():
            try:
                import yaml
            except ImportError:
                needed.append('python3-yaml')
        if needed:
            print('安装必要依赖：' + ', '.join(needed), flush=True)
            run('apt-get', 'update')
            run('apt-get', 'install', '-y', *needed, 'ca-certificates')
    old = load_config(CONFIG)
    action = args.action
    if old and action == 'install':
        action = 'reconfigure'
        if args.version:
            raise ValueError('已有安装，请使用 upgrade --version 指定升级版本。')
    if action != 'install' and (not old or not BINARY.exists() or not UNIT.exists()):
        raise ValueError('未找到完整的现有安装，请先运行 install。')
    config = copy.deepcopy(old) if action == 'upgrade' else choose_settings(args, old)
    print(f'操作：{action}；监听：{config.get("listen", ":443")}；' + ('保留已有配置。' if action == 'upgrade' else '证书自动续期。'), flush=True)
    if args.dry_run:
        print('检查通过。未下载程序、申请证书或修改配置。')
        return
    if action != 'upgrade':
        domain = config['acme']['domains'][0]
        dns_check(domain, args.dns_wait)
        if config['acme'].get('type', 'http') == 'http' and not port_free('t', 80):
            raise ValueError('TCP 80 已占用，HTTP 证书验证无法启动。请先处理占用，不会自动停止其他服务。')
        port = int(config['listen'].rsplit(':', 1)[-1])
        if not port_free('u', port):
            old_port = str(old.get('listen', '')).rsplit(':', 1)[-1]
            if old_port != str(port) or run('systemctl', 'is-active', 'hysteria-server', check=False).stdout.strip() != 'active':
                raise ValueError(f'UDP {port} 已被其他服务占用。')
    if run('id', 'hysteria', check=False).returncode:
        run('useradd', '--system', '--user-group', '--home-dir', str(HOME), '--shell', '/usr/sbin/nologin', 'hysteria')
    run('install', '-d', '-o', 'hysteria', '-g', 'hysteria', '-m', '700', str(HOME), str(HOME / 'acme'))
    work = Path(tempfile.mkdtemp(prefix='.install-', dir=HOME))
    run('chown', 'hysteria:hysteria', str(work))
    stage = 'hy2-setup-' + secrets.token_hex(5)
    try:
        if action == 'reconfigure':
            shutil.copy2(BINARY, work / 'hysteria')
            print('使用已安装核心验证新配置……', flush=True)
        else:
            version = download_binary(work / 'hysteria', args.version)
            print(f'官方程序 {version} 校验通过。正在验证兼容性与证书……', flush=True)
        preview = copy.deepcopy(config)
        # Kernel-assigned port avoids conflict with any existing server.
        preview['listen'] = ':0'
        preview['masquerade'] = {'type': 'string', 'string': {'content': 'setup'}}
        write_atomic(work / 'config.json', json.dumps(preview), 0o600)
        run('chown', 'hysteria:hysteria', str(work / 'config.json'))
        run('systemd-run', '--unit=' + stage, '--property=User=hysteria', '--property=Group=hysteria',
            '--property=AmbientCapabilities=CAP_NET_BIND_SERVICE', str(work / 'hysteria'),
            'server', '-c', str(work / 'config.json'))
        wait_ready(stage, 240)
        run('systemctl', 'stop', stage)
        backup = Path(tempfile.mkdtemp(prefix='hy2-backup-', dir='/root'))
        files = []
        if action != 'reconfigure':
            files.append((BINARY, work / 'hysteria', 0o755))
        if action != 'upgrade':
            files.append((CONFIG, json.dumps(config, ensure_ascii=False, indent=2) + '\n', 0o640))
            if not UNIT.exists():
                files.append((UNIT, SERVICE, 0o644))
            if config['masquerade'].get('type') == 'file' and config['masquerade']['file']['dir'] == str(HOME / 'www') and not (HOME / 'www/index.html').exists():
                files.append((HOME / 'www/index.html', SITE, 0o644))
            for name, content in client_files(config).items():
                files.append((EXPORT / name, content, 0o600))
        deploy_files(files, backup)
        print(f'部署完成。备份：{backup}')
        if action != 'upgrade':
            print(f'Clash 配置：{EXPORT}/clash.yaml\n节点链接：{EXPORT}/hy2.txt\n请在客户端重新导入或更新订阅。\n云防火墙请放行 UDP {port} 和证书验证端口。')
            print((EXPORT / 'hy2.txt').read_text().strip())
    finally:
        run('systemctl', 'stop', stage, check=False)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as exc:
        print('部署未完成：' + str(exc), file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError):
            print(exc.stderr[-1500:], file=sys.stderr)
        sys.exit(1)
