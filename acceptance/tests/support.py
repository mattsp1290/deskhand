"""Shared helpers for the acceptance tests: module loading, a JPEG header stub and throwaway certificates."""

import importlib.util
import pathlib
import shutil
import struct
import subprocess

ACCEPTANCE = pathlib.Path(__file__).resolve().parent.parent


def load(filename, name):
    spec = importlib.util.spec_from_file_location(name, ACCEPTANCE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


client = load("deskhand_acceptance.py", "deskhand_acceptance")
render = load("render-job.py", "render_job")


def jpeg(width, height):
    """SOI, an APP0 stub and a baseline SOF0 header: enough for image_size, not a decodable image."""
    return (b"\xff\xd8" + b"\xff\xe0" + struct.pack(">H", 4) + b"\x00\x00"
            + b"\xff\xc0" + struct.pack(">HBHHB", 11, 8, height, width, 3) + b"\x00" * 8 + b"\xff\xd9")


def make_pki(directory):
    """Create a CA, a server cert for localhost and a client cert with the openssl CLI.

    Uses only `ecparam`, `req -new` and `x509 -req -extfile`, which OpenSSL and LibreSSL both
    support. Returns None when openssl is missing or fails, so the caller can skip with a reason.
    """
    if not shutil.which("openssl"):
        return None
    d = pathlib.Path(directory)
    exts = {
        "ca": "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n",
        "server": "basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n",
        "client": "basicConstraints=CA:FALSE\nextendedKeyUsage=clientAuth\n",
    }

    def run(*args):
        subprocess.run(["openssl", *args], check=True, capture_output=True)

    try:
        for serial, (name, ext) in enumerate(exts.items(), start=1):
            (d / f"{name}.ext").write_text(ext)
            run("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(d / f"{name}.key"))
            run("req", "-new", "-key", str(d / f"{name}.key"), "-subj", f"/CN=acceptance-{name}",
                "-out", str(d / f"{name}.csr"))
            if name == "ca":
                signer = ["-signkey", str(d / "ca.key")]
            else:
                signer = ["-CA", str(d / "ca.crt"), "-CAkey", str(d / "ca.key"), "-set_serial", str(serial)]
            run("x509", "-req", "-in", str(d / f"{name}.csr"), *signer, "-days", "2", "-sha256",
                "-extfile", str(d / f"{name}.ext"), "-out", str(d / f"{name}.crt"))
    except (subprocess.CalledProcessError, OSError):
        return None
    return d
