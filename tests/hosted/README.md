# Tests that run inside the hosted macOS

Two small programs for the pointer-authentication fix in `xnu-patches/0001-linux64-machine-layer.patch` (the `cswitch.s`
part). They need `clang` in the hosted system, or the four programs built elsewhere (see below).

| File | What it shows |
|---|---|
| `keys.c` | Which of the four pointer-authentication keys (IA, IB, DA, DB) are on in the process. |
| `exc.m` | Whether a process can throw and catch Objective-C exceptions through its own frames. |
| `run.sh` | Builds both for `arm64` and `arm64e`, runs them and checks the output. |

Run all of it:

```sh
sh run.sh
```

Expected output (this is what the hosted system on the cloud VM printed with the fix; a real Apple silicon Mac gives
the same lines):

```
ok   keys arm64: IA off  IB off  DA off  DB off
ok   exc arm64: caught 50 of 50 exceptions
ok   keys arm64e: IA ON  IB ON  DA ON  DB ON
ok   exc arm64e: caught 50 of 50 exceptions
hosted tests: pass
```

A hosted system with no compiler (a disk built on Linux has none): build the programs where there is one, for example
on a hosted system that has developer tools, and hand their folder to `run.sh`:

```sh
for a in arm64 arm64e; do clang -arch $a -o keys-$a keys.c && clang -arch $a -framework Foundation -o exc-$a exc.m; done
sh run.sh /path/to/the/folder/with/the/four/programs
```

By hand:

```sh
clang -arch arm64 -o keys-arm64 keys.c && ./keys-arm64
clang -arch arm64 -framework Foundation -o exc-arm64 exc.m && ./exc-arm64
```

```
IA off  IB off  DA off  DB off
IB sign of 0x1234500000 -> 0x1234500000 (IB key OFF: no-op)
IA sign -> 0x1234500000 (IA key OFF)
caught 50 of 50 exceptions
```

Without the fix the hosted kernel left the IB and DB keys on for plain `arm64` processes. `keys-arm64` then prints
`IB ON` and `DB ON`, and `exc-arm64` dies with SIGBUS at the first throw on a CPU that faults on a failed
authentication (FEAT_FPAC): the system unwinder checks every return address with the IB key, and a plain `arm64` frame's
return address is not signed.

All three files were run in the hosted system on the cloud VM in the form they have here, with the output above, on
the Mac-built disk (compiled there) and on a Linux-built disk (with the four programs compiled on the Mac-built one).

## A fault on a thread that has the signal blocked

`faultmask.c` shows what Darwin does with a hardware fault on a thread that has the fault's signal blocked: nothing is
delivered, and the thread takes the same fault again, forever, at full CPU. It is not part of `run.sh` (it checks a
property of Darwin, not of the hosted kernel) and it explains
`gpu/xnu-cpu-metal/patches/mesa/0003-util-thread-fault-signals-unblocked.patch`: Mesa blocks SIGBUS on the threads it
starts, so a rasteriser thread that jumped to non-executable memory held a CPU instead of ending its process.

```sh
clang -o faultmask faultmask.c && ./faultmask
```

```
fault signals blocked:   still faulting after 2 s
fault signals unblocked: killed by signal 10
```

The same two lines on an Apple silicon Mac (macOS 27.2.1) and in the hosted system on a Google Cloud C4A VM, built as
`arm64` and as `arm64e`. The program kills its own child after two seconds; it leaves nothing running.
