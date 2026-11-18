"""Fixed operations for the HY2 installer. No user-supplied shell commands."""
import base64
import hashlib
import io
import re
import shlex
import threading
from pathlib import Path

import paramiko

INSTALLER = Path(__file__).resolve().parents[1] / "hysteria.sh"
EXPORT = "/etc/hysteria/client/hy2.txt"
CONFIG = "/etc/hysteria/config.yaml"


class TaskError(Exception):
    pass


class VerifyHost(Exception):
    def __init__(self, fingerprint):
        self.fingerprint = fingerprint


class PinnedHost(paramiko.MissingHostKeyPolicy):
    def __init__(self, expected):
        self.expected = expected

    def missing_host_key(self, client, hostname, key):
        actual = "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
        if actual != self.expected:
            raise VerifyHost(actual)


class Remote:
    def __init__(self, server, secret):
        self.server = server
        self.secret = secret
        self.client = paramiko.SSHClient()

    def __enter__(self):
        self.client.set_missing_host_key_policy(PinnedHost(self.server["fingerprint"]))
        auth = {}
        if self.secret["kind"] == "password":
            auth["password"] = self.secret["value"]
        else:
            for key_type in (paramiko.Ed25519Key, paramiko.RSAKey, paramiko.ECDSAKey):
                try:
                    auth["pkey"] = key_type.from_private_key(io.StringIO(self.secret["value"]),
                                                             password=self.secret.get("passphrase") or None)
                    break
                except (ValueError, paramiko.SSHException):
                    continue
            else:
                raise TaskError("私钥格式或私钥口令无效")
        try:
            self.client.connect(self.server["host"], port=self.server["port"], username=self.server["username"],
                                timeout=15, auth_timeout=20, banner_timeout=20, allow_agent=False,
                                look_for_keys=False, **auth)
            return self
        except BaseException:
            self.client.close()
            raise

    def __exit__(self, *args):
        self.client.close()

    def run(self, command, payload=None, limit=65536):
        prefix = "" if self.server["username"] == "root" else "sudo -n -- "
        chan = self.client.get_transport().open_session(timeout=15)
        # A wall-clock deadline also covers a stalled command with no output.
        deadline = threading.Timer(1200, chan.close)
        deadline.start()
        try:
            chan.set_combine_stderr(True)
            chan.exec_command(prefix + command)
            if payload:
                chan.sendall(payload)
            chan.shutdown_write()
            data = bytearray()
            while chunk := chan.recv(8192):
                if limit and len(data) + len(chunk) > limit:
                    raise TaskError("远程输出超出预期大小")
                if limit:
                    data.extend(chunk)
            return chan.recv_exit_status(), bytes(data).decode(errors="replace")
        finally:
            deadline.cancel()
            chan.close()

    def installed(self):
        code, _ = self.run("test -e " + CONFIG)
        if code not in (0, 1):
            raise TaskError("无法检查现有安装，请检查 SSH 用户权限")
        # sudo failures also return 1; never treat a privilege failure as a fresh host.
        if self.run("id -u")[1].strip() != "0":
            raise TaskError("需要 root 或免密 sudo")
        return code == 0

    def install(self, action, domain):
        if action == "deploy":
            command = "bash -s -- install --non-interactive --dns-wait 60 --domain " + shlex.quote(domain)
        else:
            command = "bash -s -- upgrade --non-interactive"
        code, _ = self.run(command, INSTALLER.read_bytes(), limit=0)
        if code:
            raise TaskError("安装脚本未成功完成，请检查 Debian 13、DNS、端口和服务状态，再重新提交")

    def links(self):
        code, result = self.run("cat " + EXPORT)
        lines = [line.strip() for line in result.splitlines() if line.strip()]
        if code or not lines or any(not line.startswith(("hy2://", "hysteria2://")) for line in lines):
            raise TaskError("未找到可恢复的 HY2 导出文件，请检查现有安装")
        return lines

    def status(self):
        code, _ = self.run("systemctl is-active hysteria-server.service")
        rc, version = self.run("/usr/local/bin/hysteria version")
        match = re.search(r'\bv?2\.\d+\.\d+\b', version)
        return {"active": code == 0, "version": match.group() if not rc and match else ""}
