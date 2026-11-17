import contextlib
import io
import json
import os
import shutil
import subprocess
import unittest

from support import render

ARGS = ["--node", "infra-control-master", "--mac", "m1max2021", "--run-id", "r1", "--port", "8443"]


class RenderTests(unittest.TestCase):
    def manifests(self, extra=()):
        return render.build(render.parse_args(ARGS + list(extra)))

    def test_configmap_carries_the_client(self):
        configmap, job = self.manifests()
        self.assertEqual(configmap["kind"], "ConfigMap")
        self.assertEqual(configmap["data"]["deskhand_acceptance.py"], render.SCRIPT.read_text())
        self.assertIs(configmap["immutable"], True)
        volume = job["spec"]["template"]["spec"]["volumes"][0]
        self.assertEqual(volume["configMap"]["name"], configmap["metadata"]["name"])

    def test_job_policy(self):
        _, job = self.manifests()
        self.assertEqual(job["metadata"]["namespace"], "forge")
        self.assertEqual(job["metadata"]["name"], "deskhand-acceptance-r1")
        spec = job["spec"]
        self.assertEqual(spec["backoffLimit"], 0)
        self.assertIn("activeDeadlineSeconds", spec)
        self.assertIn("ttlSecondsAfterFinished", spec)
        pod = spec["template"]
        self.assertEqual(pod["metadata"]["labels"]["birb.homes/deskhand-egress"], "true")
        ps = pod["spec"]
        self.assertEqual(ps["restartPolicy"], "Never")
        self.assertIn("birb.homes/acceptance-client-sha256", pod["metadata"]["annotations"])
        self.assertIs(ps["automountServiceAccountToken"], False)
        self.assertEqual(ps["nodeSelector"], {"kubernetes.io/hostname": "infra-control-master"})
        self.assertIs(ps["securityContext"]["runAsNonRoot"], True)
        self.assertEqual(ps["securityContext"]["seccompProfile"], {"type": "RuntimeDefault"})
        (container,) = ps["containers"]
        sc = container["securityContext"]
        self.assertIs(sc["readOnlyRootFilesystem"], True)
        self.assertIs(sc["allowPrivilegeEscalation"], False)
        self.assertEqual(sc["capabilities"], {"drop": ["ALL"]})
        self.assertIn("limits", container["resources"])
        self.assertTrue(all(m["readOnly"] for m in container["volumeMounts"]))

    def test_secrets_are_volumes_not_env(self):
        _, job = self.manifests(["--tls-secret", "tls-x", "--token-secret", "tok-y"])
        ps = job["spec"]["template"]["spec"]
        secrets = {v["secret"]["secretName"] for v in ps["volumes"] if "secret" in v}
        self.assertEqual(secrets, {"tls-x", "tok-y"})
        for env in ps["containers"][0]["env"]:
            self.assertNotIn("secretKeyRef", env.get("valueFrom", {}))
        env = {e["name"]: e.get("value") for e in ps["containers"][0]["env"]}
        self.assertEqual(env["DESKHAND_HOST"], "deskhand-m1max2021.forge.svc")
        self.assertEqual(env["DESKHAND_PORT"], "8443")
        self.assertEqual(env["DESKHAND_MAC"], "m1max2021")

    def test_rejects_bad_inputs(self):
        for bad in (["--run-id", "Bad_ID"], ["--mac", "other-mac"], ["--port", "0"], ["--node", "a b"],
                    ["--checks", "statsu"], ["--checks", ","]):
            argv = ARGS + bad  # argparse keeps the last value of a repeated flag
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                render.parse_args(argv)

    def test_yaml_emitter(self):
        doc = {"a": 1, "b": True, "c": "x: y", "d": [{"e": "f", "g": []}, "h"], "i": "l1\n  l2\n", "j": {},
               "k": "cr\r\n"}
        self.assertEqual(render.to_yaml(doc), "\n".join([
            "a: 1", "b: true", 'c: "x: y"', "d:", '  - e: "f"', "    g: []", '  - "h"',
            "i: |2", "  l1", "    l2", "j: {}", 'k: "cr\\r\\n"']))

    def test_yaml_parses_to_the_model(self):
        # Ruby's YAML library is an independent parser that GitHub's Ubuntu runners have.
        usable = shutil.which("ruby") and subprocess.run(["ruby", "-ryaml", "-e", "1"],
                                                         capture_output=True).returncode == 0
        if not usable and os.environ.get("DESKHAND_REQUIRE_E2E") != "1":
            self.skipTest("ruby with its yaml library is not available")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            render.main(ARGS)
        parsed = subprocess.run(["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_stream(STDIN.read))"],
                                input=out.getvalue(), capture_output=True, text=True, check=True).stdout
        self.assertEqual(json.loads(parsed), self.manifests())

    def test_main_prints_two_documents(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(render.main(ARGS), 0)
        text = out.getvalue()
        self.assertEqual(text.count("\n---\n") + text.startswith("---\n"), 2)
        self.assertIn('kind: "Job"', text)
        self.assertIn("  deskhand_acceptance.py: |2\n    #!/usr/bin/env python3\n", text)


if __name__ == "__main__":
    unittest.main()
