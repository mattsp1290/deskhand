#!/usr/bin/env python3
"""Scripted MCP acceptance client for one deskhand Mac (docs/contract.md, 0.11-draft).

Standard library only. Configuration comes from environment variables and mounted files
(see acceptance/README.md). Evidence is written to stdout as JSON lines, one per check,
then one summary line. Exit status: 0 when every selected check passed, 1 when any failed,
2 on a configuration error. The bearer token is read from a file, is never put in argv,
and is redacted from everything this script prints.
"""

import argparse
import base64
import hashlib
import http.client
import json
import os
import pathlib
import re
import secrets
import signal
import ssl
import struct
import sys
import time

PROTOCOL_VERSION = "2026-07-28"  # contract section 2.1
CONTRACT_VERSION = "0.11-draft"  # status.contract_version this client was written against
MAX_LONG_EDGE = 2576  # section 16
MAX_PIXELS = 3_588_000
MAX_IMAGE_BYTES = 3_750_000
JPEG_QUALITY_STEPS = (85, 75, 65, 60)
MAX_RESPONSE_BODY_BYTES = 5_400_000
FRAME_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")  # section 4.2; used with fullmatch
HANDLE_RE = re.compile(r"[A-Za-z0-9._:-]{1,128}")  # holder_id, operation_id (4.1, 4.3)
TOKEN_RE = re.compile(r"^[\x21-\x7e]+\Z")  # visible ASCII, as deskhand loads it; keeps the header well formed

# Section 3.2: order, titles and annotations of the six tools.
TOOLS = [
    ("status", "Status", (True, False, True, False)),
    ("displays", "List displays", (True, False, True, False)),
    ("screenshot", "Take a screenshot", (True, False, False, True)),
    ("pointer", "Pointer input", (False, True, True, True)),
    ("keyboard", "Keyboard input", (False, True, True, True)),
    ("lease", "Lease", (False, False, False, False)),
]
HINTS = ("readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint")

# Run order. Checks that need the lease run between acquire and release.
PRE_LEASE = ["discover", "tools_list", "status", "neg_missing_token", "neg_wrong_token", "neg_get",
             "neg_delete", "neg_wrong_host", "neg_unsupported_version", "neg_method_mismatch",
             "neg_name_mismatch", "neg_missing_header", "neg_no_lease", "displays", "screenshot"]
UNDER_LEASE = ["neg_stale_frame", "pointer_move", "type_text"]
ALL_CHECKS = PRE_LEASE + ["lease"] + UNDER_LEASE
OPERATOR_CHECKS = ("pointer_move", "type_text")  # need a permitted app set up at the Mac (6.9)
DEFAULT_CHECKS = [c for c in ALL_CHECKS if c not in OPERATOR_CHECKS]


class CheckFailed(Exception):
    pass


class Terminated(BaseException):
    """Raised from the SIGTERM handler (Job deadline) so finally blocks release the lease."""


def expect(cond, message):
    if not cond:
        raise CheckFailed(message)


class Redactor:
    """Replaces every registered secret with a marker in text that is about to leave the process."""

    def __init__(self):
        self._secrets = []

    def add(self, value):
        if value:  # also the form json.dumps gives a value with quotes or backslashes
            self._secrets += [value, json.dumps(value)[1:-1]]

    def __call__(self, text):
        for value in self._secrets:
            text = text.replace(value, "[REDACTED]")
        return text


