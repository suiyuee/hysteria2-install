import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, unquote, urlsplit

import importlib.util
SOURCE = Path(__file__).resolve().parents[1] / 'src/installer.py'
spec = importlib.util.spec_from_file_location('installer', SOURCE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def args(**kwargs):
    return argparse.Namespace(domain='hy.example.com', email='a@example.com',
                              non_interactive=True, port=None, masquerade_url=None, builtin_site=False, **kwargs)


class InstallerTests(unittest.TestCase):
    def test_existing_password_port_and_obfs_survive(self):
        old = {'listen': ':63992', 'tls': {'cert': 'old'},
               'auth': {'type': 'password', 'password': 'a:@/# ?\"\n汉字'},
               'quic': {'maxIdleTimeout': '40s'},
               'obfs': {'type': 'salamander', 'salamander': {'password': 'b &?='}}}
        config = m.choose_settings(args(), old)
        self.assertEqual(config['listen'], ':63992')
        self.assertEqual(config['quic'], old['quic'])
        self.assertNotIn('tls', config)
        exports = m.client_files(config)
        node = json.loads(exports['clash.yaml'])['proxies'][0]
        uri = urlsplit(exports['hy2.txt'].strip())
        self.assertEqual(unquote(uri.username), old['auth']['password'])
        self.assertEqual(node['password'], old['auth']['password'])
        self.assertFalse(node['skip-cert-verify'])
        self.assertEqual(parse_qs(uri.query)['insecure'], ['0'])
        self.assertEqual(parse_qs(uri.query)['obfs-password'], ['b &?='])
        self.assertEqual(node['obfs-password'], 'b &?=')
        self.assertEqual(old['tls'], {'cert': 'old'})

    def test_reconfigure_preserves_acme_and_custom_site(self):
        old = {'listen': ':443', 'auth': {'type': 'password', 'password': 'existing'},
               'acme': {'domains': ['hy.example.com'], 'email': 'old@example.com',
                        'ca': 'zerossl', 'type': 'http', 'dir': '/custom/acme'},
               'masquerade': {'type': 'proxy', 'proxy': {'url': 'https://example.com'}}}
        options = args(); options.email = None
        config = m.choose_settings(options, old)
        self.assertEqual(config['acme'], old['acme'])
        self.assertEqual(config['masquerade'], old['masquerade'])
        options.builtin_site = True
        self.assertEqual(m.choose_settings(options, old)['masquerade']['type'], 'file')

    def test_fresh_install_generates_new_password_and_default_email(self):
        options = args(); options.email = None
        first = m.choose_settings(options, {})
        second = m.choose_settings(options, {})
        self.assertNotEqual(first['auth']['password'], second['auth']['password'])
        self.assertGreaterEqual(len(first['auth']['password']), 32)
        self.assertEqual(first['acme']['email'], '1094620146@qq.com')

    def test_upgrade_rejects_configuration_options(self):
        with self.assertRaises(SystemExit) as raised:
            m.main(['upgrade', '--domain', 'hy.example.com', '--dry-run'])
        self.assertEqual(raised.exception.code, 2)

    def test_rejects_unsafe_domains_and_unsupported_auth(self):
        for value in ['https://example.com', '127.0.0.1', 'example.com:443',
                      'a.example.com\nx: y', '*.example.com', '-a.example.com']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                m.domain_name(value)
        with self.assertRaises(ValueError):
            m.choose_settings(args(), {'auth': {'type': 'http'}, 'listen': ':443'})

    def test_download_rejects_wrong_digest_before_writing(self):
        release = {'tag_name': 'app/v2.12.3', 'assets': [{
            'name': 'hysteria-linux-amd64', 'digest': 'sha256:' + '0' * 64,
            'browser_download_url': 'https://github.com/apernet/hysteria/releases/download/app/v2.12.3/hysteria-linux-amd64'}]}
        with tempfile.TemporaryDirectory() as td, patch.object(m.platform, 'machine', return_value='x86_64'), patch.object(m, 'fetch', side_effect=[json.dumps(release).encode(), b'wrong']):
            target = Path(td) / 'hysteria'
            with self.assertRaisesRegex(ValueError, 'SHA256'):
                m.download_binary(target, None)
            self.assertFalse(target.exists())

    def test_dns_rejects_stale_ipv6_and_cdn(self):
        interface = json.dumps([{'addr_info': [{'scope': 'global', 'local': '192.0.2.2'}]}])
        result = subprocess.CompletedProcess([], 0, interface, '')
        for ips in [['192.0.2.3'], ['192.0.2.2', '2001:db8::1']]:
            with self.subTest(ips=ips), patch.object(m, 'run', return_value=result), patch.object(m.socket, 'getaddrinfo', return_value=[(0, 0, 0, '', (ip, 0)) for ip in ips]):
                with self.assertRaisesRegex(ValueError, 'DNS'):
                    m.dns_check('hy.example.com', 0)

    def test_failed_restart_restores_binary_config_and_exports(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            binary, config, unit, export = [root / name for name in ('binary', 'config', 'unit', 'export')]
            for path in (binary, config, unit):
                path.write_text('original-' + path.name)
                path.chmod(0o640)
            candidate = root / 'candidate'
            candidate.write_text('new binary')
            backup = root / 'backup'; backup.mkdir()
            files = [(binary, candidate, 0o755), (config, 'new config', 0o640),
                     (unit, 'new unit', 0o644), (export, 'new password', 0o600)]
            calls = []
            def run(*cmd, check=True):
                calls.append(cmd)
                if cmd == ('systemctl', 'restart', 'hysteria-server') and check:
                    raise subprocess.CalledProcessError(1, cmd, stderr='failed')
                return subprocess.CompletedProcess(cmd, 0, 'active' if cmd[:2] == ('systemctl', 'is-active') else '', '')
            with patch.object(m, 'CONFIG', config), patch.object(m, 'UNIT', unit), patch.object(m, 'run', side_effect=run), patch.object(m, 'wait_ready'):
                with self.assertRaises(subprocess.CalledProcessError):
                    m.deploy_files(files, backup)
            for path in (binary, config, unit):
                self.assertEqual(path.read_text(), 'original-' + path.name)
                self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            self.assertFalse(export.exists())
            self.assertEqual(calls.count(('systemctl', 'restart', 'hysteria-server')), 2)

    def test_dry_run_has_no_mutations_or_network(self):
        with tempfile.TemporaryDirectory() as td, patch.object(m, 'CONFIG', Path(td) / 'none'), patch.object(m, 'fetch', side_effect=AssertionError('network')), patch.object(m, 'run', side_effect=AssertionError('command')):
            m.main(['--domain', 'hy.example.com', '--email', 'a@example.com', '--dry-run', '--non-interactive'])


if __name__ == '__main__':
    unittest.main()
