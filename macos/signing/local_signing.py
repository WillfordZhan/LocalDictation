#!/usr/bin/env python3
"""LocalDictation-only persistent signing; never changes trust or search lists."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import stat
import subprocess
import sys

HERE = Path(__file__).resolve().parent
BUNDLE_ID = "local.willford.dictation"

def helper_path():
    source = HERE / "LocalSigningKeychain.swift"
    binary = HERE / "keychain-helper"
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        run(["/usr/bin/swiftc", source, "-o", binary], timeout=30)
    return binary

def run(args, **kwargs):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{Path(str(args[0])).name} exited {result.returncode}: {result.stderr.strip()}")
    return result.stdout

def keychain_preferences():
    return {"search_list": run(["/usr/bin/security", "list-keychains", "-d", "user"]),
            "default_keychain": run(["/usr/bin/security", "default-keychain", "-d", "user"])}

def private_write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(data)

def check_private_directory(directory):
    if directory.is_symlink():
        raise RuntimeError("Signing directory must not be a symlink")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    permissions = directory.stat()
    if permissions.st_uid != os.getuid() or stat.S_IMODE(permissions.st_mode) & 0o077:
        raise RuntimeError("Signing directory must be owned by this user and have mode 0700")

def initialize(directory):
    manifest = directory / "identity.json"
    keychain = directory / "LocalDictationSigning.keychain-db"
    if manifest.exists():
        if not keychain.exists(): raise RuntimeError("Identity manifest exists without keychain; do not generate replacement")
        print("Existing stable identity preserved:", json.loads(manifest.read_text())["certificate_sha1"])
        return
    if any((directory / name).exists() for name in ["LocalDictationSigning.keychain-db", "keychain-password", "signer.pem"]):
        raise RuntimeError("Partial identity already exists; inspect it instead of rotating the signing key")
    before = keychain_preferences()
    password = directory / "keychain-password"
    private_write(password, secrets.token_hex(32))
    config = directory / "certificate.cnf"
    private_write(config, """[req]
prompt = no
distinguished_name = dn
x509_extensions = signing
[dn]
CN = LocalDictation Local Signing
O = LocalDictation on this Mac
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
    key = directory / "private-key.pem"
    certificate = directory / "signer.pem"
    p12 = directory / "identity.p12"
    openssl = shutil.which("openssl")
    if not openssl: raise RuntimeError("OpenSSL is required to prepare the local signing certificate")
    old_mask = os.umask(0o077)
    try:
        run([openssl, "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes", "-sha256", "-days", "3650", "-config", config, "-keyout", key, "-out", certificate], timeout=30)
        # AES/SHA-256 avoids OpenSSL 3's legacy RC2 while using PKCS#12 that
        # SecPKCS12Import can read. The passphrase never appears in argv.
        run([openssl, "pkcs12", "-export", "-inkey", key, "-in", certificate, "-name", "LocalDictation Local Signing", "-keypbe", "AES-256-CBC", "-certpbe", "AES-256-CBC", "-macalg", "SHA256", "-passout", "file:" + str(password), "-out", p12], timeout=15)
        output = run([helper_path(), "initialize", directory], timeout=30)
        certificate_der = subprocess.run([openssl, "x509", "-in", str(certificate), "-outform", "DER"], capture_output=True, check=True).stdout
        fingerprint = hashlib.sha1(certificate_der).hexdigest().upper()
        requirement = f'identifier "{BUNDLE_ID}" and certificate leaf = H"{fingerprint}"'
        after = keychain_preferences()
        if after != before:
            raise RuntimeError("Unexpected keychain preference change; stopped without modifying/restoring search lists")
        record = {"created_at": datetime.datetime.now().astimezone().isoformat(), "certificate_sha1": fingerprint,
                  "requirement": requirement, "keychain_path": str(keychain), "keychain_preferences_unchanged": True,
                  "scope": "Local development signing only; no trust-settings or TCC modifications"}
        private_write(manifest, json.dumps(record, indent=2) + "\n")
        print(output.strip()); print("Stable leaf certificate SHA-1:", fingerprint)
    finally:
        os.umask(old_mask)
        # Never retain temporary plaintext or wrapped private-key files. If
        # initialization failed, leave metadata/keychain for explicit inspection
        # rather than silently creating a different identity on a retry.
        key.unlink(missing_ok=True); p12.unlink(missing_ok=True)
        if keychain_preferences() != before:
            print("CHECK REQUIRED: keychain preferences differ; no automatic global write attempted", file=sys.stderr)

def sign(directory, app):
    manifest = json.loads((directory / "identity.json").read_text())
    app = app.resolve(strict=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise RuntimeError("This identity wrapper only signs LocalDictation")
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    if subprocess.run(["/usr/sbin/lsof", "-t", str(executable)], capture_output=True).returncode == 0:
        raise RuntimeError("Refusing to sign an executable currently in use; build into staging")
    before = keychain_preferences()
    try:
        print(run([helper_path(), "sign", directory, app], timeout=45).strip())
        run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + manifest["requirement"], app], timeout=15)
        print(run(["/usr/bin/codesign", "-d", "-r-", app]).strip())
    finally:
        if keychain_preferences() != before:
            raise RuntimeError("Keychain preferences unexpectedly changed; no global settings restored or overwritten")
    print("Verified stable signed app:", app)

parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=["initialize", "sign"])
parser.add_argument("--directory", type=Path, default=Path.home() / "Library/Application Support/LocalDictation/Signing")
parser.add_argument("--app", type=Path)
args = parser.parse_args()
check_private_directory(args.directory)
if args.mode == "initialize": initialize(args.directory)
else:
    if not args.app: parser.error("--app is required for sign")
    sign(args.directory, args.app)