class Config:
    def __init__(self, env):
        def need(name):
            value = env.get(name, "").strip()
            if not value:
                raise ValueError(f"{name} is required")
            return value

        self.host = need("DESKHAND_HOST")
        self.port = int(need("DESKHAND_PORT"))
        self.mac = need("DESKHAND_MAC")
        base = env.get("DESKHAND_CREDENTIALS_DIR", "/etc/deskhand-acceptance")
        self.client_cert = env.get("DESKHAND_CLIENT_CERT", f"{base}/tls/tls.crt")
        self.client_key = env.get("DESKHAND_CLIENT_KEY", f"{base}/tls/tls.key")
        self.ca_cert = env.get("DESKHAND_CA_CERT", f"{base}/tls/ca.crt")
        self.token_file = env.get("DESKHAND_TOKEN_FILE", f"{base}/token/token")
        self.run_id = env.get("DESKHAND_RUN_ID") or secrets.token_hex(4)
        self.holder_id = env.get("DESKHAND_HOLDER_ID") or f"acceptance-{self.run_id}-{secrets.token_hex(4)}"
        # operation_id is "acc-<run_id>-<12 hex>": 17 characters around run_id, so it can be up to 111.
        if not HANDLE_RE.fullmatch(self.holder_id) or not HANDLE_RE.fullmatch(f"acc-{self.run_id}-{'0' * 12}"):
            raise ValueError("DESKHAND_RUN_ID or DESKHAND_HOLDER_ID is outside the contract 4.1/4.3 alphabet")
        apps = env.get("DESKHAND_PERMITTED_APPS", "com.apple.TextEdit").split(",")
        self.permitted_apps = list(dict.fromkeys(a.strip() for a in apps if a.strip()))
        if not self.permitted_apps:  # an empty list is invalid_argument (6.8)
            raise ValueError("DESKHAND_PERMITTED_APPS names no bundle identifier")
        self.node = env.get("NODE_NAME", "")
        self.timeout = float(env.get("DESKHAND_TIMEOUT_S", "30"))


def build_request(method, params, *, host, port, token, request_id=1, version=PROTOCOL_VERSION,
                  header_overrides=None):
    """Return (headers, body) for one MCP request (contract 2.3, 3). Overrides of None drop a header."""
    params = dict(params)
    params["_meta"] = {"io.modelcontextprotocol/protocolVersion": version}
    body = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params},
                      separators=(",", ":")).encode()
    headers = {
        "Host": f"{host}:{port}",
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": version,
        "Mcp-Method": method,
    }
    if method == "tools/call":
        headers["Mcp-Name"] = params["name"]
    for name, value in (header_overrides or {}).items():
        if value is None:
            headers.pop(name, None)
        else:
            headers[name] = value
    return headers, body


class Response:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body

    def json(self):
        return json.loads(self.body) if self.body else None

    def rpc_error_code(self):
        try:
            return self.json()["error"]["code"]
        except (ValueError, KeyError, TypeError):
            return None

    def tool_result(self):
        """Return (structuredContent, isError, content) or raise CheckFailed (contract 3.3)."""
        expect(self.status == 200, f"HTTP {self.status}, rpc error {self.rpc_error_code()}")
        result = (self.json() or {}).get("result")
        expect(isinstance(result, dict), "no JSON-RPC result")
        expect(result.get("resultType") == "complete", "resultType is not complete")
        expect(isinstance(result.get("isError"), bool), "isError missing")
        content = result.get("content") or []
        expect(content and content[-1].get("type") == "text", "content does not end with a text block")
        return result.get("structuredContent"), result["isError"], content


