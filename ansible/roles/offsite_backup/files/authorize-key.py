#!/usr/bin/env python3
"""Runs on atlas (TrueNAS). Adds one authorized_keys line to root through the middleware,
which is the copy TrueNAS keeps across updates. Prints "changed" or "ok".
Usage: authorize-key.py '<authorized_keys line>'"""
import json
import subprocess
import sys

line = sys.argv[1].strip()
words = line.split()
key_body = next(words[i + 1] for i, w in enumerate(words) if w.startswith("ssh-") or ",ssh-" in w)

user = json.loads(subprocess.check_output(
    ["midclt", "call", "user.query", json.dumps([["username", "=", "root"]]),
     json.dumps({"get": True, "select": ["id", "sshpubkey"]})]))
current = (user.get("sshpubkey") or "").strip()

if key_body in current:
    print("ok")
    sys.exit(0)

updated = (current + "\n" + line).strip() + "\n"
subprocess.check_call(
    ["midclt", "call", "user.update", str(user["id"]), json.dumps({"sshpubkey": updated})],
    stdout=subprocess.DEVNULL)
print("changed")
