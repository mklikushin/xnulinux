#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Helper of build-disk-linux.sh: the parts of the Linux disk build that need Python. Not meant to be run by hand.

    disk_linux.py names   --dvm DIR --inventory FILE
    disk_linux.py image   --dvm DIR --artifacts DIR --out DIR --size-gib N
    disk_linux.py stage   --dvm DIR --artifacts DIR --out DIR --repo DIR --gpu-bundle DIR --password-file FILE
                          --user NAME [--ssh-key FILE] --ssh on|off --screen-sharing on|off --autologin on|off --tuning on|off
    disk_linux.py finish  --dvm DIR --artifacts DIR --out DIR --trustcache FILE
    disk_linux.py verify  --dvm DIR --out DIR --user NAME

The APFS work is done by macOS-DroidVM's own scripts, loaded at run time from the checkout in --dvm (a pinned commit that
build-disk-linux.sh fetches; that repository has no licence file, so nothing of it is copied here) and by the Linux apfs
driver. What this file adds is the disk layout xnulinux needs and the staging of the Data volume:

- a GPT disk with two APFS containers. The first is a small "iBoot System Container" (its own partition type) with the
  iSCPreboot, xART, Hardware and Recovery volumes, all empty. launchd's mount-phase-1 looks for the xART volume in the
  container of a partition with that type and stops the boot without it. The second is the main container: the System
  volume from Apple's restore image with the OS cryptex merged in, Data, Preboot, VM and Update.
