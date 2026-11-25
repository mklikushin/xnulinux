#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Enable automatic login for USER on this Mac (run as root, the user's password on stdin, one line).

    sudo python3 autologin.py USER < PASSWORD_FILE      then reboot

A rented Mac has nobody at its screen, and Apple's Virtualization.framework starts a macOS guest only for a user with a
desktop session ("The virtual machine failed to start" otherwise); automatic login gives that user one after a reboot.
The password is checked first (dscl -authonly, which takes it as an argument: visible in the process list for a
moment), then written to /etc/kcpassword in the system's own obfuscated form and USER set as loginwindow's
autoLoginUser. Nothing is printed but the result. To undo: sudo defaults delete /Library/Preferences/com.apple.loginwindow
autoLoginUser; sudo rm /etc/kcpassword.
Exit: 0 set, 1 wrong password or not root, 2 wrong usage.
Status: only syntax-checked in this cleaned form; the private original set it on the rented Mac.
"""
import os, subprocess, sys

if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
    print(__doc__, file=sys.stderr if len(sys.argv) != 2 else sys.stdout); sys.exit(0 if len(sys.argv) == 2 else 2)
user = sys.argv[1]; pw = sys.stdin.readline().rstrip("\n").encode()
if not pw: sys.exit("autologin: no password on stdin")
if os.geteuid() != 0: sys.exit("autologin: run with sudo")
# check the password before writing anything
r = subprocess.run(["dscl", "/Local/Default", "-authonly", user, pw.decode()], capture_output=True)
if r.returncode != 0: sys.exit("autologin: the password does not authenticate " + user)
key = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
data = bytearray(pw) + b"\0"
data += b"\0" * ((12 - len(data) % 12) % 12)
enc = bytes(b ^ key[i % len(key)] for i, b in enumerate(data))
fd = os.open("/etc/kcpassword", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, enc); os.close(fd); os.chown("/etc/kcpassword", 0, 0)
subprocess.check_call(["defaults", "write", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser", user])
print("autologin set for", user)
