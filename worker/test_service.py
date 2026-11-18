import tempfile
import unittest
from unittest.mock import Mock

from cryptography.fernet import Fernet

from remote import PinnedHost, TaskError, VerifyHost
from service import Manager, create_app
from subscription import Subscription, digest


class TestRemote:
    def __init__(self):
        self.exists = False
        self.installs = []
        self.fingerprint = "SHA256:demo"
        self.export = ["hy2://demo@hy.example:443#test", "hy2://demo@hy.example:444#test%20(IPv6)"]

    def connect(self, server, secret):
        if server["fingerprint"] != self.fingerprint:
            raise VerifyHost(self.fingerprint)
        return self

    def __enter__(self): return self
    def __exit__(self, *args): pass
    def installed(self): return self.exists
    def install(self, action, domain):
        self.installs.append(action)
        self.exists = True
    def links(self): return self.export
    def status(self): return {"active":self.exists,"version":"2.6.0"}


class TestSubscription(Subscription):
    def __init__(self):
        self.links = []
        self.offline = False

    def request(self,method="GET",suffix="",body=None):
        if self.offline:
            raise TaskError("订阅同步失败")
        if method == "POST":
            self.links.extend(v for v in body["links"] if v not in self.links)
        if method == "PATCH":
            idx = [digest(v) for v in self.links].index(suffix[1:])
            self.links[idx] = body["link"]
        return [{"id":digest(v),"link":v} for v in self.links]


class WorkflowTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.remote = TestRemote()
        self.sub = TestSubscription()
        self.manager = Manager(tmp.name,Fernet.generate_key(),self.sub,self.remote.connect)
        self.token = "manager-" + "x"*32
        self.app = create_app(self.manager,self.token).test_client()
        self.form = {"host":"test.example","port":22,"domain":"hy.example","secret":{"kind":"password","value":"test-key"}}
        resp = self.req("POST","/servers",self.form)
        self.assertEqual(resp.status_code,202)
        self.sid = resp.json["id"]
        self.path = "/servers/"+self.sid

    def req(self,method,path,data=None,token=None):
        return self.app.open(path,method=method,json=data,headers={"Authorization":"Bearer "+(token or self.token)})

    def info(self):
        return self.req("GET",self.path).json

    def task(self,action,**fields):
        return self.req("POST",self.path+"/jobs",{"action":action,**fields})

    def step(self):
        self.assertTrue(self.manager.start_one())

    def verify(self):
        self.step()
        self.assertEqual(self.info()["state"],"verify")
        self.assertEqual(self.task("verify",fingerprint="wrong").status_code,409)
        self.assertEqual(self.task("verify",fingerprint=self.remote.fingerprint).status_code,202)
        self.step()

    def test_deploy_restore_sync_and_upgrade(self):
        self.verify()
        self.assertEqual(self.info()["state"],"done")
        self.assertEqual(self.remote.installs,["deploy"])
        self.assertEqual(self.sub.links,self.remote.export)
        self.sub.links.clear()
        self.form.pop("secret")
        self.assertEqual(self.req("POST","/servers",self.form).json["id"],self.sid)
        self.step()
        self.assertEqual(self.info()["state"],"select")
        choices=self.info()["choices"]
        self.task("restore",selected=[choices[0]["id"]]); self.step()
        self.assertEqual(self.sub.links,self.remote.export[:1])
        self.sub.links[0]=self.sub.links[0].split("#")[0]+"#Personal"
        self.remote.export[0]=self.remote.export[0].replace(":443",":8443")
        self.task("sync"); self.step()
        self.assertEqual(len(self.sub.links),2)
        self.assertTrue(self.sub.links[0].endswith(":8443#Personal"))
        self.task("upgrade");self.step()
        self.assertEqual(self.remote.installs,["deploy","upgrade"])
        self.assertTrue(self.info()["health"]["active"])

    def test_sync_failure_does_not_repeat_install_or_leak_password(self):
        self.sub.offline=True
        self.verify()
        self.assertEqual(self.info()["state"],"failed")
        self.sub.offline=False
        self.task("sync");self.step()
        self.assertEqual(self.remote.installs,["deploy"])
        self.assertEqual(self.sub.links,self.remote.export)
        with self.manager.db() as db:
            encrypted=db.execute("SELECT secret FROM servers").fetchone()[0]
        self.assertNotIn(b"test-key",encrypted)
        self.assertNotIn("test-key",str(self.info()))

    def test_scoped_grant_and_changed_host(self):
        self.assertEqual(self.req("GET","/servers",token="ordinary-node-token").status_code,401)
        token=self.req("POST",self.path+"/grant",{}).json["token"]
        self.assertEqual(self.req("POST",self.path+"/credentials",{},token).json["secret"]["value"],"test-key")
        self.assertEqual(self.req("POST","/servers/another/credentials",{},token).status_code,401)
        self.assertEqual(self.req("GET","/servers",token=token).status_code,401)
        self.req("POST",self.path+"/grant",{"revoke":True})
        self.assertEqual(self.req("POST",self.path+"/credentials",{},token).status_code,401)
        self.verify()
        self.remote.fingerprint="SHA256:changed"
        self.task("upgrade"); self.step()
        self.assertEqual(self.info()["state"],"verify")
        self.assertEqual(self.remote.installs,["deploy"])
        self.assertEqual(self.req("DELETE",self.path).status_code,200)
        self.assertEqual(len(self.sub.links),2)

    def test_fingerprint_check_and_busy_guard(self):
        key=Mock()
        key.asbytes.return_value=b'public key'
        with self.assertRaises(VerifyHost) as ctx:
            PinnedHost('').missing_host_key(None,"sample",key)
        PinnedHost(ctx.exception.fingerprint).missing_host_key(None,"sample",key)
        self.assertEqual(self.task("sync").status_code,409)
        self.assertEqual(self.req("DELETE",self.path).status_code,409)
