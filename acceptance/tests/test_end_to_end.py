"""Runs the client against a local fake deskhand that requires mutual TLS and the token.

The fake implements just enough of docs/contract.md (check order of section 2.4, the lease of
section 5, the effect refusals of section 9.5) to exercise the client's wire handling.
"""

import base64
import hashlib
import http.server
import io
import json
import os
import re
import signal
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest

from support import ACCEPTANCE, client as dh, jpeg, make_pki

TOKEN = "e2e-token-value-never-printed"


class FakeDeskhand(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state = None  # set per server

    def log_message(self, *args):
        pass

    def reply(self, status, payload=None, headers=()):
        body = json.dumps(payload).encode() if payload is not None else b""
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def rpc_error(self, status, code, rid=None):
        self.reply(status, {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": "x"}})

    def do_GET(self):
        self.handle_any("GET")

    def do_DELETE(self):
        self.handle_any("DELETE")

    def do_POST(self):
        self.handle_any("POST")

    def handle_any(self, method):
        h = self.headers
        if method != "POST":
            return self.reply(405, headers=[("Allow", "POST")])
        if h.get("Host", "").lower() != f"localhost:{self.server.server_port}":
            return self.reply(421)
        if h.get("Authorization") != f"Bearer {TOKEN}":
            return self.reply(401, headers=[("WWW-Authenticate", 'Bearer realm="deskhand"')])
        msg = json.loads(self.rfile.read(int(h.get("Content-Length", 0))))
        version = h.get("MCP-Protocol-Version")
        if not version or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", version):
            return self.rpc_error(400, -32020, msg["id"])
        if version != dh.PROTOCOL_VERSION:
            return self.rpc_error(400, -32022, msg["id"])
        params = msg["params"]
        if params["_meta"]["io.modelcontextprotocol/protocolVersion"] != version:
            return self.rpc_error(400, -32020, msg["id"])
        if h.get("Mcp-Method") != msg["method"] or (
                msg["method"] == "tools/call" and h.get("Mcp-Name") != params.get("name")):
            return self.rpc_error(400, -32020, msg["id"])
        result = self.dispatch(msg["method"], params)
        self.reply(200, {"jsonrpc": "2.0", "id": msg["id"], "result": result})

    def dispatch(self, method, params):
        if method == "server/discover":
            return {"resultType": "complete", "supportedVersions": [dh.PROTOCOL_VERSION],
                    "capabilities": {"tools": {"listChanged": False}}, "ttlMs": 300000, "cacheScope": "private",
                    "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "deskhand", "version": "0.1.0"}}}
        if method == "tools/list":
            tools = [{"name": n, "title": t, "description": "d", "inputSchema": {}, "outputSchema": {},
                      "annotations": dict(zip(dh.HINTS, hints))} for n, t, hints in dh.TOOLS]
            return {"resultType": "complete", "tools": tools, "ttlMs": 300000, "cacheScope": "private"}
        sc, content = self.tool(params["name"], params.get("arguments", {}))
        content.append({"type": "text", "text": json.dumps(sc)})
        return {"resultType": "complete", "content": content, "structuredContent": sc,
                "isError": "code" in sc}

    def lease_view(self, holder):
        return {"held_by_caller": self.state["holder"] == holder}

    def tool(self, name, args):
        st = self.state
        if name == "status":
            return {"contract_version": dh.CONTRACT_VERSION, "mcp_protocol_version": dh.PROTOCOL_VERSION,
                    "mac": "m1max2021", "state": "ok", "active_states": [], "conditions": [],
                    "lease": self.lease_view(args.get("holder_id"))}, []
        if name == "displays":
            return {"display_config_generation": 1, "displays": [
                {"display_id": 1, "is_main": True, "pixel_size": {"width": 4, "height": 3}}]}, []
        if name == "screenshot":
            st["frames"] += 1
            data = jpeg(4, 3)
            frame_id = f"frm_{st['frames']:022d}"
            st["live"].add(frame_id)
            sc = {"frame_id": frame_id, "sha256": hashlib.sha256(data).hexdigest(), "image_bytes": len(data),
                  "output_pixel_size": {"width": 4, "height": 3}, "format": "jpeg", "mime_type": "image/jpeg",
                  "jpeg_quality": 85,
                  "pointer_position": None, "max_age_ms": 60000}
            return sc, [{"type": "image", "data": base64.b64encode(data).decode(), "mimeType": "image/jpeg"}]
        if name == "lease":
            op, holder = args["op"], args["holder_id"]
            if op == "acquire":
                st["holder"], outcome = holder, "acquired"
            elif op == "renew":
                outcome = "renewed" if st["holder"] == holder else "refused"
            else:
                outcome = "released" if st["holder"] == holder else "not_held"
                st["holder"] = None if outcome == "released" else st["holder"]
            return {"lease_result": {"op": op, "outcome": outcome}, "lease": self.lease_view(holder)}, []
        err = {"state": "ok", "operation_id": args["operation_id"], "message": "m"}
        if st["holder"] != args["holder_id"]:
            return {**err, "code": "lease_not_held"}, []
        if args["frame_id"] not in st["live"]:
            return {**err, "code": "stale_frame", "details": {"reason": "unknown"}}, []
        if name in st["hang_tools"]:
            st["hanging"].set()
            st["unhang"].wait(10)
        if name in st["fail_tools"]:
            return {**err, "code": "user_active", "details": {"idle_ms": 0}}, []
        app = {"bundle_id": "com.apple.TextEdit", "team_id": None, "name": "TextEdit"}
        point = {"x": 1.0, "y": 1.0} if name == "pointer" else None
        return {"operation_id": args["operation_id"], "frame_id": args["frame_id"], "status": "completed",
                "events_posted": 2, "replayed": False, "completed_at": "t",
                "measured": {"frontmost_app": app, "target_app": app, "window_title": None,
                             "global_point": point, "measured_at": "t"}}, []


class QuietServer(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass  # test_wrong_ca_fails_tls aborts the handshake on purpose


class EndToEndTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.pki = make_pki(cls.tmp.name)
        if cls.pki is None:
            cls.tmp.cleanup()
            if os.environ.get("DESKHAND_REQUIRE_E2E") == "1":
                raise RuntimeError("DESKHAND_REQUIRE_E2E=1 but test certificates could not be made")
            raise unittest.SkipTest("openssl CLI missing or could not create test certificates")
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(cls.pki / "server.crt", cls.pki / "server.key")
        ctx.load_verify_locations(cls.pki / "ca.crt")
        ctx.verify_mode = ssl.CERT_REQUIRED
        handler = type("Handler", (FakeDeskhand,), {})
        cls.server = QuietServer(("localhost", 0), handler)
        cls.server.socket = ctx.wrap_socket(cls.server.socket, server_side=True)
        cls.handler = handler
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        token_file = cls.pki / "token"
        token_file.write_text(TOKEN + "\n")
        cls.env = {"DESKHAND_HOST": "localhost", "DESKHAND_PORT": str(cls.server.server_port),
                   "DESKHAND_MAC": "m1max2021", "DESKHAND_CLIENT_CERT": str(cls.pki / "client.crt"),
                   "DESKHAND_CLIENT_KEY": str(cls.pki / "client.key"), "DESKHAND_CA_CERT": str(cls.pki / "ca.crt"),
                   "DESKHAND_TOKEN_FILE": str(token_file), "DESKHAND_RUN_ID": "e2e"}

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.tmp.cleanup()

    def reset_state(self, fail_tools=(), hang_tools=()):
        self.handler.state = {"holder": None, "frames": 0, "live": set(), "fail_tools": set(fail_tools),
                              "hang_tools": set(hang_tools), "hanging": threading.Event(), "unhang": threading.Event()}

    def run_client(self, checks, fail_tools=()):
        self.reset_state(fail_tools)
        out = io.StringIO()
        code = dh.main(["--checks", checks], env=self.env, out=out)
        self.assertNotIn(TOKEN, out.getvalue())
        return code, [json.loads(line) for line in out.getvalue().splitlines()]

    def test_all_checks_pass(self):
        code, records = self.run_client("all")
        failed = [r for r in records if r.get("ok") is False]
        self.assertEqual(failed, [])
        self.assertEqual(code, 0)
        names = [r.get("check") for r in records[:-1]]
        self.assertEqual(set(names), set(dh.ALL_CHECKS) - {"lease"}
                         | {"lease_acquire", "lease_renew", "lease_release"})
        self.assertTrue(records[-1]["summary"]["ok"])
        self.assertIsNone(self.handler.state["holder"])

    def test_lease_released_when_an_effect_fails(self):
        code, records = self.run_client("type_text", fail_tools={"keyboard"})
        self.assertEqual(code, 1)
        by_name = {r.get("check"): r for r in records}
        self.assertFalse(by_name["type_text"]["ok"])
        self.assertTrue(by_name["lease_release"]["ok"])
        self.assertIsNone(self.handler.state["holder"])

    def test_sigterm_releases_the_lease(self):
        self.reset_state(hang_tools={"keyboard"})
        proc = subprocess.Popen([sys.executable, "-I", str(ACCEPTANCE / "deskhand_acceptance.py"),
                                 "--checks", "type_text"], env=self.env, stdout=subprocess.PIPE, text=True)
        try:
            self.assertTrue(self.handler.state["hanging"].wait(10), "client never reached the keyboard call")
            self.assertIsNotNone(self.handler.state["holder"])
            proc.send_signal(signal.SIGTERM)
            out, _ = proc.communicate(timeout=10)
        finally:
            self.handler.state["unhang"].set()
            if proc.poll() is None:
                proc.kill()
                proc.wait()
        self.assertEqual(proc.returncode, 1)
        self.assertIsNone(self.handler.state["holder"])
        summary = json.loads(out.splitlines()[-1])["summary"]
        self.assertTrue(summary["terminated"])
        self.assertNotIn(TOKEN, out)

    def test_wrong_ca_fails_tls(self):
        env = dict(self.env, DESKHAND_CA_CERT=str(self.pki / "client.crt"))
        out = io.StringIO()
        self.assertEqual(dh.main(["--checks", "discover"], env=env, out=out), 1)
        self.assertIn("SSL", json.loads(out.getvalue().splitlines()[0])["error"])
        self.assertNotIn(TOKEN, out.getvalue())


if __name__ == "__main__":
    unittest.main()
