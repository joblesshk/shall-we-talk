#!/usr/bin/env python3
"""Check tracked publication files and ZIP text members without printing their content."""
import hashlib
import ipaddress
import re
import subprocess
import sys
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
failures = []

# Hashes of case-insensitive private identifier tokens, so the denylist itself
# does not republish an operator identifier. Scan binary payloads as well as text.
PRIVATE_TOKEN_HASHES = {
    "40040f36e47a933cc902ed7cdddba4c3052555e3e7f1d86b0e32d62f99038179",
}


def check(name, data):
    if any(hashlib.sha256(token.lower()).hexdigest() in PRIVATE_TOKEN_HASHES
           for token in re.findall(rb"[A-Za-z][A-Za-z0-9_-]*", data)):
        failures.append((name, "private identifier token"))
    if b"\0" in data[:8192]:
        return
    text = data.decode("utf-8", errors="replace")
    if re.search(r"/(?:Users|home)/[A-Za-z][^/\s]*", text):
        failures.append((name, "personal home path"))
    for value in re.findall(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])", text):
        try:
            addr = ipaddress.ip_address(value)
        except ValueError:
            continue
        if addr.is_private and not addr.is_loopback and not addr.is_unspecified and not any(addr in block for block in (ipaddress.ip_network("192.0.2.0/24"), ipaddress.ip_network("198.51.100.0/24"), ipaddress.ip_network("203.0.113.0/24"))):
            failures.append((name, "private IP address"))

for rel in filter(None, paths):
    path = root / rel
    if not path.is_file():
        continue
    if path.suffix == ".zip":
        with zipfile.ZipFile(path) as archive:
            for member in archive.infolist():
                if not member.is_dir():
                    check(rel + "!" + member.filename, archive.read(member))
    else:
        check(rel, path.read_bytes())
for name, rule in sorted(set(failures)):
    print(f"FAIL: {name}: {rule}")
if failures:
    sys.exit(1)
print("Publication checks passed (tracked text and ZIP members). Run a credential scanner separately.")