class Client:
    def __init__(self, cfg, token):
        self.cfg = cfg
        self.token = token
        self._next_id = 0
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)  # verifies the chain and the hostname (2.2)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_verify_locations(cafile=cfg.ca_cert)
        ctx.load_cert_chain(cfg.client_cert, cfg.client_key)
        self.ctx = ctx

    def send(self, http_method, headers, body=None):
        conn = http.client.HTTPSConnection(self.cfg.host, self.cfg.port, context=self.ctx,
                                           timeout=self.cfg.timeout)
        try:
            conn.request(http_method, "/mcp", body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read(MAX_RESPONSE_BODY_BYTES + 1)
            expect(len(data) <= MAX_RESPONSE_BODY_BYTES, "response body over MAX_RESPONSE_BODY_BYTES")
            return Response(resp.status, {k.lower(): v for k, v in resp.getheaders()}, data)
        finally:
            conn.close()

    def rpc(self, method, params=None, **kwargs):
        self._next_id += 1
        kwargs.setdefault("token", self.token)
        headers, body = build_request(method, params or {}, host=self.cfg.host, port=self.cfg.port,
                                      request_id=self._next_id, **kwargs)
        return self.send("POST", headers, body)

    def call(self, tool, arguments, **kwargs):
        return self.rpc("tools/call", {"name": tool, "arguments": arguments}, **kwargs).tool_result()


def refusal(sc):
    """Describe a tool error, naming the precondition when one is not met (9.5 step 1, 5.1)."""
    sc = sc or {}
    code = sc.get("code")
    if code is not None and code == sc.get("state"):
        return f"precondition: got {code}; deskhand state is {code}, not ok (9.5 step 1)"
    if code == "lease_held_by_other":
        return f"precondition: got {code}; another holder holds the lease"
    return f"got {code}"


def image_size(data, mime_type):
    """Pixel size read from the PNG IHDR or the JPEG SOFn marker, or None."""
    if mime_type == "image/png" and data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if mime_type == "image/jpeg" and data[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                return None
            marker, length = data[i + 1], struct.unpack(">H", data[i + 2:i + 4])[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return w, h
            i += 2 + length
    return None


class Run:
    def __init__(self, cfg, client, out, redact):
        self.cfg, self.client, self.out, self.redact = cfg, client, out, redact
        self.results = []
        self.frame = None

    def emit(self, record):
        self.out.write(self.redact(json.dumps(record, sort_keys=True)) + "\n")
        self.out.flush()

    def run_check(self, name, fn):
        facts = {}
        start = time.monotonic()
        try:
            fn(facts)
            ok, error = True, None
        except CheckFailed as exc:
            ok, error = False, str(exc)
        except Exception as exc:  # TLS, network, decode faults
            ok, error = False, f"{type(exc).__name__}: {exc}"
        record = {"check": name, "ok": ok, "ms": round((time.monotonic() - start) * 1000, 1),
                  "facts": facts}
        if error:
            record["error"] = error
        self.results.append(record)
        self.emit(record)
        return ok

    # --- reads -------------------------------------------------------------------------------
    def discover(self, facts):
        resp = self.client.rpc("server/discover")
        expect(resp.status == 200, f"HTTP {resp.status}")
        result = resp.json()["result"]
        info = result.get("_meta", {}).get("io.modelcontextprotocol/serverInfo", {})
        facts.update(supported_versions=result.get("supportedVersions"), server=info)
        expect(result.get("supportedVersions") == [PROTOCOL_VERSION], "supportedVersions")
        expect(result.get("resultType") == "complete", "resultType")
        expect(result.get("capabilities", {}).get("tools", {}).get("listChanged") is False, "tools capability")
        expect(info.get("name") == "deskhand", "serverInfo.name")
        expect(result.get("ttlMs") == 300000 and result.get("cacheScope") == "private", "caching hints")

    def tools_list(self, facts):
        resp = self.client.rpc("tools/list")
        expect(resp.status == 200, f"HTTP {resp.status}")
        result = resp.json()["result"]
        tools = result.get("tools", [])
        facts["tools"] = [t.get("name") for t in tools]
        expect(facts["tools"] == [t[0] for t in TOOLS], "tool names or order differ from section 3.2")
        expect("nextCursor" not in result, "nextCursor present")
        expect(result.get("resultType") == "complete", "resultType")
        expect(result.get("ttlMs") == 300000 and result.get("cacheScope") == "private", "caching hints")
        for tool, (name, title, hints) in zip(tools, TOOLS):
            expect(tool.get("title") == title, f"{name}: title")
            got = tuple(tool.get("annotations", {}).get(h) for h in HINTS)
            expect(got == hints, f"{name}: annotations {got}")
            for key in ("description", "inputSchema", "outputSchema"):
                expect(key in tool, f"{name}: missing {key}")

    def status(self, facts):
        sc, is_error, _ = self.client.call("status", {"holder_id": self.cfg.holder_id})
        expect(not is_error, refusal(sc))
        facts.update({k: sc.get(k) for k in ("contract_version", "mcp_protocol_version", "server_version",
                                             "mac", "state", "active_states", "conditions")})
        facts["contract_version_matches"] = sc.get("contract_version") == CONTRACT_VERSION
        expect(sc.get("mcp_protocol_version") == PROTOCOL_VERSION, "mcp_protocol_version")
        expect(sc.get("mac") == self.cfg.mac, "mac differs from DESKHAND_MAC")
        expect((sc.get("lease") or {}).get("held_by_caller") is False, "lease view before acquire")

    def displays(self, facts):
        sc, is_error, _ = self.client.call("displays", {})
        expect(not is_error, refusal(sc))
        facts["display_config_generation"] = sc.get("display_config_generation")
        facts["displays"] = [{k: d.get(k) for k in ("display_id", "is_main", "pixel_size")}
                             for d in sc.get("displays", [])]
        expect(facts["displays"], "no displays")

    def take_screenshot(self, facts):
        sc, is_error, content = self.client.call("screenshot", {"holder_id": self.cfg.holder_id})
        expect(not is_error, refusal(sc))
        expect(len(content) == 2 and content[0].get("type") == "image", "want an image block then a text block")
        data = base64.b64decode(content[0]["data"], validate=True)
        w, h = sc["output_pixel_size"]["width"], sc["output_pixel_size"]["height"]
        facts.update(frame_id=sc["frame_id"], image_bytes=len(data), sha256=sc["sha256"],
                     output_pixel_size=[w, h], format=sc.get("format"), max_age_ms=sc.get("max_age_ms"),
                     frontmost_app=sc.get("frontmost_app"))
        expect(FRAME_ID_RE.fullmatch(sc["frame_id"]), "frame_id alphabet")
        expect(sc.get("format") == "jpeg" and sc.get("jpeg_quality") in JPEG_QUALITY_STEPS, "default format")
        expect(len(data) == sc["image_bytes"] <= MAX_IMAGE_BYTES, "image_bytes")
        expect(hashlib.sha256(data).hexdigest() == sc["sha256"], "sha256 does not match image")
        expect(max(w, h) <= MAX_LONG_EDGE and w * h <= MAX_PIXELS, "size over contract limits")
        expect(content[0].get("mimeType") == sc.get("mime_type"), "mimeType")
        expect(image_size(data, sc.get("mime_type")) == (w, h), "decoded size differs from output_pixel_size")
        self.frame = sc
        return sc

    def screenshot(self, facts):
        self.take_screenshot(facts)

    # --- lease (section 5) -----------------------------------------------------------------
    def lease(self, op, facts, ttl_ms=None):
        args = {"op": op, "holder_id": self.cfg.holder_id}
        if ttl_ms is not None:
            args["ttl_ms"] = ttl_ms
        sc, is_error, _ = self.client.call("lease", args)
        expect(not is_error, refusal(sc))
        facts.update(lease_result=sc.get("lease_result"), held_by_caller=sc["lease"].get("held_by_caller"),
                     expires_in_ms=sc["lease"].get("expires_in_ms"))
        return sc

    def lease_acquire(self, facts):
        sc = self.lease("acquire", facts, ttl_ms=120000)  # the longest TTL (5.1); renewed after the checks
        result = sc["lease_result"]
        if result.get("code") == "lease_held_by_other":
            raise CheckFailed("precondition: another holder holds the lease (5.1)")
        expect(result.get("outcome") == "acquired", f"outcome {result.get('outcome')}, code {result.get('code')}")
        expect(sc["lease"].get("held_by_caller") is True, "held_by_caller")

    def lease_renew(self, facts):
        sc = self.lease("renew", facts, ttl_ms=30000)
        expect(sc["lease_result"].get("outcome") == "renewed", "outcome is not renewed")
        expect(sc["lease"].get("held_by_caller") is True, "held_by_caller")

    def lease_release(self, facts):
        sc = self.lease("release", facts)
        expect(sc["lease_result"].get("outcome") == "released", "outcome is not released")
        view, _, _ = self.client.call("status", {"holder_id": self.cfg.holder_id})
        expect((view.get("lease") or {}).get("held_by_caller") is False, "status still shows the lease")

    # --- effects (section 6.4, 6.5, 6.7) ---------------------------------------------------
    def effect(self, tool, action, frame_id, extra=None):
        args = {"holder_id": self.cfg.holder_id, "frame_id": frame_id,
                "operation_id": f"acc-{self.cfg.run_id}-{secrets.token_hex(6)}", "action": action}
        args.update(extra or {})
        sc, is_error, _ = self.client.call(tool, args)
        return args, sc, is_error

    def check_effect(self, args, sc, is_error, facts):
        measured = sc.get("measured") or {}
        facts.update(events_posted=sc.get("events_posted"), target_app=measured.get("target_app"),
                     frontmost_app=measured.get("frontmost_app"), global_point=measured.get("global_point"))
        expect(not is_error, f"{refusal(sc)} {sc.get('details')}")
        expect(sc.get("status") == "completed", "status is not completed")
        expect(sc.get("replayed") is False, "replayed")
        expect(sc.get("operation_id") == args["operation_id"] and sc.get("frame_id") == args["frame_id"],
               "operation_id or frame_id not echoed")
        expect(sc.get("events_posted", 0) >= 1, "no events posted")

    def pointer_move(self, facts):
        frame = self.take_screenshot({})
        size = frame["output_pixel_size"]
        target = frame.get("pointer_position") or {"x": size["width"] // 2, "y": size["height"] // 2}
        args, sc, is_error = self.effect("pointer", {"type": "move", "x": target["x"], "y": target["y"]},
                                         frame["frame_id"], {"permitted_apps": self.cfg.permitted_apps})
        self.check_effect(args, sc, is_error, facts)
        expect(facts["global_point"] is not None, "measured.global_point is null")

    def type_text(self, facts):
        before = self.take_screenshot({})
        nonce = f"deskhand-acceptance-{secrets.token_hex(6)}"
        args, sc, is_error = self.effect("keyboard", {"type": "type", "text": nonce}, before["frame_id"],
                                         {"permitted_apps": self.cfg.permitted_apps})
        facts["nonce"] = nonce
        self.check_effect(args, sc, is_error, facts)
        expect((facts["target_app"] or {}).get("bundle_id") in self.cfg.permitted_apps, "target_app")
        after = self.take_screenshot({})
        facts["screen_changed"] = after["sha256"] != before["sha256"]

    # --- negative cases (sections 2.3, 2.4, 9.4, 9.5, 8.3) -----------------------------------
    def expect_status(self, resp, status, facts, rpc_code=None):
        facts.update(http_status=resp.status, rpc_code=resp.rpc_error_code())
        expect(resp.status == status, f"HTTP {resp.status}, want {status}")
        if rpc_code is not None:
            expect(facts["rpc_code"] == rpc_code, f"rpc code {facts['rpc_code']}, want {rpc_code}")

    def neg_missing_token(self, facts):
        resp = self.client.rpc("server/discover", header_overrides={"Authorization": None})
        self.expect_status(resp, 401, facts)
        expect(resp.headers.get("www-authenticate", "").startswith("Bearer"), "WWW-Authenticate")

    def neg_wrong_token(self, facts):
        resp = self.client.rpc("server/discover", token=secrets.token_urlsafe(32))
        self.expect_status(resp, 401, facts)
        expect(resp.headers.get("www-authenticate", "").startswith("Bearer"), "WWW-Authenticate")

    def _method(self, http_method, facts):
        headers, _ = build_request("server/discover", {}, host=self.cfg.host, port=self.cfg.port,
                                   token=self.client.token)
        resp = self.client.send(http_method, headers)
        self.expect_status(resp, 405, facts)
        facts["allow"] = resp.headers.get("allow")
        expect(facts["allow"] == "POST", "Allow header")

    def neg_get(self, facts):
        self._method("GET", facts)

    def neg_delete(self, facts):
        self._method("DELETE", facts)

    def neg_wrong_host(self, facts):
        resp = self.client.rpc("server/discover",
                               header_overrides={"Host": f"deskhand-acceptance.invalid:{self.cfg.port}"})
        self.expect_status(resp, 421, facts)

    def neg_unsupported_version(self, facts):
        self.expect_status(self.client.rpc("server/discover", version="2025-06-18"), 400, facts, -32022)

    def neg_method_mismatch(self, facts):
        resp = self.client.rpc("server/discover", header_overrides={"Mcp-Method": "tools/list"})
        self.expect_status(resp, 400, facts, -32020)

    def neg_name_mismatch(self, facts):
        resp = self.client.rpc("tools/call", {"name": "status", "arguments": {}},
                               header_overrides={"Mcp-Name": "displays"})
        self.expect_status(resp, 400, facts, -32020)

    def neg_missing_header(self, facts):
        resp = self.client.rpc("server/discover", header_overrides={"MCP-Protocol-Version": None})
        self.expect_status(resp, 400, facts, -32020)

    def expect_tool_error(self, tool, args, code, facts):
        sc, is_error, _ = self.client.call(tool, args)
        facts.update(code=sc.get("code"), details=sc.get("details"), operation_present="operation" in sc)
        expect(is_error and sc.get("code") == code, f"{refusal(sc)}, want {code}")
        return sc

    def bogus_effect_args(self):
        return {"holder_id": self.cfg.holder_id, "frame_id": "frm_" + secrets.token_urlsafe(16)[:22],
                "operation_id": f"acc-{self.cfg.run_id}-{secrets.token_hex(6)}",
                "action": {"type": "move", "x": 0, "y": 0}}

    def neg_no_lease(self, facts):
        # Order of refusals (9.5): lease (step 6) comes before the frame (step 9).
        self.expect_tool_error("pointer", self.bogus_effect_args(), "lease_not_held", facts)

    def neg_stale_frame(self, facts):
        sc = self.expect_tool_error("pointer", self.bogus_effect_args(), "stale_frame", facts)
        expect(sc["details"].get("reason") == "unknown", "details.reason is not unknown")

    # --- driver ------------------------------------------------------------------------------
    def execute(self, selected):
        for name in PRE_LEASE:
            if name in selected:
                self.run_check(name, getattr(self, name))
        under = [n for n in UNDER_LEASE if n in selected]
        if "lease" not in selected and not under:
            return
        held = False
        try:  # the acquire is inside, so a SIGTERM during it still reaches the release
            held = self.run_check("lease_acquire", self.lease_acquire)
            for name in under:
                if held:
                    self.run_check(name, getattr(self, name))
                else:
                    self.run_check(name, lambda facts: expect(False, "lease not acquired"))
            if held:
                self.run_check("lease_renew", self.lease_renew)
        finally:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)  # a second SIGTERM must not skip the release
            # Release even when acquire looked wrong (e.g. "renewed"): release is safe to repeat (5.1).
            if not (held and self.run_check("lease_release", self.lease_release)):
                try:  # best effort; the TTL ends the lease anyway
                    self.client.call("lease", {"op": "release", "holder_id": self.cfg.holder_id})
                except Exception:
                    pass


def select_checks(spec):
    if not spec or spec == "default":
        return list(DEFAULT_CHECKS)
    if spec == "all":
        return list(ALL_CHECKS)
    names = [n.strip() for n in spec.split(",") if n.strip()]
    if not names:
        raise ValueError("no checks selected")
    unknown = [n for n in names if n not in ALL_CHECKS]
    if unknown:
        raise ValueError(f"unknown checks: {', '.join(unknown)}")
    return names


def main(argv=None, env=None, out=None):
    env = os.environ if env is None else env
    out = out or sys.stdout
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--checks", default=env.get("DESKHAND_CHECKS", "default"),
                        help="comma-separated names, 'default' or 'all'; choices: " + ", ".join(ALL_CHECKS))
    args = parser.parse_args(argv)
    redact = Redactor()
    try:
        selected = select_checks(args.checks)
        cfg = Config(env)
        with open(cfg.token_file, encoding="utf-8") as f:
            token = f.read().strip()
        redact.add(token)
        if not TOKEN_RE.match(token):  # never echo the content
            raise ValueError("token file content is not a valid bearer token (one line of visible ASCII)")
        client = Client(cfg, token)
    except (OSError, ValueError, ssl.SSLError) as exc:
        out.write(redact(json.dumps({"config_error": f"{type(exc).__name__}: {exc}"})) + "\n")
        return 2
    run = Run(cfg, client, out, redact)
    started = time.time()
    terminated = False

    def on_sigterm(signum, frame):
        raise Terminated()

    previous = signal.signal(signal.SIGTERM, on_sigterm)
    try:
        run.execute(selected)
    except Terminated:  # the lease was released by the finally in execute
        terminated = True
    finally:
        signal.signal(signal.SIGTERM, previous)
    failed = [r["check"] for r in run.results if not r["ok"]]
    ok = not failed and not terminated and bool(run.results)
    run.emit({"summary": {"mac": cfg.mac, "host": cfg.host, "port": cfg.port, "node": cfg.node,
                          "run_id": cfg.run_id, "holder_id": cfg.holder_id, "checks": len(run.results),
                          "failed": failed, "terminated": terminated, "ok": ok,
                          "client_sha256": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
                          "seconds": round(time.time() - started, 2)}})
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
