import contextlib
import io
import json
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
        spec = job["spec"]
        self.assertEqual(spec["backoffLimit"], 0)
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
        for bad in (["--run-id", "Bad_ID"], ["--run-id", "r1\n"], ["--mac", "other-mac"], ["--port", "0"],
                    ["--node", "a b"], ["--node", "n" * 64], ["--checks", "statsu"], ["--checks", ","]):
            argv = ARGS + bad  # argparse keeps the last value of a repeated flag
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                render.parse_args(argv)

    def test_main_prints_a_json_list(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(render.main(ARGS), 0)
        self.assertEqual(json.loads(out.getvalue()), {"apiVersion": "v1", "kind": "List", "items": self.manifests()})

if __name__ == "__main__":
    unittest.main()
