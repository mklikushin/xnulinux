#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""sershell.py SOCK CMDFILE [--wait-boot]: type each line of CMDFILE on a macOS guest's serial root shell, print its output and status."""
import socket, sys, time, re
sock_path, cmdfile = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX);
for _ in range(150):
    try: s.connect(sock_path); break
    except OSError: time.sleep(0.2)
else: sys.exit("no serial socket")
s.settimeout(1)
buf = b''
def read_until(pat, timeout, start=0):
    global buf
    end = time.time() + timeout
    while time.time() < end:
        m = re.search(pat, buf[start:])
        if m: return m
        try:
            d = s.recv(65536)
            if d: buf += d
        except socket.timeout: pass
    return None
PROMPT = rb'(root#|sh-[0-9.]+#|# )\s*$'
if '--wait-boot' in sys.argv:
    if not read_until(rb'Darwin Kernel Version', 420): sys.exit('no kernel')
    if not read_until(PROMPT, 120):
        for _ in range(30):
            st = len(buf); s.send(b'\n')
            if read_until(PROMPT, 10, st): break
        else: sys.exit('no prompt')
    print('[prompt]', flush=True)
n = 0
for line in open(cmdfile):
    line = line.rstrip('\n')
    if not line or line.startswith('#'): continue
    to = 120
    m = re.match(r'^@(\d+) (.*)', line)
    if m: to, line = int(m.group(1)), m.group(2)
    n += 1; tag = f'__DONE_{n}_{int(time.time())}__'
    st = len(buf); s.send((line + f'; echo {tag}$?\n').encode())
    m = read_until((tag + r'(\d+)').encode(), to, st)
    out = buf[st:].decode('utf-8', 'replace')
    out = out.replace(line + f'; echo {tag}$?', '', 1)
    out = re.sub(tag + r'\d+', '', out).strip('\r\n')
    print(f'$ {line[:150]}\n{out}\n[status {m.group(1).decode() if m else "TIMEOUT"}]', flush=True)
    if not m: break
