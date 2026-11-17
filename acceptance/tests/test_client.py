import io
import json
import os
import struct
import tempfile
import unittest
import zlib

from support import client as dh

TOKEN = "s3cret-token-value"


def png(width, height):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    raw = b"".join(b"\x00" + b"\x00\x00\x00" * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def jpeg(width, height):
    """SOI, an APP0 stub and a baseline SOF0 header: enough for image_size, not a decodable image."""
    return (b"\xff\xd8" + b"\xff\xe0" + struct.pack(">H", 4) + b"\x00\x00"
            + b"\xff\xc0" + struct.pack(">HBHHB", 11, 8, height, width, 3) + b"\x00" * 8 + b"\xff\xd9")


class BuildRequestTests(unittest.TestCase):
    def build(self, method, params, **kw):
        headers, body = dh.build_request(method, params, host="deskhand-m1max2021.forge.svc", port=8443,
                                         token=TOKEN, **kw)
        return headers, json.loads(body)

    def test_headers_match_body(self):
        headers, body = self.build("tools/call", {"name": "status", "arguments": {}})
        self.assertEqual(headers["Host"], "deskhand-m1max2021.forge.svc:8443")
        self.assertEqual(headers["Authorization"], f"Bearer {TOKEN}")
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertIn("application/json", headers["Accept"])
        self.assertIn("text/event-stream", headers["Accept"])
        self.assertEqual(headers["MCP-Protocol-Version"], "2026-07-28")
        self.assertEqual(headers["Mcp-Method"], body["method"])
        self.assertEqual(headers["Mcp-Name"], body["params"]["name"])
        self.assertEqual(body["jsonrpc"], "2.0")
        self.assertEqual(body["params"]["_meta"], {"io.modelcontextprotocol/protocolVersion": "2026-07-28"})

    def test_no_mcp_name_outside_tools_call(self):
        headers, body = self.build("server/discover", {})
        self.assertNotIn("Mcp-Name", headers)
        self.assertEqual(headers["Mcp-Method"], "server/discover")

    def test_overrides_replace_and_drop(self):
        headers, _ = self.build("server/discover", {}, header_overrides={
            "MCP-Protocol-Version": None, "Mcp-Method": "tools/list"})
        self.assertNotIn("MCP-Protocol-Version", headers)
        self.assertEqual(headers["Mcp-Method"], "tools/list")

    def test_version_goes_to_header_and_body(self):
        headers, body = self.build("server/discover", {}, version="2025-06-18")
        self.assertEqual(headers["MCP-Protocol-Version"], "2025-06-18")
        self.assertEqual(body["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"], "2025-06-18")


class ResponseTests(unittest.TestCase):
    def test_rpc_error_code(self):
        resp = dh.Response(400, {}, json.dumps({"jsonrpc": "2.0", "id": 1,
                                                "error": {"code": -32020, "message": "x"}}).encode())
        self.assertEqual(resp.rpc_error_code(), -32020)
        self.assertIsNone(dh.Response(401, {}, b"").rpc_error_code())
        self.assertIsNone(dh.Response(400, {}, b"not json").rpc_error_code())

    def test_tool_result(self):
        result = {"resultType": "complete", "isError": True, "structuredContent": {"code": "busy"},
                  "content": [{"type": "text", "text": "{}"}]}
        resp = dh.Response(200, {}, json.dumps({"jsonrpc": "2.0", "id": 1, "result": result}).encode())
        sc, is_error, _ = resp.tool_result()
        self.assertTrue(is_error)
        self.assertEqual(sc["code"], "busy")

    def test_tool_result_rejects_rpc_error(self):
        with self.assertRaises(dh.CheckFailed):
            dh.Response(400, {}, b'{"error":{"code":-32020}}').tool_result()

    def test_image_size(self):
        self.assertEqual(dh.image_size(png(5, 3), "image/png"), (5, 3))
        self.assertEqual(dh.image_size(jpeg(9, 7), "image/jpeg"), (9, 7))
        self.assertIsNone(dh.image_size(b"junk", "image/jpeg"))


class SelectionTests(unittest.TestCase):
    def test_default_excludes_operator_checks(self):
        self.assertNotIn("type_text", dh.select_checks("default"))
        self.assertNotIn("pointer_move", dh.select_checks("default"))
        self.assertIn("type_text", dh.select_checks("all"))
        self.assertEqual(dh.select_checks("status, lease"), ["status", "lease"])
        for bad in ("status,nope", ",", " , "):
            with self.assertRaises(ValueError):
                dh.select_checks(bad)

    def test_refusal_names_preconditions(self):
        self.assertIn("state is disarmed", dh.refusal({"code": "disarmed", "state": "disarmed"}))
        self.assertIn("another holder", dh.refusal({"code": "lease_held_by_other", "state": "ok"}))
        self.assertEqual(dh.refusal({"code": "busy", "state": "ok"}), "got busy")


class RedactionTests(unittest.TestCase):
    def test_redactor(self):
        redact = dh.Redactor()
        redact.add(TOKEN)
        redact.add("")
        self.assertEqual(redact(f"Bearer {TOKEN} and {TOKEN}"), "Bearer [REDACTED] and [REDACTED]")
        quoted = dh.Redactor()
        quoted.add('a"b\\c')
        self.assertNotIn("b", quoted(json.dumps({"error": 'x a"b\\c'})))

    def config_error(self, token_text, **env):
        with tempfile.TemporaryDirectory() as tmp:
            token_file = os.path.join(tmp, "token")
            with open(token_file, "w") as f:
                f.write(token_text)
            out = io.StringIO()
            env = {"DESKHAND_HOST": "h", "DESKHAND_PORT": "1", "DESKHAND_MAC": "m",
                   "DESKHAND_TOKEN_FILE": token_file, "DESKHAND_CA_CERT": os.path.join(tmp, "missing"), **env}
            self.assertEqual(dh.main([], env=env, out=out), 2)
            return out.getvalue()

    def test_config_error_does_not_print_token(self):
        text = self.config_error(TOKEN + "\n")
        self.assertIn("config_error", text)
        self.assertNotIn(TOKEN, text)

    def test_malformed_token_is_refused_without_echo(self):
        # http.client would echo a header value with a control character in its exception.
        text = self.config_error("abc\ndef-secret\n")
        self.assertIn("not a valid bearer token", text)
        self.assertNotIn("secret", text)

    def test_bad_handles_are_config_errors(self):
        self.assertIn("alphabet", self.config_error(TOKEN, DESKHAND_RUN_ID="has space"))
        self.assertIn("alphabet", self.config_error(TOKEN, DESKHAND_HOLDER_ID="x" * 129))

    def test_emit_redacts(self):
        out = io.StringIO()
        redact = dh.Redactor()
        redact.add(TOKEN)
        run = dh.Run(None, None, out, redact)
        run.run_check("x", lambda facts: (_ for _ in ()).throw(RuntimeError(f"boom {TOKEN}")))
        self.assertNotIn(TOKEN, out.getvalue())
        self.assertFalse(json.loads(out.getvalue())["ok"])


if __name__ == "__main__":
    unittest.main()
