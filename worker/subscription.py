import hashlib
import json
from urllib.error import HTTPError, URLError
from urllib.parse import unquote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from remote import TaskError


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def name(link):
    return unquote(urlsplit(link).fragment) or urlsplit(link).hostname


def identity(link):
    # The installer's per-domain export has a primary and an optional IPv6 variant.
    return str(urlsplit(link).hostname) + ("#6" if name(link).endswith(" (IPv6)") else "#4")


class Subscription:
    def __init__(self, origin, token):
        self.base = origin.rstrip("/") + "/api/nodes"
        self.token = token

    def request(self, method="GET", suffix="", body=None):
        req = Request(self.base + suffix, method=method,
                      data=json.dumps(body).encode() if body is not None else None,
                      headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        try:
            with build_opener(NoRedirect).open(req, timeout=20) as res:
                return json.load(res)["nodes"]
        except (HTTPError, URLError, TimeoutError, ValueError, KeyError) as exc:
            raise TaskError("订阅同步失败，请核对订阅后台连接和授权后点「同步订阅」") from exc

    def sync(self, links, mapping, record):
        nodes = self.request()
        for link in links:
            key = identity(link)
            body = link.split("#")[0]
            old = mapping.get(key)
            # Match even if the user edited the remark on the management page.
            existing = next((n for n in nodes if n["link"].split("#")[0] == body), None)
            if not existing:
                existing = next((n for n in nodes if digest(n["link"].split("#")[0]) == old), None)
                if existing:
                    remark = existing["link"].partition("#")[2]
                    updated = body + ("#" + remark if remark else "")
                    nodes = self.request("PATCH", "/" + existing["id"], {"link": updated})
                else:
                    nodes = self.request("POST", body={"links": [link]})
            mapping[key] = digest(body)
            record(mapping)