- three changes to macOS-DroidVM's behaviour, all made from outside, at run time:
  1. its volume list is set so that xART and Hardware are not also made in the main container;
  2. its rsync calls get -X (extended attributes) and three exclusions: the two attributes that hold APFS's transparent
     compression (the Linux driver hands out the file's contents uncompressed, so they must not follow) and the driver's
     internal symlink attribute;
  3. on hosts that forbid unprivileged user namespaces, a stand-in `unshare` runs its mkapfs call under sudo.
- the Data volume as scripts/mk-macvm-disk.sh leaves it on a Mac (user, setup done, GPU bundle, console shell, launchd's
  disabled list), plus the options of build-disk-linux.sh.

Uses sudo for: insmod, losetup, mount, umount, mkapfs, and every write into a mounted volume. The password is read from
its file by a root process and never appears on a command line or in the output.
"""
import argparse
import importlib.util
import json
import os
import plistlib
import struct
import subprocess
import sys
import uuid
from pathlib import Path

MIB = 1 << 20
ISC_OFFSET, ISC_SIZE = MIB, 500 * MIB
OFFSET = ISC_OFFSET + ISC_SIZE
ISC_TYPE = '69646961-6700-11AA-AA11-00306543ECAC'
APFS_TYPE = '7C3457EF-0000-11AA-AA11-00306543ECAC'
IDENTITY = 'vma2macosap'     # the virtual Mac of Apple's Virtualization framework: the identity the kernel collection is made from
COMPONENTS = ['StaticTrustCache', 'Cryptex1,SystemTrustCache', 'Cryptex1,AppTrustCache', 'Cryptex1,AppOS', 'Cryptex1,SystemOS', 'OS']
# never copied: APFS's transparent compression (the data arrives uncompressed) and the driver's own symlink attribute
XATTR_SKIP = ['osx.com.apple.decmpfs', 'osx.com.apple.ResourceFork', 'osx.com.apple.fs.symlink']
# scripts/mk-macvm-disk.sh's list: daemons of hardware the hosted system does not have
DISABLE = ['com.apple.watchdogd', 'com.apple.iomfb_bics_daemon', 'com.apple.audiomxd', 'com.apple.audio.coreaudiod',
           'com.apple.PerfPowerServices', 'com.apple.PerfPowerServicesExtended', 'com.apple.oahd', 'com.apple.oahd-root-helper']
# --tuning on: what docs/cloud-arm.md section 12 turns off for CPU rendering. cryptexd and locationd crashed repeatedly;
# the rest is idle work for hardware or services the hosted system does not have.
TUNE_SYSTEM = ['com.apple.security.cryptexd', 'com.apple.locationd', 'com.apple.icloud.searchpartyd',
               'com.apple.findmy.findmybeaconingd', 'com.apple.icloud.findmydeviced', 'com.apple.findmymacd',
               'com.apple.findmymacmessenger', 'com.apple.softwareupdated', 'com.apple.mobile.softwareupdated', 'com.apple.adid',
               'com.apple.fairplayd', 'com.apple.fairplaydeviceidentityd', 'com.apple.modelcatalogd', 'com.apple.perfpowermetricd']
# User agents of the voice assistant, suggestions, weather, tips, photo and media analysis. com.apple.siriactionsd is NOT in
# this list and must stay enabled: three control-centre widgets ask it for their actions and crash at every login without it.
TUNE_USER = '''amsengagementd assistantd biomesyncd cloudphotod duetexpertd familycircled financed gamed knowledge-agent
mediaanalysisd mediastream.mstreamd ndoagent newsd parsecd passd photoanalysisd suggestd tipsd weather weatherd
Siri.ActionPredictionNotifications Siri.agent Siri.running SiriTTSTrainingAgent siri.activation siri.analytics.assistant
siri.attendingstates.xpc siri.audiopowerupdate.xpc siri.context.service siri.contextcollector siri.deviceselection
siri.hearables siri.inference.EntityMatcher.admin siri.intelligence siri.invoke siri.localspeechrecognitionbridge.xpc
siri.location siri.orchestration.capabilities siri.orchestration.intelligencesession siri.orchestration.prescribedaction
siri.orchestration.sirix siri.ssrvtuitrainingservice.xpc siri.tether siri.uaf.service siri.VoiceShortcuts.xpc
siri.vocabularyupdates siri.voiceprofilemanager.xpc siriappintentsd siriinferenced siriinferenced.remembers
siriinferenced.signals siriknowledged siriknowledged.aps siriknowledged.koa.donate siriknowledged.vocabulary.admin
sirisuggestions sirittsd'''.split()
TUNE_USER = ['com.apple.' + name for name in TUNE_USER]


def fail(message, code=1):
    print(f'disk_linux: {message}', file=sys.stderr)
    sys.exit(code)


def run(*command, **options):
    return subprocess.run([str(c) for c in command], check=True, **options)


def sudo(*command, **options):
    return run('sudo', '-n', *command, **options)


def sudo_ok(*command):
    return subprocess.run(['sudo', '-n', *map(str, command)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def root_read(path):
    return subprocess.run(['sudo', '-n', 'cat', str(path)], capture_output=True).stdout


def root_write(path, data, mode='644', owner='0:0'):
    subprocess.run(['sudo', '-n', 'tee', str(path)], input=data, stdout=subprocess.DEVNULL, check=True)
    sudo('chown', owner, path)
    sudo('chmod', mode, path)


def components(inventory):
    """{component: member file name} of the virtual-Mac identity in macOS-DroidVM's inventory of the restore image."""
    data = json.loads(Path(inventory).read_text())
    found = [i for i in data['identities'] if i['device_class'] == IDENTITY and i['variant'] == 'macOS Customer'
             and i['restore_behavior'] == 'Erase']
    if len(found) != 1:
        fail(f'{inventory}: {len(found)} identities for {IDENTITY}, one wanted')
    return {name: os.path.basename(found[0]['components'][name]['path']) for name in COMPONENTS}


def load_droidvm(dvm, artifacts, shim_dir):
    """macOS-DroidVM's make-macos-disk.py as a module, with the three changes described at the top of this file."""
    dvm = Path(dvm).resolve()
    # Two of its scripts import UniXNU's packed_ramdisk (the seed format of DroidVM's phone storage) when they load. Nothing
    # of it is used for a plain disk image, and UniXNU is not fetched, so an empty module stands in for it.
    stand_in = dvm / 'sources/UniXNU/drivers/DarwinBoot/Test'
    stand_in.mkdir(parents=True, exist_ok=True)
    if not (stand_in / 'packed_ramdisk.py').exists():
        (stand_in / 'packed_ramdisk.py').write_text('# stand-in written by xnulinux tools/cloud/vm/disk_linux.py: not used for a raw disk\n')
    if subprocess.run(['unshare', '-r', 'true'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        shim_dir = Path(shim_dir)
        shim_dir.mkdir(parents=True, exist_ok=True)
        (shim_dir / 'unshare').write_text('#!/bin/sh\n# stand-in written by xnulinux tools/cloud/vm/disk_linux.py: this host forbids unprivileged user\n'
                                          '# namespaces, so `unshare -r mkapfs ... IMAGE` runs under sudo and IMAGE is handed back to the caller\n'
                                          '[ "$1" = -r ] && shift\nsudo -n "$@" || exit 1\nfor last; do :; done\n'
                                          'sudo -n chown "$(id -u):$(id -g)" "$last"\n')
        (shim_dir / 'unshare').chmod(0o755)
        os.environ['PATH'] = f"{shim_dir}:{os.environ['PATH']}"
    os.environ['MACOS_ARTIFACTS'] = str(Path(artifacts).resolve())
    os.chdir(dvm)
    sys.path.insert(0, str(dvm / 'scripts'))
    spec = importlib.util.spec_from_file_location('droidvm_make_macos_disk', dvm / 'scripts/make-macos-disk.py')
    mk = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mk)
    mk.OTHER_VOLUMES = [('Preboot', 'B'), ('VM', 'V'), ('Update', 'E')]
    original = mk.sudo

    def sudo_with_xattrs(*command, **options):
        command = [str(c) for c in command]
        if command and command[0] == 'rsync':
            command[1:1] = ['-X'] + [f'--filter=-x {name}' for name in XATTR_SKIP]
        return original(*command, **options)
    mk.sudo = sudo_with_xattrs
    return mk


def release(image, points):
    """Unmount what an interrupted run left behind and detach its loop devices."""
    for point in points:
        while subprocess.run(['mountpoint', '-q', str(point)]).returncode == 0:
            sudo('umount', point)
    listed = subprocess.run(['sudo', '-n', 'losetup', '-j', str(image), '-O', 'NAME', '--noheadings'], capture_output=True, text=True).stdout
    for loop in listed.split():
        sudo('losetup', '-d', loop)


def build_isc(mk, image, scratch):
    """The iBoot System Container. mkapfs makes a container with one volume; macOS-DroidVM's apfs-add-volumes adds three. mkapfs
    allows one volume per 512 MiB; Apple's installer puts four in a 500 MB container, so the limit in the new container's
    superblock is raised to four, and the first volume gets the Preboot role as on an installed disk."""
    volumes = mk.volumes
    isc = scratch / 'isc.img'
    isc.unlink(missing_ok=True)
    with open(isc, 'wb') as handle:
        handle.truncate(ISC_SIZE)
    run('unshare', '-r', volumes.MKAPFS, '-L', 'iSCPreboot', '-u', str(uuid.uuid4()).upper(), isc, stdout=subprocess.DEVNULL)
    img = mk.grow.Image(isc)
    checkpoint = mk.grow.Checkpoint(img)
    struct.pack_into('<I', checkpoint.sb, volumes.NX_MAX_FS, 4)
    checkpoint.put_superblock(img)
    (_, _, block, apsb), = volumes.Container(img).volumes()
    struct.pack_into('<H', apsb, volumes.APSB_ROLE, volumes.ROLES['B'])
    img.put(block, apsb)
    volumes.add_volumes(img, [(name, volumes.ROLES[role], False, str(uuid.uuid4()).upper())
                              for name, role in (('xART', 'X'), ('Hardware', 'H'), ('Recovery', 'R'))])
    img.map.close()
    img.handle.close()
    run('dd', f'if={isc}', f'of={image}', 'bs=1M', f'seek={ISC_OFFSET}', 'oflag=seek_bytes', 'conv=notrunc,sparse', 'status=none')
    isc.unlink()


def roles_of(mk, image):
    logical = image.stat().st_size - OFFSET - MIB
    return mk.volumes.role_volumes(mk.grow.Image(image, OFFSET, logical)), logical


def attach(mk, image, logical):
    if subprocess.run(['grep', '-q', '^apfs ', '/proc/modules']).returncode:
        sudo('insmod', mk.APFS_KO)
    return subprocess.check_output(['sudo', '-n', 'losetup', '--find', '--show', '--offset', str(OFFSET), '--sizelimit', str(logical),
                                    str(image)], text=True).strip()


def cmd_names(args):
    for name, member in components(args.inventory).items():
        print(f'{name}\t{member}')


def cmd_image(args):
    out = Path(args.out).resolve()
    image, scratch = out / 'mac.img', out / 'scratch'
    scratch.mkdir(parents=True, exist_ok=True)
    release(image, [scratch / 'volume', scratch / 'source'])
    mk = load_droidvm(args.dvm, args.artifacts, out / 'shim')
    logical = args.size_gib << 30
    image.unlink(missing_ok=True)
    with open(image, 'xb') as handle:
        handle.truncate(OFFSET + logical + MIB)
    run('sgdisk', '-a', '8', '-n', f'1:{ISC_OFFSET // 512}:{OFFSET // 512 - 1}', '-t', f'1:{ISC_TYPE}', '-c', '1:iBootSystemContainer',
        '-n', f'2:{OFFSET // 512}:{(OFFSET + logical) // 512 - 1}', '-t', f'2:{APFS_TYPE}', '-c', '2:Container', image,
        stdout=subprocess.DEVNULL)
    build_isc(mk, image, scratch)
    roles = mk.build_container(image, OFFSET, logical, str(uuid.uuid4()).upper())
    print('volumes:', {mk.volumes.ROLE_NAMES.get(r, hex(r)): v for r, v in roles.items()}, flush=True)
    loop = attach(mk, image, logical)
    try:
        mk.fill(loop, roles, scratch)
    finally:
        sudo('losetup', '-d', loop)
    print('image: built')


def cmd_stage(args):
    out = Path(args.out).resolve()
    image, scratch = out / 'mac.img', out / 'scratch'
    scratch.mkdir(parents=True, exist_ok=True)
    point, source_point = scratch / 'volume', scratch / 'source'
    release(image, [point, source_point])
    mk = load_droidvm(args.dvm, args.artifacts, out / 'shim')
    volumes = mk.volumes
    roles, logical = roles_of(mk, image)
    repo, bundle, user = Path(args.repo).resolve(), Path(args.gpu_bundle).resolve(), args.user
    point.mkdir(exist_ok=True)
    source_point.mkdir(exist_ok=True)
    loop = attach(mk, image, logical)
    source_loop = subprocess.check_output(['sudo', '-n', 'losetup', '--find', '--show', '--read-only', str(mk.ARTIFACTS / 'os.raw')],
                                          text=True).strip()
    mounted = []
    try:
        # the user template and the system's version come from Apple's untouched System volume (os.raw), mounted read-only:
        # two volumes of one container mounted together crashed the Linux driver for macOS-DroidVM's authors
        sudo('mount', '-t', 'apfs', '-o', 'ro', source_loop, source_point)
        mounted.append(source_point)
        sudo('mount', '-t', 'apfs', '-o', f'readwrite,vol={roles[volumes.ROLES["D"]][0]}', loop, point)
        mounted.append(point)
        D = point
        (mk.ARTIFACTS / 'SystemVersion.plist').write_bytes(root_read(source_point / 'System/Library/CoreServices/SystemVersion.plist'))
        # 1. the user: this repository's own script. The password file is read inside the root process.
        runner = ('import sys, runpy\nargv = sys.argv[1:]\nwith open(argv[4]) as f: pw = f.readline().rstrip("\\n")\n'
                  'if not pw: sys.exit("the password file is empty")\n'
                  'sys.argv = ["gui-user.py", argv[1], argv[2], argv[3], pw, "501"]\nrunpy.run_path(argv[0], run_name="__main__")\n')
        sudo('python3', '-c', runner, repo / 'tools/hosted/gui-user.py', D, source_point / 'System/Library/User Template', user,
             Path(args.password_file).resolve())
        home = D / 'Users' / user
        lw_path = D / 'Library/Preferences/com.apple.loginwindow.plist'
        if args.autologin == 'off':
            sudo('rm', '-f', D / 'private/etc/kcpassword')
            lw = plistlib.loads(root_read(lw_path))
            lw.pop('autoLoginUser', None)
            lw.pop('autoLoginUserUID', None)
            root_write(lw_path, plistlib.dumps(lw, fmt=plistlib.FMT_BINARY))
        # 2. the Metal plugin
        sudo('mkdir', '-p', D / 'Library/GPUBundles', D / 'Library/LaunchDaemons', D / 'Library/LaunchAgents',
             D / 'private/var/db/com.apple.xpc.launchd', D / 'Library/Preferences', D / 'private/etc')
        sudo('rm', '-rf', D / 'Library/GPUBundles/XnuCpuMetal.bundle')
        sudo('cp', '-R', bundle, D / 'Library/GPUBundles/XnuCpuMetal.bundle')
        sudo('chown', '-R', '0:0', D / 'Library/GPUBundles')
        sudo('chmod', '-R', 'go-w,a+rX', D / 'Library/GPUBundles')
        # 3. the jobs and settings of scripts/mk-macvm-disk.sh (see there for why each exists)
        shell = {'Label': 'xnulinux.shell', 'ProgramArguments': ['/bin/bash', '-i'], 'RunAtLoad': True,
                 'StandardInPath': '/dev/console', 'StandardOutPath': '/dev/console', 'StandardErrorPath': '/dev/console',
                 'EnvironmentVariables': {'HOME': '/var/root', 'LOGNAME': 'root', 'USER': 'root', 'SHELL': '/bin/bash', 'TERM': 'dumb',
                                          'PATH': '/bin:/usr/bin:/sbin:/usr/sbin', 'PS1': 'xnulinux# '}}
        root_write(D / 'Library/LaunchDaemons/xnulinux.shell.plist', plistlib.dumps(shell))
        awake = {'Label': 'xnulinux.awake', 'RunAtLoad': True,
                 'ProgramArguments': ['/usr/bin/pmset', '-a', 'displaysleep', '0', 'sleep', '0', 'disksleep', '0']}
        root_write(D / 'Library/LaunchDaemons/xnulinux.awake.plist', plistlib.dumps(awake))
        nosaver = {'Label': 'xnulinux.nosaver', 'RunAtLoad': True, 'LimitLoadToSessionType': 'Aqua',
                   'ProgramArguments': ['/usr/bin/defaults', '-currentHost', 'write', 'com.apple.screensaver', 'idleTime', '-int', '0']}
        root_write(D / 'Library/LaunchAgents/xnulinux.nosaver.plist', plistlib.dumps(nosaver))
        root_write(D / 'Library/Preferences/com.apple.keyboardtype.plist', plistlib.dumps({'keyboardtype': {'22529-4617-0': 40}}))
        root_write(D / 'private/etc/sysctl.conf', b'kern.memorystatus_highwater_enabled=0\n')
        # the Data template's relative links (Applications/Safari.app -> ../System/Cryptexes/App/...) climb to the Data volume's
        # own root, which has no System/Cryptexes: point it at the real one
        if not sudo_ok('test', '-L', D / 'System/Cryptexes'):
            sudo('mkdir', '-p', D / 'System')
            sudo('ln', '-s', '/System/Cryptexes', D / 'System/Cryptexes')
        # 4. launchd's disabled lists: a label set to False is forced on, True is off, absent is the system's default
        tune = args.tuning == 'on'
        path = D / 'private/var/db/com.apple.xpc.launchd/disabled.plist'
        old = root_read(path)
        disabled = plistlib.loads(old) if old else {}
        disabled.update({label: True for label in DISABLE})
        for label in TUNE_SYSTEM:
            if tune:
                disabled[label] = True
            else:
                disabled.pop(label, None)
        disabled['com.openssh.sshd'] = args.ssh != 'on'
        disabled['com.apple.screensharing'] = args.screen_sharing != 'on'
        root_write(path, plistlib.dumps(disabled))
        path = D / 'private/var/db/com.apple.xpc.launchd/disabled.501.plist'
        old = root_read(path)
        user_disabled = plistlib.loads(old) if old else {}
        for label in TUNE_USER:
            if tune:
                user_disabled[label] = True
            else:
                user_disabled.pop(label, None)
        if user_disabled:
            root_write(path, plistlib.dumps(user_disabled))
        else:
            sudo('rm', '-f', path)
        # 5. the rest of the tuning: no Spotlight indexing, no Power Nap, sRGB display profile, less for the compositor to blend and animate
        job = D / 'Library/LaunchDaemons/xnulinux.tune.plist'
        srgb_agent = D / 'Library/LaunchAgents/xnulinux.display-srgb.plist'
        prefs = [(D / 'Library/Preferences/com.apple.universalaccess.plist', {'reduceTransparency': True, 'reduceMotion': True}, '644', '0:0'),
                 (D / 'Library/Preferences/com.apple.Accessibility.plist', {'ReduceMotionEnabled': True}, '644', '0:0'),
                 (home / 'Library/Preferences/com.apple.universalaccess.plist', {'reduceTransparency': True, 'reduceMotion': True}, '600', '501:20'),
                 (home / 'Library/Preferences/com.apple.Accessibility.plist', {'ReduceMotionEnabled': True}, '600', '501:20')]
        if tune:
            root_write(job, plistlib.dumps({'Label': 'xnulinux.tune', 'RunAtLoad': True, 'ProgramArguments': [
                '/bin/sh', '-c', '/usr/bin/mdutil -a -i off; /usr/bin/pmset -a powernap 0']}))
            root_write(srgb_agent, plistlib.dumps({'Label': 'xnulinux.display-srgb', 'RunAtLoad': True, 'ProgramArguments': [
                '/usr/bin/defaults', '-currentHost', 'write', '-g', 'com.apple.ColorSync.Devices', '-dict-add',
                'Device.mntr.44726F69-6456-4D00-0000-000000000001',
                '<dict><key>CustomProfiles</key><dict><key>1</key><string>/System/Library/ColorSync/Profiles/sRGB Profile.icc</string></dict></dict>']}))
        else:
            sudo('rm', '-f', job, srgb_agent)
        for path, keys, mode, owner in prefs:
            old = root_read(path)
            value = plistlib.loads(old) if old else {}
            for key, setting in keys.items():
                if tune:
                    value[key] = setting
                else:
                    value.pop(key, None)
            if value:
                root_write(path, plistlib.dumps(value, fmt=plistlib.FMT_BINARY), mode, owner)
            else:
                sudo('rm', '-f', path)
        # 6. the ssh key
        if args.ssh_key:
            sudo('mkdir', '-p', home / '.ssh')
            sudo('cp', Path(args.ssh_key).resolve(), home / '.ssh/authorized_keys')
            sudo('chown', '-R', '501:20', home / '.ssh')
            sudo('chmod', '700', home / '.ssh')
            sudo('chmod', '600', home / '.ssh/authorized_keys')
        run('sync')
        listing = subprocess.check_output(['sudo', '-n', 'ls', str(D / 'Users'), str(D / 'Library/GPUBundles'),
                                           str(D / 'private/var/db/dslocal/nodes/Default/users')], text=True)
        if f'{user}.plist' not in listing or 'XnuCpuMetal.bundle' not in listing:
            fail('the user record or the GPU bundle is missing on the Data volume after staging')
        print(f'stage: user {user}, automatic login {args.autologin}, ssh {args.ssh}, screen sharing {args.screen_sharing}, '
              f'tuning {args.tuning}, {sum(1 for v in disabled.values() if v)} system and '
              f'{sum(1 for v in user_disabled.values() if v)} user services disabled')
    finally:
        for mount in reversed(mounted):
            sudo('umount', mount)
        sudo('losetup', '-d', source_loop)
        sudo('losetup', '-d', loop)


def trustcache_payload(im4p):
    """The payload of an IM4P file: SEQUENCE { IA5 'IM4P', IA5 type, IA5 version, OCTET STRING payload, ... }."""
    def tlv(at):
        tag, n = im4p[at], im4p[at + 1]
        at += 2
        if n & 0x80:
            k = n & 0x7f
            n = int.from_bytes(im4p[at:at + k], 'big')
            at += k
        return tag, at, n
    _, at, n = tlv(0)
    end, items = at + n, []
    while at < end:
        tag, start, n = tlv(at)
        items.append((tag, im4p[start:start + n]))
        at = start + n
    if len(items) < 4 or items[0][1] != b'IM4P' or items[1][1] != b'trst' or items[3][0] != 4:
        fail('the static trust cache member is not a trust cache IM4P')
    return items[3][1]


def cmd_finish(args):
    out = Path(args.out).resolve()
    image, scratch = out / 'mac.img', out / 'scratch'
    release(image, [scratch / 'volume', scratch / 'source'])
    mk = load_droidvm(args.dvm, args.artifacts, out / 'shim')
    volumes = mk.volumes
    roles, _ = roles_of(mk, image)
    need = {'S': 'System', 'D': 'Data', 'B': 'Preboot', 'V': 'VM', 'E': 'Update'}
    missing = [name for letter, name in need.items() if volumes.ROLES[letter] not in roles]
    if missing:
        fail(f'the main container has no {", ".join(missing)} volume')
    isc = volumes.role_volumes(mk.grow.Image(image, ISC_OFFSET, ISC_SIZE))
    if volumes.ROLES['X'] not in isc:
        fail('the iBoot System Container has no xART volume')
    # ROOT_UUID: the System volume's. BOOT_UUID: its volume group's, which is the Data volume's UUID (as diskutil gives it).
    version = plistlib.loads((Path(args.artifacts) / 'SystemVersion.plist').read_bytes())
    (out / 'mac.conf').write_text(f'ROOT_UUID={roles[volumes.ROLES["S"]][1]}\nBOOT_UUID={roles[volumes.ROLES["D"]][1]}\n'
                                  f'MACOS={version["ProductVersion"]}\n')
    (out / 'trustcache.bin').write_bytes(trustcache_payload(Path(args.trustcache).read_bytes()))
    print((out / 'mac.conf').read_text(), end='')
    print(f'finish: {version["ProductName"]} {version["ProductVersion"]} ({version["ProductBuildVersion"]}), '
          f'trust cache {(out / "trustcache.bin").stat().st_size} bytes')


def cmd_verify(args):
    """Mount each written volume read-only, one at a time, and look for what a boot needs."""
    out = Path(args.out).resolve()
    image, scratch = out / 'mac.img', out / 'scratch'
    point = scratch / 'volume'
    release(image, [point, scratch / 'source'])
    mk = load_droidvm(args.dvm, args.artifacts, out / 'shim')
    volumes = mk.volumes
    roles, logical = roles_of(mk, image)
    point.mkdir(parents=True, exist_ok=True)
    wanted = {
        'S': ['System/Library/CoreServices/SystemVersion.plist', 'System/Library/dyld/dyld_shared_cache_arm64e', 'sbin/launchd',
              'usr/lib/libLaunchServicesSupport.dylib'],
        'B': ['Cryptexes/App/System/Applications/Safari.app'],
        'D': [f'Users/{args.user}/Library/Preferences/com.apple.SetupAssistant.plist',
              f'private/var/db/dslocal/nodes/Default/users/{args.user}.plist', 'private/var/db/.AppleSetupDone',
              'Library/GPUBundles/XnuCpuMetal.bundle/Contents/MacOS/XnuCpuMetal', 'Library/LaunchDaemons/xnulinux.shell.plist',
              'private/var/db/com.apple.xpc.launchd/disabled.plist'],
    }
    bad = 0
    loop = attach(mk, image, logical)
    try:
        for letter, paths in wanted.items():
            sudo('mount', '-t', 'apfs', '-o', f'ro,vol={roles[volumes.ROLES[letter]][0]}', loop, point)
            try:
                for path in paths:
                    if sudo_ok('test', '-e', point / path):
                        print(f'ok      {letter}: {path}')
                    else:
                        print(f'MISSING {letter}: {path}')
                        bad = 1
                if letter == 'D':
                    marks = subprocess.run(['sudo', '-n', 'python3', '-c',
                                            'import os,sys\nprint(sum(1 for d,ds,fs in os.walk(sys.argv[1]) for e in ds if '
                                            '"osx.com.apple.rootless" in os.listxattr(os.path.join(d,e), follow_symlinks=False)))',
                                            str(point)], capture_output=True, text=True).stdout.strip()
                    print(f'info    D: {marks} directories carry the com.apple.rootless attribute')
            finally:
                sudo('umount', point)
    finally:
        sudo('losetup', '-d', loop)
    sys.exit(bad)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('names', 'image', 'stage', 'finish', 'verify'):
        p = sub.add_parser(name)
        p.add_argument('--dvm')
        p.add_argument('--artifacts')
        p.add_argument('--out')
        p.add_argument('--inventory')
        p.add_argument('--size-gib', type=int)
        p.add_argument('--repo')
        p.add_argument('--gpu-bundle')
        p.add_argument('--password-file')
        p.add_argument('--user', default='xnu')
        p.add_argument('--ssh-key')
        p.add_argument('--trustcache')
        for flag in ('--ssh', '--screen-sharing', '--autologin', '--tuning'):
            p.add_argument(flag, choices=['on', 'off'], default='off')
    args = parser.parse_args()
    try:
        {'names': cmd_names, 'image': cmd_image, 'stage': cmd_stage, 'finish': cmd_finish, 'verify': cmd_verify}[args.command](args)
    except subprocess.CalledProcessError as error:
        fail(f'command failed with status {error.returncode}: {" ".join(map(str, error.cmd))[:300]}')


if __name__ == '__main__':
    main()
