import hmac
import ipaddress
import json
import os
import re
import secrets
import sqlite3
import threading
import time
from contextlib import contextmanager
from pathlib import Path

import paramiko

from cryptography.fernet import Fernet
from flask import Flask, abort, jsonify, request
from werkzeug.exceptions import HTTPException

from remote import Remote, TaskError, VerifyHost
from subscription import Subscription, digest, name


def valid_host(value):
    if not isinstance(value, str) or not value or len(value) > 253:
        return False
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return all(re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", part)
                   for part in value.split("."))


class Manager:
    def __init__(self, directory, key, subscription, remote=Remote):
        Path(directory).mkdir(mode=0o700, parents=True, exist_ok=True)
        self.file = str(Path(directory) / "hy2.sqlite")
        self.vault = Fernet(key)
        self.subscription = subscription
        self.remote = remote
        self.wake = threading.Event()
        with self.db() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS servers (
                    id TEXT PRIMARY KEY, host TEXT NOT NULL, port INTEGER NOT NULL,
                    username TEXT NOT NULL, name TEXT NOT NULL, domain TEXT NOT NULL,
                    secret BLOB NOT NULL, fingerprint TEXT NOT NULL DEFAULT '',
                    grant_hash TEXT NOT NULL DEFAULT '', mapping TEXT NOT NULL DEFAULT '{}',
                    health TEXT NOT NULL DEFAULT '{}', UNIQUE(host,port));
                CREATE TABLE IF NOT EXISTS jobs (
                    server TEXT PRIMARY KEY REFERENCES servers(id) ON DELETE CASCADE,
                    action TEXT NOT NULL, state TEXT NOT NULL, message TEXT NOT NULL,
                    fingerprint TEXT NOT NULL DEFAULT '', choices TEXT NOT NULL DEFAULT '[]',
                    updated INTEGER NOT NULL);
            """)
            db.execute("UPDATE jobs SET state='failed',message='后台已重启，请检查状态后重试' WHERE state='running'")

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.file, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    def servers(self):
        with self.db() as db:
            rows = db.execute("""SELECT s.id,s.host,s.port,s.username,s.name,s.domain,s.fingerprint,s.health,
                                  j.action,j.state,j.message,j.choices,j.fingerprint AS pendingFingerprint,j.updated
                                  FROM servers s LEFT JOIN jobs j ON j.server=s.id ORDER BY s.rowid""")
            return [dict(dict(r), choices=json.loads(r["choices"] or "[]"), health=json.loads(r["health"])) for r in rows]

    def queue(self, db, sid, action):
        db.execute("""INSERT OR REPLACE INTO jobs(server,action,state,message,updated)
                      VALUES(?,?,'queued','等待执行',?)""", (sid, action, int(time.time())))
        self.wake.set()

    def change(self, sid, state, message, **extra):
        with self.db() as db:
            db.execute("UPDATE jobs SET state=?,message=?,updated=? WHERE server=?", (state,message,int(time.time()),sid))
            for key, value in extra.items():
                assert key in ("fingerprint","choices")
                db.execute("UPDATE jobs SET " + key + "=? WHERE server=?", (value,sid))

    def start_one(self):
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE")
            job = db.execute("SELECT * FROM jobs WHERE state='queued' ORDER BY updated,rowid LIMIT 1").fetchone()
            if job is None:
                return False
            sid = job["server"]
            server = dict(db.execute("SELECT * FROM servers WHERE id=?", (sid,)).fetchone())
            db.execute("UPDATE jobs SET state='running',message='正在连接 SSH' WHERE server=?", (sid,))
        try:
            secret = json.loads(self.vault.decrypt(server["secret"]))
            with self.remote(server, secret) as ssh:
                action = job["action"]
                installed = ssh.installed()
                if installed and action == "deploy":
                    links = ssh.links()
                    choices = [{"id": digest(link), "name": name(link)} for link in links]
                    self.change(sid, "select", "发现已有安装，选择要恢复的节点", choices=json.dumps(choices))
                    return True
                if not installed and action != "deploy":
                    raise TaskError("未找到现有配置，请使用部署节点")
                before = ssh.status().get("version") if action == "upgrade" else None
                if action in ("deploy","upgrade"):
                    self.change(sid, "running", "正在安装核心及申请证书" if action == "deploy" else "正在升级核心")
                    ssh.install(action, server["domain"])
                health = dict(ssh.status(), checked=int(time.time()))
                if before:
                    health["previousVersion"] = before
                with self.db() as db:
                    db.execute("UPDATE servers SET health=? WHERE id=?", (json.dumps(health),sid))
                if not health["active"] and action != "status":
                    raise TaskError("HY2 主服务未运行，请检查服务状态")
                if action not in ("upgrade","status"):
                    links = ssh.links()
                    if action == "restore":
                        selected = set(json.loads(job["choices"]))
                        links = [link for link in links if digest(link) in selected]
                        if len(links) != len(selected):
                            raise TaskError("远程导出已变化，请重新识别已有节点")
                    self.change(sid, "running", "正在同步订阅")
                    def record(mapping):
                        with self.db() as db:
                            db.execute("UPDATE servers SET mapping=? WHERE id=?", (json.dumps(mapping),sid))
                    self.subscription.sync(links, json.loads(server["mapping"]), record)
                messages = {"upgrade":"核心升级完成","status":"状态已更新","deploy":"部署和同步完成"}
                self.change(sid, "done", messages.get(action,"订阅同步完成"), choices="[]")
        except VerifyHost as exc:
            self.change(sid, "verify", "主机指纹已变化，请重新核实身份" if server["fingerprint"] else "首次连接，请核对主机指纹",
                        fingerprint=exc.fingerprint)
        except TaskError as exc:
            self.change(sid, "failed", str(exc))
        except paramiko.AuthenticationException:
            self.change(sid, "failed", "SSH 认证失败，请核对用户名和密码或私钥")
        except (OSError, paramiko.SSHException):
            self.change(sid, "failed", "SSH 连接失败，请核对地址、端口和网络")
        except Exception:
            self.change(sid, "failed", "连接或读取失败，请核对 SSH 地址、凭据、主机权限和后台配置")
        return True

    def loop(self):
        while True:
            self.wake.clear()
            if not self.start_one():
                self.wake.wait(2)


def create_app(manager, admin):
    if not re.fullmatch(r"[!-~]{32,256}", admin):
        raise ValueError("SERVER_ADMIN_TOKEN must contain at least 32 characters")
    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = 65536

    @app.before_request
    def authorize():
        token = request.headers.get("Authorization","").removeprefix("Bearer ")
        if hmac.compare_digest(token.encode(), admin.encode()):
            return
        sid = (request.view_args or {}).get("sid")
        if sid and request.endpoint in ("credentials","details") and token:
            with manager.db() as db:
                row = db.execute("SELECT grant_hash FROM servers WHERE id=?", (sid,)).fetchone()
            if row and hmac.compare_digest(row[0],digest(token)):
                return
        abort(401, "需要服务器管理授权")

    @app.after_request
    def no_cache(response):
        response.headers["Cache-Control"] = "private, no-store"
        return response

    @app.errorhandler(HTTPException)
    def problem(exc):
        return jsonify(error=exc.description), exc.code

    def body():
        value = request.get_json()
        if not isinstance(value, dict):
            abort(400,"需要 JSON 对象")
        return value

    def writable(db,sid):
        db.execute("BEGIN IMMEDIATE")
        if not db.execute("SELECT 1 FROM servers WHERE id=?", (sid,)).fetchone():
            abort(404, "找不到服务器")
        job = db.execute("SELECT * FROM jobs WHERE server=?", (sid,)).fetchone()
        if job and job["state"] in ("running","queued"):
            abort(409, "服务器已有任务")
        return job

    @app.get("/servers")
    def listing():
        return jsonify(servers=manager.servers())

    @app.post("/servers")
    def add():
        data = body()
        host = str(data.get("host","")).strip().lower()
        port = data.get("port",22)
        user = data.get("username","root")
        if not valid_host(host) or type(port) is not int or not 1 <= port <= 65535 or not re.fullmatch(r"[a-z_][\w-]{0,31}",str(user)):
            abort(400,"SSH 地址、端口或用户名无效")
        with manager.db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM servers WHERE host=? AND port=?", (host,port)).fetchone()
            if row and db.execute("SELECT 1 FROM jobs WHERE server=? AND state IN ('running','queued')",(row["id"],)).fetchone():
                abort(409,"服务器已有任务")
            domain = str(data.get("domain") or (row["domain"] if row else "")).strip().lower()
            if not valid_host(domain) or "." not in domain or not any(c.isalpha() for c in domain):
                abort(400,"请输入节点域名")
            secret = data.get("secret")
            if secret:
                if not isinstance(secret,dict) or secret.get("kind") not in ("password","key") or not isinstance(secret.get("value"),str) or not secret["value"]:
                    abort(400,"SSH 凭据无效")
                encrypted = manager.vault.encrypt(json.dumps(secret).encode())
            elif not row or user != row["username"]:
                abort(400,"首次添加或更换用户需要 SSH 凭据")
            else:
                encrypted = row["secret"]
            sid = row["id"] if row else secrets.token_hex(12)
            title = str(data.get("name") or (row["name"] if row else host))[:128]
            db.execute("""INSERT INTO servers(id,host,port,username,name,domain,secret) VALUES(?,?,?,?,?,?,?)
                          ON CONFLICT(host,port) DO UPDATE SET username=excluded.username,name=excluded.name,
                          domain=excluded.domain,secret=excluded.secret""", (sid,host,port,user,title,domain,encrypted))
            manager.queue(db,sid,"deploy")
        return jsonify(id=sid),202

    @app.get("/servers/<sid>")
    def details(sid):
        return jsonify(next((s for s in manager.servers() if s["id"] == sid),None) or abort(404))

    @app.post("/servers/<sid>/credentials")
    def credentials(sid):
        with manager.db() as db:
            row = db.execute("SELECT secret,host,port,username,fingerprint FROM servers WHERE id=?",(sid,)).fetchone()
        if not row:
            abort(404)
        return jsonify(host=row["host"],port=row["port"],username=row["username"],fingerprint=row["fingerprint"],
                       secret=json.loads(manager.vault.decrypt(row["secret"])))

    @app.post("/servers/<sid>/grant")
    def grant(sid):
        revoke = body().get("revoke") is True
        token = "" if revoke else secrets.token_urlsafe(36)
        with manager.db() as db:
            if not db.execute("UPDATE servers SET grant_hash=? WHERE id=?",(digest(token) if token else "",sid)).rowcount:
                abort(404)
        return jsonify(token=token)

    @app.delete("/servers/<sid>")
    def remove(sid):
        with manager.db() as db:
            writable(db,sid)
            db.execute("DELETE FROM servers WHERE id=?",(sid,))
        return jsonify(ok=True)

    @app.post("/servers/<sid>/jobs")
    def job(sid):
        data = body()
        action = data.get("action")
        with manager.db() as db:
            previous = writable(db,sid)
            if action == "verify":
                if not previous or previous["state"] != "verify" or data.get("fingerprint") != previous["fingerprint"]:
                    abort(409,"指纹确认已失效")
                db.execute("UPDATE servers SET fingerprint=? WHERE id=?",(previous["fingerprint"],sid))
                db.execute("UPDATE jobs SET state='queued',message='已确认指纹',fingerprint='' WHERE server=?",(sid,))
                manager.wake.set()
            elif action == "restore":
                selected = data.get("selected")
                if not previous or previous["state"] != "select" or not isinstance(selected,list) or not selected:
                    abort(409,"请选择待恢复的节点")
                allowed = {v["id"] for v in json.loads(previous["choices"])}
                if not all(isinstance(v,str) and v in allowed for v in selected):
                    abort(400,"选择已过期")
                manager.queue(db,sid,action)
                db.execute("UPDATE jobs SET choices=? WHERE server=?",(json.dumps(selected),sid))
            elif action in ("deploy","sync","upgrade","status"):
                manager.queue(db,sid,action)
            else:
                abort(400,"不支持的任务")
        return jsonify(id=sid),202

    return app


def production():
    os.umask(0o077)
    from urllib.parse import urlsplit
    origin = os.environ["SUBSCRIPTION_ORIGIN"]
    if urlsplit(origin).scheme != "https" and urlsplit(origin).hostname not in ("127.0.0.1","localhost"):
        raise ValueError("订阅地址需要 HTTPS")
    admin, node_token = os.environ["SERVER_ADMIN_TOKEN"], os.environ["NODE_API_TOKEN"]
    if admin == node_token:
        raise ValueError("服务器管理令牌必须独立于节点口令")
    manager = Manager(os.getenv("HY2_DATA","/data"), os.environ["VAULT_KEY"],
                      Subscription(origin,node_token))
    app = create_app(manager,admin)
    threading.Thread(target=manager.loop,daemon=True).start()
    return app
