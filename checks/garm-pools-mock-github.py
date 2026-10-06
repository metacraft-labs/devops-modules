"""Mock GitHub management API for the GARM POOL gates.

Runner-Fleet-Capability-Pools-And-Remote-Driving RC2 (t_garm_pools_labels) and
RB3 (t_garm_capability_placement). Real GitHub cannot be reached hermetically,
so this is the sanctioned stand-in (same shape as the garm-reconcile gate's
mock, port from $MOCK_PORT). It serves BOTH:

  * the CLASSIC REST runners surface GARM POOLS use — org lookup, runner groups,
    App installation token, an empty `actions/runners` list, a registration
    token — noting `garm-cli pool add` is a pure DB op (it never contacts the
    provider or GitHub) that only needs the org entity + GARM's seeded default
    `github_linux` template; and
  * the ADO runner-scale-set surface a COEXISTING scale set needs (create/list/
    get/delete + a complete message session so GARM's scale-set listener stays
    alive long-polling a queue that never yields a job).

No runner is ever provisioned (min-idle 0, no job handed out). The gates assert
on the reconciled POOL objects + `garm_pool_*` metrics, which GARM populates
from its DB independently of pool-manager/listener health.
"""
import base64
import json
import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("MOCK_PORT", "8099"))
LOCK = threading.Lock()
SCALESETS: dict = {}
NEXT_ID = [1000]


def now_plus(secs):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + secs))


def _b64(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()


def fake_jwt(ttl=3600):
    hdr = _b64({"alg": "none", "typ": "JWT"})
    pl = _b64({"exp": int(time.time()) + ttl, "iat": int(time.time())})
    return "%s.%s." % (hdr, pl)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        if n == 0:
            return {}
        raw = self.rfile.read(n)
        try:
            return json.loads(raw)
        except Exception:
            return {}

    def do_GET(self):
        p = self.path.split("?")[0]
        # Org lookup.
        if p.startswith("/orgs/") and p.count("/") == 2:
            org = p.split("/")[2]
            return self._send(200, {"login": org, "id": 42,
                                    "url": "http://127.0.0.1:%d%s" % (PORT, p)})
        # Runner groups.
        if p.startswith("/orgs/") and p.endswith("/actions/runner-groups"):
            return self._send(200, {"total_count": 1, "runner_groups": [
                {"id": 1, "name": "Default", "default": True, "visibility": "all"}]})
        # Classic runners list (pool manager poll) — empty so nothing reconciles.
        if p.endswith("/actions/runners"):
            return self._send(200, {"total_count": 0, "runners": []})
        # ADO: list runner scale sets by name.
        if p.endswith("/_apis/runtime/runnerscalesets"):
            q = parse_qs(urlparse(self.path).query)
            name = (q.get("name") or [""])[0]
            with LOCK:
                if name and name in SCALESETS:
                    return self._send(200, {"count": 1, "value": [SCALESETS[name]]})
                return self._send(200, {"count": 0, "value": []})
        # ADO: long-poll the message queue — 202 == "no messages".
        if "/messages" in p or "/ado/mq" in p:
            time.sleep(2)
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        # ADO: get scale set by id.
        if "/_apis/runtime/runnerscalesets/" in p:
            tail = p.split("/_apis/runtime/runnerscalesets/", 1)[1]
            if tail.isdigit():
                sid = int(tail)
                with LOCK:
                    for v in SCALESETS.values():
                        if v["id"] == sid:
                            return self._send(200, v)
                return self._send(404, {"message": "not found"})
        if p == "/app":
            return self._send(200, {"id": 1, "slug": "mock-app"})
        return self._send(200, {})

    def do_POST(self):
        p = self.path.split("?")[0]
        # App installation token.
        if p.startswith("/app/installations/") and p.endswith("/access_tokens"):
            return self._send(201, {"token": "ghs_mock_installation_token",
                                    "expires_at": now_plus(3600),
                                    "permissions": {"actions": "write",
                                                    "organization_self_hosted_runners": "write"}})
        # Org runner registration token.
        if p.endswith("/actions/runners/registration-token"):
            return self._send(201, {"token": "mock_reg_token", "expires_at": now_plus(3600)})
        # ADO service admin info — hand back our own base as the pipeline URL.
        if p == "/actions/runner-registration":
            return self._send(200, {"url": "http://127.0.0.1:%d/ado" % PORT,
                                    "token": "mock_ado_jwt"})
        # ADO: create a message session for a scale set (complete session so the
        # listener does not panic on a nil SessionID).
        if "/_apis/runtime/runnerscalesets/" in p and p.endswith("/sessions"):
            mid = p.split("/_apis/runtime/runnerscalesets/", 1)[1].split("/")[0]
            sset = None
            if mid.isdigit():
                with LOCK:
                    for v in SCALESETS.values():
                        if v["id"] == int(mid):
                            sset = v
            return self._send(200, {
                "sessionId": str(uuid.uuid4()),
                "ownerName": "garm",
                "runnerScaleSet": sset,
                "messageQueueUrl": "http://127.0.0.1:%d/ado/mq" % PORT,
                "messageQueueAccessToken": fake_jwt(),
                "statistics": {},
            })
        # ADO: create a runner scale set.
        if p.endswith("/_apis/runtime/runnerscalesets"):
            body = self._read()
            name = body.get("name", "unknown")
            with LOCK:
                if name in SCALESETS:
                    obj = SCALESETS[name]
                else:
                    sid = NEXT_ID[0]
                    NEXT_ID[0] += 1
                    obj = {
                        "id": sid,
                        "name": name,
                        "runnerGroupId": body.get("runnerGroupId", 1),
                        "runnerGroupName": "Default",
                        "labels": body.get("labels", []),
                        "enabled": body.get("enabled", True),
                        "runnerSetting": body.get("RunnerSetting", {}),
                        "runnerJitConfigUrl": "http://127.0.0.1:%d/ado/jit" % PORT,
                    }
                    SCALESETS[name] = obj
            return self._send(200, obj)
        return self._send(200, {})

    def do_PATCH(self):
        p = self.path.split("?")[0]
        if "/sessions/" in p:
            return self._send(200, {
                "sessionId": p.rstrip("/").rsplit("/", 1)[1],
                "ownerName": "garm",
                "messageQueueUrl": "http://127.0.0.1:%d/ado/mq" % PORT,
                "messageQueueAccessToken": fake_jwt(),
            })
        return self._send(200, {})

    def do_DELETE(self):
        p = self.path.split("?")[0]
        if "/sessions/" in p:
            return self._send(204, {})
        if "/_apis/runtime/runnerscalesets/" in p:
            tail = p.split("/_apis/runtime/runnerscalesets/", 1)[1]
            if tail.isdigit():
                sid = int(tail)
                with LOCK:
                    for k, v in list(SCALESETS.items()):
                        if v["id"] == sid:
                            del SCALESETS[k]
            return self._send(204, {})
        return self._send(204, {})


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
