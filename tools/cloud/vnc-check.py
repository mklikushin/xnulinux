#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Headless check of the hosted Mac's Screen Sharing through a local tunnel: Apple authentication (type 30), one full
frame saved as PNG, and optional pointer/key events.   vnc-check.py PORT USER PASSFILE OUT.png [click X Y | key SYM]"""
import hashlib, os, socket, struct, subprocess, sys, time, zlib
port, user, passfile, out = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
action = sys.argv[5:]
pw = open(passfile).read().strip()
s = socket.create_connection(('127.0.0.1', port), timeout=20)
def rd(n):
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise SystemExit('connection closed after %d of %d bytes' % (len(b), n))
        b += c
    return b
banner = rd(12); s.sendall(banner)
n = rd(1)[0]; types = list(rd(n)); print('server', banner.decode().strip(), 'security types', types)
if 30 not in types: raise SystemExit('no Apple DH authentication (type 30) offered')
s.sendall(bytes([30]))
gen, klen = struct.unpack('>HH', rd(4)); prime = int.from_bytes(rd(klen), 'big'); peer = int.from_bytes(rd(klen), 'big')
priv = int.from_bytes(os.urandom(klen), 'big') % prime; pub = pow(gen, priv, prime); shared = pow(peer, priv, prime)
key = hashlib.md5(shared.to_bytes(klen, 'big')).hexdigest()
def field(t): b = t.encode() + b'\0'; return b + os.urandom(64 - len(b))
creds = field(user) + field(pw)
enc = subprocess.run(['openssl', 'enc', '-aes-128-ecb', '-nopad', '-K', key], input=creds, capture_output=True, check=True).stdout
s.sendall(enc + pub.to_bytes(klen, 'big'))
res = struct.unpack('>I', rd(4))[0]
if res != 0: raise SystemExit('authentication refused (result %d)' % res)
s.sendall(b'\x01')                                  # ClientInit: shared session
w, h = struct.unpack('>HH', rd(4)); pf = rd(16); name = rd(struct.unpack('>I', rd(4))[0]).decode('utf8', 'replace')
bpp, depth, big, true, rmax, gmax, bmax, rsh, gsh, bsh = struct.unpack('>BBBBHHHBBB3x', pf)
print('authenticated; desktop "%s" %dx%d, %d bpp' % (name, w, h, bpp))
s.sendall(struct.pack('>BBHi', 2, 0, 1, 0))         # SetEncodings: raw
def request(inc): s.sendall(struct.pack('>BBHHHH', 3, inc, 0, 0, w, h))
fb = bytearray(w * h * 3); covered = 0; request(0); t0 = time.time()
while covered < w * h and time.time() - t0 < 30:
    t = rd(1)[0]
    if t == 0:
        rd(1); nr = struct.unpack('>H', rd(2))[0]
        for _ in range(nr):
            x, y, rw, rh, e = struct.unpack('>HHHHi', rd(12))
            if e != 0: raise SystemExit('unexpected encoding %d' % e)
            data = rd(rw * rh * bpp // 8); covered += rw * rh
            for row in range(rh):
                line = data[row * rw * 4:(row + 1) * rw * 4]; o = ((y + row) * w + x) * 3
                px = struct.unpack(('>' if big else '<') + '%dI' % rw, line)
                fb[o:o + rw * 3] = bytes(c for p in px for c in ((p >> rsh) & 255, (p >> gsh) & 255, (p >> bsh) & 255))
    elif t == 2: pass                                # bell
    elif t == 3: rd(3); rd(struct.unpack('>I', rd(4))[0])   # server cut text
    else: raise SystemExit('unexpected server message %d' % t)
print('frame: %d of %d pixels in %.1f s' % (min(covered, w * h), w * h, time.time() - t0))
def chunk(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
raw = b''.join(b'\0' + bytes(fb[y * w * 3:(y + 1) * w * 3]) for y in range(h))
open(out, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))
if action[:1] == ['click']:
    x, y = int(action[1]), int(action[2])
    for mx, my, mask, d in ((x - 20, y - 10, 0, 0.3), (x - 5, y - 2, 0, 0.3), (x, y, 0, 0.5), (x, y, 1, 0.3), (x, y, 0, 1.5)):
        s.sendall(struct.pack('>BBHH', 5, mask, mx, my)); time.sleep(d)
    print('sent click at %d,%d' % (x, y))
elif action[:1] == ['key']:
    k = int(action[1], 0)
    for down in (1, 0): s.sendall(struct.pack('>BBHI', 4, down, 0, k)); time.sleep(0.1)
    print('sent key 0x%x' % k)
time.sleep(0.5); s.close()
