# A12 GhostLock — one-click root for the Samsung Galaxy A12

![CVE](https://img.shields.io/badge/CVE-2026--43499-ff3b30?style=flat-square)
![Codename](https://img.shields.io/badge/codename-GhostLock-8b5cf6?style=flat-square)
![Target](https://img.shields.io/badge/target-SM--A125F%20%C2%B7%20Android%2012-3b82f6?style=flat-square)
![Kernel](https://img.shields.io/badge/kernel-4.19.188%20non--GKI-0ea5e9?style=flat-square)
![Result](https://img.shields.io/badge/result-uid%200%20%2B%20forged%20caps-22c55e?style=flat-square)
![Layer](https://img.shields.io/badge/userspace-KernelSU--compatible-64748b?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-black?style=flat-square)

**A complete, reproducible local privilege escalation for the Samsung Galaxy A12
(SM-A125F, Android 12, kernel 4.19.188), built on the GhostLock bug
(CVE-2026-43499).** It leaves a parked uid-0 process with a forged capability
set, serves `su` to ordinary apps through a KernelSU-style grant dialog, and
implements a KernelSU-compatible userspace layer (`su`, `ksud`, `magisk`,
`resetprop`, hot module install with overlayfs).

The deliverable is a double-click Windows package. It reboots the phone,
exploits it, verifies root, installs three real root apps, and proves each one
actually ran commands through its root shell.

```
OneClickRoot.bat
  └─ root.ps1 ── adb ──► SM-A125F
        ├─ fresh boot (exploit is one-shot per boot)
        ├─ payload/exploit rootd ──► L1 permissive → L2 box alive → L3 uid 0 + caps
        ├─ KernelSU layer check (su/ksud/magisk/resetprop + module install)
        ├─ install manager + Neo Backup + App Manager + Shizuku
        ├─ drive each app, tap "Always allow" on the grant dialog
        └─ PASS only if root, popups, root commands and modules all verify
```

---

## Table of contents

- [Disclosure & intent](#disclosure--intent)
- [The vulnerability: GhostLock](#the-vulnerability-ghostlock)
- [Why this target](#why-this-target)
- [The chain](#the-chain)
- [KernelSU-compatible userspace layer](#kernelsu-compatible-userspace-layer)
- [The grant dialog](#the-grant-dialog)
- [Demo root apps](#demo-root-apps)
- [Usage](#usage)
- [What PASS means](#what-pass-means)
- [Evidence](#evidence)
- [Reliability](#reliability)
- [Limitations](#limitations-honest-ones)
- [Repository layout](#repository-layout)
- [Building from source](#building-from-source)
- [Credits](#credits)
- [License](#license)

---

## Disclosure & intent

This is a **post-disclosure, fully patched-upstream** bug. CVE-2026-43499 was
reported to `security@kernel.org` on 2026-04-18, fixed on 2026-04-20,
backported on 2026-05-04, and publicly disclosed on 2026-07-07 by
[NebuSec](https://nebusec.ai/buglist/CVE-2026-43499/). This repository does not
disclose a new vulnerability.

The exploit is published for **security research and for rooting hardware you
own**. It is device-specific: hard-coded kernel addresses and structure offsets
for one firmware build. Running it against a patched kernel fails cleanly
(the primitive does not exist); running it against a *different* kernel can
panic the box.

**Do not use this on a device you do not own.** Rooting voids warranties,
can trip Knox, and may break banking/DRM apps.

---

## The vulnerability: GhostLock

GhostLock is a use-after-free in the Linux kernel's rtmutex/futex-PI code,
in `remove_waiter()` (`kernel/locking/rtmutex.c`). It affects Linux 2.6.39-rc1
through 7.1-rc1 — roughly fifteen years — whenever `CONFIG_FUTEX_PI=y`, which
is the default nearly everywhere. No capabilities, no namespaces, no network:
the trigger is ordinary threading plus futex syscalls.

### Root cause

`remove_waiter()` was written for the self-blocking slow path, where `current`
*is* the waiter, so it clears `current->pi_blocked_on`. Requeue-PI reuses the
same helper through `rt_mutex_start_proxy_lock()` on behalf of a sleeping task,
so `current` is the **requeuer**, not the waiter. When the proxy enqueue hits
`-EDEADLK` and rolls back, the waiter is dequeued from the lock but
`pi_blocked_on` is scrubbed on the **wrong task**. The waiter then returns to
userspace with `pi_blocked_on` still pointing at the `rt_mutex_waiter` living
on its own `FUTEX_WAIT_REQUEUE_PI` stack frame — which is freed the moment the
syscall returns. Every later PI chain walk through that task dereferences a
dangling pointer.

The upstream fix reads the owning task from `waiter->task` instead of
`current`:

```c
struct task_struct *waiter_task = waiter->task;
...
scoped_guard(raw_spinlock, &waiter_task->pi_lock) {
    rt_mutex_dequeue(lock, waiter);
    waiter_task->pi_blocked_on = NULL;
}
```

A regression in the first fix (CVE-2026-53166) was patched on 2026-06-02. The
original research turned the stack UAF into a 97%-stable LPE and container
escape via `PR_SET_MM_MAP` stack reclaim, a forged `rt_mutex_waiter`, a
constrained write into `inet6_protos[IPPROTO_UDP]`, a CPU-entry-area ROP pivot
and a "DirtyMode" `core_pattern` flip — and won Google's kernelCTF.

### This exploit takes a different path

We do not reclaim the freed stack frame with `PR_SET_MM_MAP` and we do not
build a ROP chain. We keep the dangling waiter alive and steer the rtmutex
rbtree operations into a **fake-lock constrained write**: a controlled
`rb_erase` that stores an attacker-chosen 8-byte value at an attacker-chosen
kernel address. That primitive is applied directly to kernel data — SELinux
state, the `task_struct` credential pointers, and the credential's capability
words — which is enough for a full root shell and needs no control-flow
hijack. The trade-off is that some erase rounds corrupt the PI waiter tree and
panic the box, so the tool retries on a fresh boot (see
[Reliability](#reliability)).

---

## Why this target

| | |
|---|---|
| Device | Samsung Galaxy A12 (SM-A125F) |
| SoC | MediaTek Helio P35 (MT6765) |
| Android | 12 |
| Kernel | 4.19.188, **non-GKI** |
| Bootloader | locked (`ro.boot.flash.locked=1`, `sys.oem_unlock_allowed=0`) |
| SELinux | Enforcing, shell domain |
| Config | `CONFIG_FUTEX_PI=y`, no `CONFIG_KSU`, no `CONFIG_KEXEC`, no module loading |

Every mainstream root solution is blocked here:

* **KernelSU / KernelSU-Next** need a kernel driver; the manager only supports
  GKI kernels, and this is a non-GKI Samsung 4.19 build with a locked
  bootloader.
* **APatch** supports 3.18–6.12 non-GKI, but installs by patching `boot.img`
  and flashing it — impossible with the bootloader locked.
* **Magisk** patches the boot ramdisk — same blocker.
* The GhostLock-Galaxy ports that do exist rely on `ksud late-load` plus a
  prebuilt `kernelsu.ko`, which requires module loading this kernel does not
  allow.

So the package brings its own su stack instead: the exploited process keeps
uid 0 + capabilities and serves root over a socket, while `su`, `ksud`,
`magisk`, `resetprop` and a module engine emulate the KernelSU userspace
contract on top of it.

---

## The chain

Three levels, each independently verified. The harness refuses to report
success without all three.

| Level | Meaning | Check |
|---|---|---|
| **L1** | SELinux permissive | `selinux_state` write, `getenforce` → `Permissive` |
| **L2** | Box alive and sane | boot_id unchanged, task count/zombies, idle time (no spin) |
| **L3** | uid 0 with working capabilities | `uid=0 euid=0`, `CapEff=ffffff8009ea09b2`, `su -c id` → `uid=0(root)` |

### 1. Stage the PI dependency cycle

Three futex words and three threads form a cycle that closes on its own:

```
waiter ──► f_pi_target ──► owner ──► f_pi_chain ──► waiter
```

`W` locks `f_pi_chain`, `T` blocks on `f_pi_target` at nice 19, and an `O`
thread per round blocks on `f_pi_chain`. `W` then waits on `f_wait` with
`FUTEX_WAIT_REQUEUE_PI` targeting `f_pi_target`, which drives the proxy
enqueue into the `-EDEADLK` rollback.

### 2. Reclaim and forge

The rollback leaves `pi_blocked_on` dangling at the freed waiter frame. A
follow-up `sched_setattr()` (or the next PI walk) dereferences it. The forged
waiter's tree links are laid out so that the erase's pointer stores land where
we want:

```
rb_erase_cached(node)
   ├─ stores parent/child pointer  → address A
   └─ stores colour/left/right     → value V
```

That is the constrained write: **V to A**. Each request consumes one 8-byte
slot. The slot array lives in the unused tail of `modprobe_path` (256 bytes),
which is writable and never used by the kernel after boot:

```
MODPROBE_PATH 0xffffff8009e78340
  +0x10 .. +0xef   17 fake-lock slots
  +0xd0            slot 6 (reserved)
  +0xf8            REINIT_SCRATCH
```

### 3. Apply the writes

A clean run uses 8 of 17 slots:

| # | Write | Purpose |
|---|---|---|
| 1 | `selinux_state = 0` | permissive |
| 2 | `REINIT_SCRATCH = selinux_state + 3` | force SELinux state re-init so the shell context is re-evaluated |
| 3 | carrier tail | read `task_struct` via the hostname sysctl |
| 4 | carrier candidate | point the carrier at a task |
| 5 | `cred->securebits = 0` | clear `SECBIT_*` |
| 6 | `cred->cap_permitted = CAP_VALUE` | forged permitted set |
| 7 | `cred->cap_effective = CAP_VALUE` | forged effective set |
| 8 | `cred->cap_bset = CAP_VALUE` | keep caps across `exec` |

### 4. Read kernel memory with the hostname carrier

`/proc/sys/kernel/hostname` stores into `hostname_data` (`0xffffff8009e88328`)
and reads back as a C string. Point the carrier at `task + 0x748` and read
`real_cred`, `cred`, `comm` out of kernel memory. Because a `0x00` byte
truncates the string, an unreadable cred pointer shows up as a short read —
the exploit then churns `setresuid(2000,2000,2000)` and forks a beacon per
round until one cred allocation has a readable low byte (5 rounds max, 2 slots
per round, 16 of 17 worst case).

### 5. Rewrite the credentials

```
cred + 4   uid      → 0        cred + 48  cap_permitted → CAP_VALUE
cred + 8   gid      → 0        cred + 56  cap_effective → CAP_VALUE
cred + 20  euid     → 0        cred + 64  cap_bset      → CAP_VALUE
cred + 28  fsuid    → 0
```

`CAP_VALUE = 0xffffff8009ea09b2` is read from `core_pattern`'s tail at boot
(`CORE_PATTERN = 0xffffff8009ea09b0`), so it matches the running kernel rather
than a hard-coded constant. The parked process ends as:

```
uid=0 euid=0 gid=2000 egid=2000 CapEff=ffffff8009ea09b2
```

The capability set is deliberately not `all`: it lacks `CAP_SETGID`,
`CAP_NET_ADMIN`, `CAP_NET_RAW` and `CAP_SYS_MODULE`. That is why the gid stays
2000 and why iptables-based apps cannot work (see
[Limitations](#limitations-honest-ones)). It is enough for `CAP_DAC_OVERRIDE`,
`CAP_SETUID`, `CAP_SETPCAP`, `CAP_SYS_ADMIN`-adjacent operations needed by the
su daemon and the module engine.

### 6. Serve root

The parked process listens on `/dev/socket/a12su` and implements the
KernelSU-style `su` protocol (see below). `su` and the shims are copied into a
tmpfs over-mounted on `/system_ext/bin`, which is on zygote's `PATH`, so every
app can find them.

---

## KernelSU-compatible userspace layer

| Piece | Surface |
|---|---|
| `su` | `-c/--command`, `-s/--shell`, `-u/--user`, `-g/--group`, `-G/--supp-group`, `-Z/--context`, `-M/--mount-master`, `-W`, `-l`, `-p`, `-v`, `-V`, `--ksu-no-new-privs`, positional user, `su <uid> -c cmd` |
| `ksud` | `--version`, `module install/list/enable/disable/uninstall/undo-uninstall/action/mount/unmount/config`, `late-load`, `post-fs-data`, `services`, `boot-completed`, `su`, `resetprop`, `feature`, `initrc`, `debug` |
| `magisk` | `-c/-v/-V`, `--path`, `--list-modules`, `--install-module`, `--remove-module(s)`, `--post-fs-data`, `--service`, `--boot-completed`, `su`, `resetprop` |
| `resetprop` | get/set/delete, `-p` persist, `-f` file, `-w` wait, `-v` |
| `a12mod.sh` | hot install, overlayfs mounts, `system.prop`, `REPLACE`/`REMOVE`, per-stage scripts, `action.sh`, module configs, prune, su repair |

Reported versions match the KernelSU contract:

```
su -v            v3.3.1:KernelSU
su -V            33001
ksud --version   v3.3.1 (uapi: 2)
magisk -v        25.2:MAGISK
magisk -V        25200
magisk --path    /data/adb/ksu/bin
```

### Module layout

```
/data/adb/modules/<id>/            installed module (system/, *.sh, module.prop)
/data/adb/modules_update/<id>/     hot staging during install
/data/adb/ksu/bin/                 ksud, magisk, resetprop, a12mod.sh
/data/adb/ksu/log/                 late-load.log, a12mod.log
/data/adb/ksu/module_configs/<id>/ config + action history
/data/adb/{post-fs-data,service,post-mount,boot-completed,late-load}.d/
```

Installs are **hot**: `modules_update/<id>` is moved to `modules/<id>` and
mounted immediately, no reboot. Overlays are mounted per first-level directory
(`/system/etc`, `/system/app`, `/vendor/etc`, …) so zygote's mount namespace
and every newly started app see them; already-running apps must be restarted.
`a12_repair_su` re-mounts the `/system_ext/bin` tmpfs and re-copies
`su/ksud/magisk/resetprop/a12mod.sh` after every mount pass, so module mounts
never break root.

### `su` wire protocol

One connection per command (or per persistent shell). Frames are
`1-byte type + 4-byte LE length + payload`:

```
client → daemon   'C' command   'I' shell stdin   'X' stdin EOF
                  'T' 4-byte target uid          'Z' SELinux context
daemon → client   'O' stdout    'E' stderr        'R' 4-byte exit code
                  'D' denial
```

stdout and stderr stay separate on purpose: libsu's job protocol writes its end
marker to both streams and would hang forever if they were merged. The magic
request `"\x01" "A12SHELL"` opens the persistent shell used by libsu-based apps
(Neo Backup, App Manager); the first `R` frame means "shell is up", the second
carries the exit code.

---

## The grant dialog

The first time an app asks for root, the daemon writes
`/data/local/tmp/a12su/req_<id>`, launches
`com.a12root.suapp/.PromptActivity` with `am start
--allow-background-activity-starts`, and waits up to 30 s for `ans_<id>`:

```
┌──────────────────────────────────────┐
│ A12 su                               │
│ Root access request                  │
│ uid 10259                            │
│ UID 10259 | su request               │
│ ┌──────────────────────────────────┐ │
│ │ (persistent shell)               │ │
│ └──────────────────────────────────┘ │
│ Always allow stores a rule in        │
│ /data/local/tmp/a12su/policy.        │
│                                      │
│   [ Deny ]  [ Allow ]  [ Always allow ] │
└──────────────────────────────────────┘
```

* `Always allow` appends `<uid> allow` to `/data/local/tmp/a12su/policy`.
* uid 0, 2000 (adb shell) and 10254 (the manager) are implicitly allowed.
* A one-shot `Allow` is cached in memory only for that process; a `Deny` is not
  cached, so the app is asked again next time.
* Nobody answers in 30 s → deny.

The harness only ever taps a dialog that names the **uid under test**. That
rule was added after a real incident: Shizuku's start-on-boot request stole the
dialog during Neo Backup's test and got granted by mistake. A root manager that
grants the wrong app is worse than one that shows no dialog, so the check is
mandatory.

---

## Demo root apps

All three are installed by the one-click, prompted through the dialog, and
verified by what they actually ran — not by what their UI claims.

| App | Package | What the harness proves |
|---|---|---|
| **Neo Backup** | `com.machiav3lli.backup` | `"toybox" ls -ld /` and its `checkroot.internal_sh` plugin ran in its root shell; the `ROOT missing` banner is gone |
| **App Manager** | `io.github.muntashirakon.AppManager` | libsu check (`echo`, `id`, `cd /`) plus `su <uid> -c keystore_cli_v2 list`; its `:priv:0` helper runs as uid 0; no `Root access is not available` |
| **Shizuku** | `moe.shizuku.privileged.api` | `Start (for rooted devices)` → grant → `shizuku_server` runs with `Uid: 0`; the manager reports `Shizuku is running` / `Version …, root` |

Shizuku is the interesting one: because the su shell is uid 0 and Shizuku's
starter keeps that uid, the server runs as **root**, not at the usual
ADB-level shell. Shizuku's own per-app authorization ("Authorized apps") is a
separate layer and is untouched.

---

## Usage

### Requirements

* Windows 10/11 with PowerShell 5.1+
* USB debugging enabled, RSA prompt accepted
* The phone unlocked at least once after boot
* Internet is **not** required (the package ships `adb` and all APKs)

### One click

1. Connect the phone by USB.
2. Double-click **`OneClickRoot.bat`**.
3. Wait 5–8 minutes. It reboots the phone (the exploit is one-shot per boot),
   runs the payload, verifies L1/L2/L3, checks the KernelSU layer, installs the
   manager and three root apps, drives each app's onboarding, taps
   `Always allow`, and verifies the root commands.
4. Read `evidence\` for logs, screenshots and per-app results.

Exit code `0` and a green `PASS` line mean everything above verified. A yellow
`PARTIAL` means root verified but an app or compatibility check failed — the
transcript says which.

### Manual mode

```powershell
adb push payload\exploit /data/local/tmp/a12exploit
adb shell chmod 755 /data/local/tmp/a12exploit
adb shell "LOG=/data/local/tmp/rootd.log SLOT0=0 setsid /data/local/tmp/a12exploit rootd </dev/null >/dev/null 2>&1 &"
adb shell "cat /data/local/tmp/rootd.log"     # wait for ROOTD READY
adb shell "/system_ext/bin/su -c id"
```

One exploit run per boot. If the box panics, it reboots itself; run again.

### If a boot panics

That is expected sometimes (see [Reliability](#reliability)). The harness
detects the reboot within ~10 s, pulls the previous boot's console from
`/sys/fs/pstore/console-ramoops-0`, and reuses the auto-rebooted boot for the
next attempt (up to 5). `/data` is untouched; nothing is bricked.

---

## What PASS means

```
L1  SELinux permissive                         getenforce → Permissive
L2  box alive                                  same boot_id, no spin, tasks sane
L3  kernel root                                uid=0 euid=0 CapEff=ffffff8009ea09b2
    su on PATH                                 /system_ext/bin/su -c id → uid=0(root)
    shell selftest                             SU shell test OK status=0
    KernelSU CLI                               su -v/-V, ksud --version, magisk -v/-V
    target uid                                 su 2000 -c 'id -u' → 2000
    resetprop                                  debug.* round-trip
    hot module install                         a12mod_test installed, overlay visible,
                                               service.sh ran with KSU=true
    manager                                    shows uid=0, sees the module overlay
    Neo Backup                                 dialog, grant, real root commands, no banner
    App Manager                                dialog, grant, libsu + keystore_cli_v2, no banner
    Shizuku                                    dialog, grant, shizuku_server uid 0, "root" mode
```

---

## Evidence

Everything below was produced by the shipped payload on the test device.

### Kernel proof

```
uid=0 euid=0 gid=2000 egid=2000 CapEff=ffffff8009ea09b2
uid=0(root) gid=2000(shell) groups=2000(shell),1004(input),1007(log),1011(adb),...
Uid:  0  0  0  0
Gid:  2000  2000  2000  2000
```

### KernelSU layer

```
v3.3.1:KernelSU
33001
v3.3.1 (uapi: 2)
25.2:MAGISK
25200
su 2000 -c id -u -> 2000
resetprop round-trip -> hello
```

Module install (hot, no reboot):

```
- Installing to /data/adb/modules_update/a12mod_test
- Extracting module files
- Running module installer
- Mounting modules
- Done
- Module installed successfully!
overlay file -> hello from a12 module overlay
service.sh -> service ran | KSU=true KSU_MODULE=a12mod_test KSU_VER=v3.3.1
```

### Payload hashes (SHA-256)

```
452e4ebad5a930878c457b532eb510848fe290aafea0278245c0196cba81cbb7  exploit
b436ad5b57702508bdb6dab1ae778233da6019a1adda0464c50c5480f2866895  su
45e7d85f9bfcceac8c3ea9b448faee30e81e71e4c35ac3d8aa2cced64097f73d  ksud
d29a8c84189d73b3d987dc436cbd45bfb76186d0e74858a9cd410182f1c87a76  magisk
ce9d9b2058cb025030531efa65d8be135018b1a8cdf541eec4d894bf80bf7e89  resetprop
b7617e9fce435f1105873075b65cd8f40059a1b0830368172817a83830e542c8  a12mod.sh
811c3179d486027615c16b6477e05896ebb5b2bfe6771eedab4b4caee66b9ca  SuApp.apk
4fcde9c7700b466d889e3877742ff25a32d7651f7982cc18fdbecf6248fb532c  a12mod_test.zip
6e273ab0e991c4e79bc8b1bbb9b9dd739ccac1a8712a541a214078886b7b790f  Shizuku.apk (v13.6.0)
```

See [docs/VERIFICATION.md](docs/VERIFICATION.md) for the full run table, boot
IDs, panic analysis and screenshot list.

---

## Reliability

The exploit is stochastic because the primitive is destructive: some erase
rounds corrupt the PI-futex waiter rbtree and the kernel data-aborts inside
`rb_erase_cached`.

```
el1_da
do_mem_abort
do_translation_fault
do_bad_area
die_kernel_fault
die
rb_erase_cached+0x30/0x398
remove_waiter+0x134/0x164
rt_mutex_cleanup_proxy_lock+0x54/0x94
futex_lock_pi+0x2b4/0x39c
do_futex
__arm64_sys_futex
el0_svc
```

The corrupted tree is the shared chain futex by design (each round's `O`
blocks on `f_pi_chain` and is requeued onto `f_pi_target`), so isolating rounds
would change the primitive rather than fix the bug. The tool therefore keeps a
retry model:

* one exploit run per boot;
* a panic reboots the box, `/data` is intact, nothing is bricked;
* the harness detects the reboot in ~10 s instead of waiting out the 150 s
  window, pulls `console-ramoops`, and reuses the fresh boot;
* up to 5 attempts.

**Measured on this device (shipped payload, 12 recorded runs):** 9 of 12
first-run boots reached L3 (75%); 12 of 12 reached L3 within three attempts.
Misses are panics, never logic failures, and the retry passes.

---

## Limitations (honest ones)

* **Memory-only, per boot.** Reboot = root gone, modules unmounted. Run the
  tool again.
* **No kernel driver.** The official KernelSU / KernelSU-Next / ReSukiSU /
  APatch / Magisk manager APKs cannot drive this stack — they need a kernel
  driver, `prctl(0xdeadbeef)`, `ksud late-load` of `kernelsu.ko`, or a patched
  boot image. Use the bundled A12 Root Manager.
* **Non-GKI, one firmware.** Addresses are hard-coded for kernel 4.19.188 on
  SM-A125F Android 12. A different build will not match.
* **Capability mask is partial.** No `CAP_SETGID`, `CAP_NET_ADMIN`,
  `CAP_NET_RAW`, `CAP_SYS_MODULE`: gid stays 2000, and iptables-based apps
  (AFWall+ etc.) cannot work.
* **Overlay limits.** A module cannot make an existing directory opaque
  (`setfattr trusted.overlay.opaque` needs `CAP_SYS_ADMIN`, which the mask
  lacks), so `REPLACE` is file-level. Running apps must be restarted to see a
  new module.
* **`resetprop` is best-effort.** `ro.*` is write-once and unknown namespaces
  are rejected by the property service (`error code: 0x18`). `debug.*` and
  `persist.sys.*` work.
* **The daemon is a demo root manager.** It accepts any local uid, the policy
  is a plain file in `/data/local/tmp`, and there is no per-command audit log
  beyond `rootd.log`. Do not treat it as a hardened security boundary.
* **Locked bootloader.** No persistent root, no custom kernel, no TWRP.

---

## Repository layout

```
README.md                     this file
LICENSE                       MIT
docs/METHOD.md                deep technical write-up (primitive, offsets, protocol)
docs/VERIFICATION.md          run table, panic analysis, evidence index
src/exploit/exploit_c.c       the exploit + su daemon (single C file)
src/su/su.c                   KernelSU-compatible su client
src/modules/a12mod.sh         module engine (hot install, overlayfs, scripts)
src/shims/ksud                KernelSU CLI shim
src/shims/magisk              Magisk CLI shim
src/shims/resetprop           property tool
src/manager/                  A12 Root Manager + grant dialog (Java + manifest)
src/harness/root.ps1          one-click orchestration + verification
src/harness/OneClickRoot.bat  double-click entry
src/harness/make_zip.ps1      reproducible module ZIP builder
payload/                      shipped binaries + test module + manager APK
evidence/                     screenshots and logs from verified runs
```

Third-party APKs (Neo Backup, App Manager, Shizuku) are **not** committed; they
are bundled in the release ZIP, with upstream links in
[docs/VERIFICATION.md](docs/VERIFICATION.md).

---

## Building from source

Exploit (Windows NDK clang, no `-lpthread`):

```powershell
.\ndk\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe `
  --target=aarch64-linux-android31 -O2 -fPIE -pie -Wall -Wextra `
  -o payload\exploit src\exploit\exploit_c.c
```

Manager APK (needs `javac`, `d8`, `apksigner`, `aapt`):

```powershell
.\src\manager\build_apk.ps1
```

Test module:

```powershell
.\src\harness\make_zip.ps1 -Source .\testmod -Out (Resolve-Path .\payload\a12mod_test.zip)
```

---

## Credits

This work stands on a lot of other people's work.

* **[NebuSec](https://nebusec.ai/buglist/CVE-2026-43499/)** — discovery, root
  cause analysis and the original exploitation of **GhostLock
  (CVE-2026-43499)**; reported to `security@kernel.org` on 2026-04-18, fixed
  2026-04-20, backported 2026-05-04, disclosed 2026-07-07; kernelCTF award.
  Their write-up ("IonStack part II") is the canonical description of the bug
  this exploit abuses.
* **Linux kernel rtmutex/locking maintainers** (Thomas Gleixner and
  co-maintainers) for the upstream fix
  (`rtmutex: Use waiter::task instead of current in remove_waiter()`) and the
  follow-up for CVE-2026-53166.
* **George Hotz (geohot)** — the original futex requeue-PI "fake lock"
  constrained-write technique from **Towelroot** (CVE-2014-3153), which is the
  direct ancestor of the primitive used here.
* **[KernelSU](https://github.com/tiann/KernelSU)** (tiann and contributors) —
  the `su`/`ksud` CLI contract, module layout, `module.prop` format and
  `late-load` model that this userspace layer emulates.
* **[Magisk](https://github.com/topjohnwu/Magisk)** (topjohnwu) — the
  `magisk`/`resetprop` CLI surface and module conventions.
* **[Shizuku](https://github.com/RikkaApps/Shizuku)** (RikkaApps) — the
  privileged-server model used as a demo root app.
* **[Neo Backup](https://github.com/NeoApplications/Neo-Backup)**
  (machiav3lli) and **[App Manager](https://github.com/MuntashirAkon/AppManager)**
  (Muntashir Akon) — libsu-based apps used as realistic root consumers.
* **Google kernelCTF** — the program that funded and validated the original
  GhostLock research.
* **AOSP / Samsung** — the kernel and userspace this runs on.

If you are one of these authors and want a correction or a different credit
line, open an issue.

---

## License

MIT — see [LICENSE](LICENSE). The exploit code is provided as-is, for
authorized testing on devices you own. No warranty; a kernel panic and reboot
is an expected failure mode.
