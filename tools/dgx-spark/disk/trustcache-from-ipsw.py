# SPDX-License-Identifier: GPL-2.0-only
import plistlib, zipfile, sys, struct, subprocess, os
z = zipfile.ZipFile(sys.argv[1])   # the restore IPSW; blacktop's ipsw is on PATH
bm = plistlib.loads(z.read('BuildManifest.plist'))
ids = [i for i in bm['BuildIdentities'] if i['Info']['DeviceClass'].lower() == 'vma2macosap' and i['Info'].get('RestoreBehavior') == 'Erase' and 'Customer' in i['Info'].get('Variant', '')]
print(len(ids), 'identities'); path = ids[0]['Manifest']['StaticTrustCache']['Info']['Path']; print(path)
open('static.im4p', 'wb').write(z.read(path))
subprocess.run(['ipsw', 'img4', 'im4p', 'extract', '-o', 'trustcache-mac.bin', 'static.im4p'], check=True, capture_output=True)
p = open('trustcache-mac.bin', 'rb').read(); v, c = struct.unpack_from('<I', p, 0)[0], struct.unpack_from('<I', p, 20)[0]
print('trust cache version', v, 'entries', c, 'bytes', len(p), 'expected', 24 + c * (24 if v == 2 else 22))
