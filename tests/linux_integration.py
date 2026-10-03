"""Run ONLY in an explicitly disposable Linux VM (not on a production server).

Uses the real official core and systemd. A local test certificate is seeded into
ACME storage so repeated tests never create public CA orders or use real domains.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('installer', ROOT / 'src/installer.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def command(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def main():
    if os.environ.get('HY2_DISPOSABLE_VM') != 'yes' or os.geteuid() != 0:
        raise SystemExit('Requires root and HY2_DISPOSABLE_VM=yes in a disposable VM')
    if m.CONFIG.exists() or m.BINARY.exists() or m.UNIT.exists():
        raise SystemExit('Refusing to touch an existing installation')
    work = Path(tempfile.mkdtemp(prefix='hy2-integration-', dir='/root'))
    domain = 'hy2.integration.test'
    addresses = json.loads(command('ip', '-j', 'addr'))
    ip = next(a['local'] for i in addresses for a in i.get('addr_info', [])
              if a.get('scope') == 'global' and a.get('family') == 'inet')
    with open('/etc/hosts', 'a') as f:
        f.write(f'\n{ip} {domain}\n')
    command('useradd', '--system', '--user-group', '--home-dir', str(m.HOME),
            '--shell', '/usr/sbin/nologin', 'hysteria')
    certificate_dir = m.HOME / 'acme/certificates/acme-v02.api.letsencrypt.org-directory' / domain
    certificate_dir.mkdir(parents=True)
    cert = certificate_dir / (domain + '.crt')
    key = certificate_dir / (domain + '.key')
    command('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '90',
            '-subj', '/CN=' + domain, '-addext', 'subjectAltName=DNS:' + domain,
            '-keyout', str(key), '-out', str(cert))
    (certificate_dir / (domain + '.json')).write_text(json.dumps({'sans': [domain], 'issuer_data': {}}))
    command('chown', '-R', 'hysteria:hysteria', str(m.HOME))
    certificate_hash = hashlib.sha256(cert.read_bytes()).hexdigest()
    verified_binary = work / 'verified-core'
    version = m.download_binary(verified_binary, 'v2.12.3')
    print('Official core verified:', version, flush=True)

    def cached_download(path, _version):
        shutil.copy2(verified_binary, path)
        return version

    with patch.object(m, 'download_binary', side_effect=cached_download):
        m.main(['--domain', domain, '--port', '24443', '--non-interactive'])
    print('PASS fresh install, real core and systemd', flush=True)
    conf = m.load_config(m.CONFIG)
    assert len(conf['auth']['password']) >= 32
    assert conf['listen'] == ':24443'
    assert m.CONFIG.stat().st_gid == pwd.getpwnam('hysteria').pw_gid
    client = json.loads((m.EXPORT / 'clash.yaml').read_text())
    assert client['proxies'][0]['skip-cert-verify'] is False
    # Real QUIC proxy request, with certificate verification against the fixture CA.
    cc = work / 'client.json'
    cc.write_text(json.dumps({'server': f'{domain}:24443', 'auth': conf['auth']['password'],
        'tls': {'sni': domain, 'ca': str(cert)}, 'socks5': {'listen': '127.0.0.1:21080'}}))
    with open(work / 'client.log', 'w') as log:
        proc = subprocess.Popen([str(m.BINARY), 'client', '-c', str(cc)], stdout=log, stderr=log)
        try:
            for _ in range(20):
                if '21080' in command('ss', '-Hltn'):
                    break
                time.sleep(.5)
            assert command('curl', '-fsS', '--max-time', '20', '--proxy', 'socks5h://127.0.0.1:21080',
                           'https://www.gstatic.com/generate_204') == ''
        finally:
            proc.terminate(); proc.wait(timeout=10)
    print('PASS actual QUIC proxy with certificate verification', flush=True)

    conf['masquerade'] = {'type': 'string', 'string': {'content': 'keep-custom-site'}}
    m.write_atomic(m.CONFIG, json.dumps(conf), 0o640)
    command('chown', 'root:hysteria', str(m.CONFIG))
    m.main(['reconfigure', '--non-interactive'])
    assert m.load_config(m.CONFIG)['masquerade'] == conf['masquerade']
    assert m.load_config(m.CONFIG)['auth'] == conf['auth']
    assert hashlib.sha256(cert.read_bytes()).hexdigest() == certificate_hash
    print('PASS reconfigure preserves password, port, custom page and cached certificate', flush=True)

    contents_before = {p: p.read_bytes() for p in [m.CONFIG, m.UNIT, m.EXPORT / 'clash.yaml']}
    with patch.object(m, 'download_binary', side_effect=cached_download):
        m.main(['upgrade', '--non-interactive'])
    assert all(p.read_bytes() == data for p, data in contents_before.items())
    print('PASS upgrade changes no configuration, unit or export', flush=True)

    before = m.CONFIG.stat()
    backup = work / 'rollback'; backup.mkdir()
    try:
        m.deploy_files([(m.CONFIG, '{"listen": ":24443", "tls": {"cert":"/missing", "key":"/missing"}}', 0o640)], backup)
    except RuntimeError:
        pass
    else:
        raise AssertionError('Invalid configuration unexpectedly started')
    m.wait_ready('hysteria-server', 15)
    after = m.CONFIG.stat()
    assert m.CONFIG.read_bytes() == contents_before[m.CONFIG]
    assert (before.st_uid, before.st_gid, before.st_mode) == (after.st_uid, after.st_gid, after.st_mode)
    assert command('systemctl', 'is-active', 'hysteria-server') == 'active'
    print('PASS failed deployment restores content, owner, group, mode and running service', flush=True)
    print('ALL LINUX INTEGRATION CHECKS PASSED', flush=True)


if __name__ == '__main__':
    main()
