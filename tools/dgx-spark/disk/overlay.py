# SPDX-License-Identifier: GPL-2.0-only
import os, plistlib, subprocess, tarfile, sys
P, ST = '/vm/mac/payload.img', '/stage'
D, T = ST + '/D', ST + '/T/System/Library/User Template'
want = {'private/var/db/dslocal/nodes/Default/groups/admin.plist', 'private/var/db/dslocal/nodes/Default/groups/staff.plist',
        'Library/Preferences/com.apple.loginwindow.plist', 'private/var/db/com.apple.xpc.launchd/disabled.plist',
        'Library/Preferences/com.apple.keyboardtype.plist', 'private/etc/sysctl.conf'}
t = tarfile.open(P, 'r:')
have = []
for m in t:
    if m.name in want:
        t.extract(m, D); have.append(m.name)
    if m.name.startswith(('private/var/keybags', 'Users/')) or m.name in ('private/etc', 'private/var/db/.AppleSetupDone'):
        print('in the archive:', m.name, m.type, m.linkname)
print('existing files taken:', have)
for d in ('private/var/db/dslocal/nodes/Default/users', 'private/var/db/dslocal/nodes/Default/groups', 'Library/Preferences', 'Users',
          'Library/GPUBundles', 'Library/LaunchDaemons', 'private/var/db/com.apple.xpc.launchd', 'private/etc'):
    os.makedirs(D + '/' + d, exist_ok=True)
os.makedirs(T, exist_ok=True); os.makedirs(ST + '/T/System/Library/CoreServices', exist_ok=True)
plistlib.dump({'ProductVersion': '27.2', 'ProductBuildVersion': '26B123'}, open(ST + '/T/System/Library/CoreServices/SystemVersion.plist', 'wb'))
subprocess.run([sys.executable, '/vm/gui-user.py', D, T], check=True)
subprocess.run(['tar', '-C', D + '/Library/GPUBundles', '-xzf', '/vm/XnuCpuMetal.bundle.tar.gz'], check=True)
subprocess.run(['chown', '-R', '0:0', D + '/Library/GPUBundles'], check=True)
os.environ['D'] = D; os.environ['DISABLE'] = 'com.apple.watchdogd com.apple.iomfb_bics_daemon com.apple.audiomxd com.apple.audio.coreaudiod com.apple.PerfPowerServices com.apple.PerfPowerServicesExtended com.apple.oahd com.apple.oahd-root-helper'
import os, plistlib
D = os.environ["D"]
shell = {"Label": "xnulinux.shell", "ProgramArguments": ["/bin/bash", "-i"], "RunAtLoad": True,
         "StandardInPath": "/dev/console", "StandardOutPath": "/dev/console", "StandardErrorPath": "/dev/console",
         "EnvironmentVariables": {"HOME": "/var/root", "LOGNAME": "root", "USER": "root", "SHELL": "/bin/bash", "TERM": "dumb",
                                  "PATH": "/bin:/usr/bin:/sbin:/usr/sbin", "PS1": "xnulinux# "}}
p = D + "/Library/LaunchDaemons/xnulinux.shell.plist"
plistlib.dump(shell, open(p, "wb")); os.chown(p, 0, 0); os.chmod(p, 0o644)
# No display or system sleep: a hosted display has no one to wake it, and its sleep locks the screen after ten idle
# minutes (loginwindow's lock-screen request, reason 5), taking the session to the lock screen.
awake = {"Label": "xnulinux.awake", "RunAtLoad": True,
         "ProgramArguments": ["/usr/bin/pmset", "-a", "displaysleep", "0", "sleep", "0", "disksleep", "0"]}
p = D + "/Library/LaunchDaemons/xnulinux.awake.plist"
plistlib.dump(awake, open(p, "wb")); os.chown(p, 0, 0); os.chmod(p, 0o644)
# No screen saver either: after its idle time (no keyboard or pointer input: a hosted system with no one at it) it plays
# the aerial wallpaper's video, which without the GPU bridge decodes in software and takes both of a two-CPU system's
# CPUs, then locks the session. The setting is the user's, per host (ByHost, by IOPlatformUUID), so it is made at login.
nosaver = {"Label": "xnulinux.nosaver", "RunAtLoad": True, "LimitLoadToSessionType": "Aqua",
           "ProgramArguments": ["/usr/bin/defaults", "-currentHost", "write", "com.apple.screensaver", "idleTime", "-int", "0"]}
os.makedirs(D + "/Library/LaunchAgents", exist_ok=True)
p = D + "/Library/LaunchAgents/xnulinux.nosaver.plist"
plistlib.dump(nosaver, open(p, "wb")); os.chown(p, 0, 0); os.chmod(p, 0o644)
p = D + "/private/var/db/com.apple.xpc.launchd/disabled.plist"
disabled = plistlib.load(open(p, "rb")) if os.path.exists(p) else {}
disabled.update({label: True for label in os.environ["DISABLE"].split()})
plistlib.dump(disabled, open(p, "wb")); os.chown(p, 0, 0); os.chmod(p, 0o644)
# The hosted keyboard's type (ANSI), as Keyboard Setup Assistant records it for a keyboard it cannot identify by itself
# (xnulinux Keyboard, vendor 0x1209, product 0x5801: "<product>-<vendor>-0"); without it the assistant opens at each login.
p = D + "/Library/Preferences/com.apple.keyboardtype.plist"
plistlib.dump({"keyboardtype": {"22529-4617-0": 40}}, open(p, "wb")); os.chown(p, 0, 0); os.chmod(p, 0o644)
# Per-process memory limits (jetsam high-water marks) off: the CPU Metal device does a GPU's work in the process that asks
# for it (WebKit's GPU process, WindowServer), over the limits set for a real GPU's clients. launchd applies sysctl.conf.
p = D + "/private/etc/sysctl.conf"
open(p, "w").write("kern.memorystatus_highwater_enabled=0\n"); os.chown(p, 0, 0); os.chmod(p, 0o644)
print("console shell job, no screen saver, %d daemons disabled, keyboard type, sysctl.conf" % len(disabled))
# files and links only: the directories that exist on the Data volume keep their own owners and modes
names = subprocess.check_output('cd %s && find . ! -type d | sort' % D, shell=True, text=True).split('\n')[:-1]
open(ST + '/list', 'w').write('\n'.join(names) + '\n')
subprocess.run(['tar', '--numeric-owner', '--format=pax', '-C', D, '-cf', '/vm/mac/overlay.tar', '-T', ST + '/list'], check=True)
print(len(names), 'entries in overlay.tar', os.path.getsize('/vm/mac/overlay.tar'))
print([n for n in names if 'GPUBundles' not in n])
