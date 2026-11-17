#!/usr/bin/env python3
"""Print a ConfigMap and a Job (YAML) that run the deskhand acceptance client once.

One invocation renders one run: one node, one target Mac, one run ID. Pipe the output to
`kubectl apply -f -`. See acceptance/README.md for the placeholders that still depend on
birbhomes gates (Service port, secret names).
"""

import argparse
import hashlib
import importlib.util
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / "deskhand_acceptance.py"
NAMESPACE = "forge"
MACS = ("lunus-macbook-pro", "m1max2021")  # contract section 2.1
DEFAULT_IMAGE = "python:3.13.5-slim"  # pin a digest at deploy time: python:3.13.5-slim@sha256:...
MOUNT = "/etc/deskhand-acceptance"
RUN_ID_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$")
NODE_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$")


def load_client():
    spec = importlib.util.spec_from_file_location("deskhand_acceptance", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build(args):
    script = SCRIPT.read_text(encoding="utf-8")
    name = f"deskhand-acceptance-{args.run_id}"
    host = args.host or f"deskhand-{args.mac}.{NAMESPACE}.svc"
    labels = {"app.kubernetes.io/name": "deskhand-acceptance", "birb.homes/acceptance-run": args.run_id}
    configmap = {
        "apiVersion": "v1", "kind": "ConfigMap",
        "metadata": {"name": f"{name}-script", "namespace": NAMESPACE, "labels": labels},
        "immutable": True,
        "data": {"deskhand_acceptance.py": script},
    }
    env = {
        "DESKHAND_HOST": host, "DESKHAND_PORT": str(args.port), "DESKHAND_MAC": args.mac,
        "DESKHAND_RUN_ID": args.run_id, "DESKHAND_CHECKS": args.checks,
        "DESKHAND_CREDENTIALS_DIR": MOUNT,
        # A run makes about 26 requests; a stalled one meets the deadline, and SIGTERM releases the lease.
        "DESKHAND_TIMEOUT_S": "10",
    }
    if args.permitted_apps:
        env["DESKHAND_PERMITTED_APPS"] = args.permitted_apps
    container = {
        "name": "acceptance",
        "image": args.image,
        "imagePullPolicy": "IfNotPresent",
        "command": ["python3", "-I", "-B", "-u", "/opt/acceptance/deskhand_acceptance.py"],
        "env": [{"name": k, "value": v} for k, v in env.items()]
        + [{"name": "NODE_NAME", "valueFrom": {"fieldRef": {"fieldPath": "spec.nodeName"}}}],
        "resources": {"requests": {"cpu": "50m", "memory": "64Mi"},
                      "limits": {"cpu": "500m", "memory": "256Mi"}},
        "securityContext": {
            "allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
            "capabilities": {"drop": ["ALL"]}, "privileged": False,
        },
        "volumeMounts": [
            {"name": "script", "mountPath": "/opt/acceptance", "readOnly": True},
            {"name": "tls", "mountPath": f"{MOUNT}/tls", "readOnly": True},
            {"name": "token", "mountPath": f"{MOUNT}/token", "readOnly": True},
        ],
    }
    secret_files = [{"key": k, "path": k} for k in ("tls.crt", "tls.key", "ca.crt")]
    pod = {
        "metadata": {"labels": {**labels, "birb.homes/deskhand-egress": "true"},
                     "annotations": {"birb.homes/acceptance-client-sha256": hashlib.sha256(
                         script.encode()).hexdigest()}},
        "spec": {
            "restartPolicy": "Never",
            "terminationGracePeriodSeconds": 30,
            "automountServiceAccountToken": False,
            "enableServiceLinks": False,
            "nodeSelector": {"kubernetes.io/hostname": args.node},
            "securityContext": {"runAsNonRoot": True, "runAsUser": 65534, "runAsGroup": 65534,
                                "fsGroup": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [container],
            "volumes": [
                {"name": "script", "configMap": {"name": f"{name}-script", "defaultMode": 0o444}},
                {"name": "tls", "secret": {"secretName": args.tls_secret, "items": secret_files,
                                           "defaultMode": 0o440}},
                {"name": "token", "secret": {"secretName": args.token_secret,
                                             "items": [{"key": args.token_key, "path": "token"}],
                                             "defaultMode": 0o440}},
            ],
        },
    }
    job = {
        "apiVersion": "batch/v1", "kind": "Job",
        "metadata": {"name": name, "namespace": NAMESPACE, "labels": labels},
        "spec": {"backoffLimit": 0, "activeDeadlineSeconds": args.deadline,
                 "ttlSecondsAfterFinished": 86400, "template": pod},
    }
    return [configmap, job]


def scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value)  # a JSON string is a valid YAML double-quoted scalar


def to_yaml(value, indent=0):
    """Minimal YAML emitter for dicts, lists, strings, ints and bools. Multi-line strings use |."""
    pad = " " * indent
    lines = []
    items = value.items() if isinstance(value, dict) else ((None, v) for v in value)
    for key, item in items:
        prefix = f"{pad}{key}:" if key is not None else f"{pad}-"
        if isinstance(item, (dict, list)) and item:
            if key is None:
                nested = to_yaml(item, indent + 2).split("\n")
                lines.append(f"{pad}- {nested[0].lstrip()}")
                lines.extend(nested[1:])
            else:
                lines.append(prefix)
                lines.append(to_yaml(item, indent + 2))
        elif isinstance(item, str) and "\n" in item and all(c == "\n" or " " <= c <= "~" for c in item):
            # Explicit indentation indicator, so a first line that starts with spaces stays literal.
            lines.append(f"{prefix} |2{'' if item.endswith(chr(10)) else '-'}")
            lines.extend(f"{pad}  {line}" if line else "" for line in item.rstrip("\n").split("\n"))
        elif isinstance(item, (dict, list)):
            lines.append(f"{prefix} {'{}' if isinstance(item, dict) else '[]'}")
        else:
            lines.append(f"{prefix} {scalar(item)}")
    return "\n".join(lines)


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--node", required=True, help="kubernetes.io/hostname of the node to run on")
    p.add_argument("--mac", required=True, choices=MACS)
    p.add_argument("--run-id", required=True, help="lowercase letters, digits and '-', at most 20")
    p.add_argument("--port", required=True, type=int, help="deskhand Service port (birbhomes-r-5elb)")
    p.add_argument("--host", help="Service DNS name; default deskhand-<mac>.forge.svc")
    p.add_argument("--checks", default="default", help="passed to the client as DESKHAND_CHECKS")
    p.add_argument("--permitted-apps", help="DESKHAND_PERMITTED_APPS for pointer_move and type_text")
    p.add_argument("--image", default=DEFAULT_IMAGE)
    p.add_argument("--tls-secret", default="deskhand-acceptance-client-tls",
                   help="Secret with tls.crt, tls.key and ca.crt (placeholder)")
    p.add_argument("--token-secret", help="Secret with the Mac's token; default deskhand-token-<mac> (placeholder)")
    p.add_argument("--token-key", default="token")
    p.add_argument("--deadline", type=int, default=600, help="activeDeadlineSeconds (at least 60)")
    args = p.parse_args(argv)
    if not RUN_ID_RE.match(args.run_id):
        p.error("--run-id must match " + RUN_ID_RE.pattern)
    if not NODE_RE.match(args.node):
        p.error("--node is not a valid node name")
    if args.deadline < 60:
        p.error("--deadline must be at least 60")
    if not 1 <= args.port <= 65535:
        p.error("--port must be 1 to 65535")
    try:
        load_client().select_checks(args.checks)
    except ValueError as exc:
        p.error(f"--checks: {exc}")
    args.token_secret = args.token_secret or f"deskhand-token-{args.mac}"
    return args


def main(argv=None):
    docs = build(parse_args(argv))
    sys.stdout.write("\n".join("---\n" + to_yaml(d) for d in docs) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
