# Method

How the GhostLock primitive is turned into a working root shell on the Samsung
Galaxy A12 (SM-A125F, Android 12, kernel 4.19.188), and how the userspace
KernelSU layer is built on top of it.

This document assumes you have read the vulnerability section of the main
README. It is organised as: the primitive, the memory layout, one write
end-to-end, the credential rewrite, the su daemon, the module engine, and the
failure mode.

---

## 1. The primitive

The bug leaves `task->pi_blocked_on` pointing at an `rt_mutex_waiter` that lived
on a syscall stack frame which has already been freed. The waiter's memory is
reused by whatever runs next on that kernel stack, so an attacker who can
control that stack can control the waiter — and `pi_blocked_on` is traversed by
the rtmutex PI code, which walks `waiter->task`, `waiter->lock` and the lock's
rbtree.

Two consequences matter:

* **The traversal is a write gadget.** `rb_erase_cached()` on a node we
  fabricated performs the classic two stores:
  `*(node->__rb_parent_color) = ...` and the parent/child fixups. With a
  fabricated `rt_mutex_waiter` we get
  `*(A) = V` plus, when `V != 0`, a secondary `*(V) = (A - 8)`.
* **The traversal is destructive.** The rbtree being erased from is the *real*
  PI waiter tree of the futex we chained. Each round can corrupt it, and the
  next walk can fault. That is the source of the panics (section 7).

We do **not** use `PR_SET_MM_MAP` stack reclaim and we do **not** build a ROP
chain. The original GhostLock research used both; this port only needs data
writes, so the whole control-flow-hijack stage is unnecessary.

---

## 2. Kernel memory layout used

All addresses are for the SM-A125F Android 12 build of 4.19.188
(`a12sue`, `MT6765`). They are constants in `src/exploit/exploit_c.c`.

| Symbol | Address | Use |
|---|---|---|
| `SELINUX_STATE` | `0xffffff800a18ea40` | write `0` → permissive |
| `INIT_TASK` | `0xffffff8009e6b840` | task list head, `comm` = `swapper/0` |
| `TASKS_OFF` | `0x4a8` | `init_task.tasks` node offset |
| `HOSTNAME_DATA` | `0xffffff8009e88328` | `hostname_data` pointer (read carrier) |
| `MODPROBE_PATH` | `0xffffff8009e78340` | fake-lock slot storage (256 B, unused tail) |
| `POWEROFF_CMD` | `0xffffff8009e77e50` | more slot storage |
| `CORE_PATTERN` | `0xffffff8009ea09b0` | more slot storage + capability word |
| `REINIT_SCRATCH` | `MODPROBE_PATH + 0xf8` | SELinux state re-init trigger |

`task_struct` offsets used:

| Field | Offset |
|---|---|
| `tasks` (list node) | `+0x4a8` |
| `real_cred` | `+0x750` |
| `cred` | `+0x758` |
| `comm` | `+0x760` |

`struct cred` offsets used:

| Field | Offset | Field | Offset |
|---|---|---|---|
| `uid` | `+4` | `securebits` | `+36` |
| `gid` | `+8` | `cap_inheritable` | `+40` |
| `suid` | `+12` | `cap_permitted` | `+48` |
| `sgid` | `+16` | `cap_effective` | `+56` |
| `euid` | `+20` | `cap_bset` | `+64` |
| `egid` | `+24` | `cap_ambient` | `+72` |
| `fsuid` | `+28` | | |
| `fsgid` | `+32` | | |

The capability word is **not** hard-coded. `CAP_VALUE` is defined as
`CORE_PATTERN + 0x2`, i.e. it is *read at runtime* from the tail of the
`core_pattern` buffer, which on this kernel happens to contain
`0xffffff8009ea09b2` — a capability mask that matches the running build. Using
a value the kernel itself stored means the forged mask stays consistent if the
image is re-flashed with a slightly different config.

---

## 3. Threads and the dependency cycle

Four kinds of thread participate (`src/exploit/exploit_c.c`, `start_all()`):

| Thread | Role |
|---|---|
| `W` | holds `f_pi_chain` (`FUTEX_LOCK_PI`), then calls `FUTEX_WAIT_REQUEUE_PI(f_wait → f_pi_target)` |
| `O` | round 0: owns `f_pi_target`, then blocks on `f_pi_chain`. Later rounds: blocks on `f_pi_chain` only |
| `T` | at nice 19, blocks on `f_pi_target` (`FUTEX_LOCK_PI`) |
| `V` | victim, parked on a pipe until the cred swap is done |

The cycle:

```
W holds f_pi_chain
O0 owns f_pi_target, blocks on f_pi_chain          → O0 waits for W
T blocks on f_pi_target                            → T waits for O0
W waits on f_wait with target f_pi_target           → W waits for T
```

`W`'s requeue therefore asks the kernel to enqueue `W` behind `T`, who waits
for `O0`, who waits for `W`: a PI deadlock. The kernel detects it in
`rt_mutex_start_proxy_lock()` and rolls the proxy enqueue back through
`remove_waiter()`. Because of the bug, `pi_blocked_on` is cleared on the wrong
task and `W` returns to userspace with the stale pointer intact.

`W` then loops forever, servicing write requests. One `O` per round is created
and parked on `f_pi_chain`, so every round has a fresh waiter to steer.

### Planting the forged waiter

The freed waiter frame is inside `W`'s kernel stack. To control it, `W` uses its
own SIMD state as a stack-write primitive (`sig_plant()`):

1. Load `v0..v31` (512 bytes) with the forged `rt_mutex_waiter` fields.
2. `nanosleep()` — entering the kernel makes the kernel save the FP/SIMD
   state into the thread's kernel stack, exactly where the stale
   `pi_blocked_on` points.
3. `tgkill(self, SIG_PLANT)` — the handler returns through `rt_sigreturn`,
   which copies the 512 saved bytes back into the kernel stack.

After that, **nothing may enter the kernel** from `W` until the trigger, or the
forged bytes get overwritten by the next syscall's frame. The layout written:

| Lane | Field | Value |
|---|---|---|
| `v29`, `v32` | `waiter.tree_entry.__rb_parent_color` | `A - 8` |
| `v30` | `waiter.tree_entry.rb_right` | `V` |
| `v35` | `waiter.task` | `INIT_TASK` |
| `v36` | `waiter.lock` | slot address |
| `v37` | `waiter.prio` | `0x11` |

The trigger is a `tgkill` from the requesting thread: the kernel's next PI walk
over `W` dereferences `pi_blocked_on`, finds the forged waiter, and erases it
from the fake lock's rbtree.

### The fake lock

The lock must look like a zeroed, 16-byte-aligned `rt_mutex` (32 bytes:
`wait_lock`, `rb_root_cached`, `owner`) so the erase has a valid empty tree.
Seventeen such slots exist in kernel `.data` that are writable and unused after
boot:

```
MODPROBE_PATH + 0x10, 0x30, 0x50, 0x70, 0x90, 0xb0, 0xd0   (7)
POWEROFF_CMD  + 0x20, 0x40, 0x60, 0x80, 0xa0, 0xc0, 0xe0   (7)
CORE_PATTERN  + 0x20, 0x40, 0x60                            (3)
```

`MODPROBE_PATH + 0xd0` (slot 6) is avoided by convention, and
`REINIT_SCRATCH = MODPROBE_PATH + 0xf8` is reserved for the SELinux re-init
write. A clean run consumes 8 slots; the worst case (five credential-churn
rounds) consumes 16 of 17.

---

## 4. One write, end to end

`do_req(A, value, tag)` is the entire interface:

```
1. pick the next fake-lock slot, build pc = A - 8
2. wait for an O thread to be sleeping on f_pi_chain
3. publish {pc, value, slot} and bump the round counter
4. W plants the forged waiter (sig_plant) and acknowledges
5. tgkill(W) → PI walk → rb_erase on the forged node
6. *(A) = value      (and *(value) = A - 8 when value != 0)
7. wait for O to report completion; if O actually acquired the chain the
   round did not consume the plant, and do_req() fails instead of lying
```

Every request is logged:

```
REQ[3] l3tail      A=ffffff8009e88328 val=ffffff8009e6bce0 slot=ffffff8009e78370 pc=ffffff8009e88320 fp=...
```

The `fp=` field is the observed `pi_blocked_on` value; a request whose `fp`
does not point into `W`'s kernel stack is treated as a failed round.

### Reading kernel memory

There is no arbitrary read gadget, so reads go through a *carrier*: the
`hostname` sysctl. `HOSTNAME_DATA` holds a pointer; writing it makes
`/proc/sys/kernel/hostname` return the bytes at whatever it points to, as a C
string (stopping at the first `0x00`).

Because the primary write also performs the secondary `*(value) = A - 8`, the
carrier is aimed **16 bytes before** the qword of interest: the secondary store
clobbers the first 8 bytes at the target, and the qword lands at string offset
16, untouched.

```
do_req(HOSTNAME_DATA, task + 0x748)   →  hostname_data = &task.cred - 16
read  /proc/sys/kernel/hostname       →  bytes[16..23] = task->cred
                                         bytes[24..]    = task->comm
```

`0x748` is chosen exactly so that `+0x758` (`cred`) appears at offset 16 and
`+0x760` (`comm`) at offset 24.

### Walking to our own task

`init_task.tasks` is a circular list. Aiming the carrier at
`INIT_TASK + 0x4a0` (the node is at `+0x4a8`) yields `next` at offset 8 and
`prev` at offset 16. `prev` is the most recently created task, so
`cand = prev - 0x4a8` is a good first guess for our own `task_struct`; the code
then checks `comm` against `a12root` / `a12exploit` and walks `prev` backwards
up to 12 times.

---

## 5. The credential rewrite

A `cred` is only reachable if its pointer is readable, and the hostname carrier
is a C string — a `0x00` in the low byte of `cred` truncates the read.
`cred_jar` objects are 192 bytes, so roughly one in four lands on a `0x100`
boundary and is unreadable.

The exploit handles this with **credential churn** (`run_caps()`):

```
for k in 0..4:
    setresuid(2000,2000,2000)     # unchanged ids still call prepare_creds()
                                  # and allocate a fresh cred object
    fork a beacon (inherits comm "a12root"), parked on a pipe
    carrier-read the task list, find a task with comm "a12root"
    if its cred pointer is readable → rewrite and signal the beacon
    else kill the beacon and try again
```

Each round costs two slots (task-list tail + candidate). The beacon is the
process that gets the credentials, so the parent can keep churning without ever
being in a half-modified state.

Writes, in order:

| # | Target | Value | Why |
|---|---|---|---|
| 1 | `cred + 32` | `0` | clears `fsgid` (+32) **and** `securebits` (+36) as one qword |
| 2 | `cred + 48` | `CAP_VALUE` | `cap_permitted` |
| 3 | `cred + 56` | `CAP_VALUE` | `cap_effective` |
| 4 | `cred + 64` | `CAP_VALUE` | `cap_bset` (survives `execve`) |

Plus, before the loop:

| # | Target | Value | Why |
|---|---|---|---|
| 0a | `SELINUX_STATE` | `0` | permissive |
| 0b | `REINIT_SCRATCH` | `SELINUX_STATE + 3` | forces the SELinux state to be re-read so the current shell context is re-evaluated |
| 0c | `HOSTNAME_DATA` | `INIT_TASK + 0x4a0` | carrier setup |

The `securebits` write is the subtle one. Android shells run with
`securebits = 47` (`SECBIT_NOROOT | SECBIT_NOROOT_LOCKED | …`), so
`cap_bprm_set_creds()` deliberately skips `handle_privileged_root()` on `execve`
and a forged `cap_bset` would be ignored. Zeroing the qword at `+32` clears
`fsgid` and `securebits` together, which unblocks the root exec path so the
`su` shell actually keeps the mask.

Why `uid` is not in that list: the beacon does not need `uid 0` to run the su
daemon — it needs `CAP_SETUID`, `CAP_DAC_OVERRIDE` and `CAP_SETPCAP`, all
present in `CAP_VALUE`. The daemon then calls `setresuid(0,0,0)` for itself and
for every child. That is why `id_caps.out` shows
`Uid: 0 0 0 0` while the daemon's own credential rewrite touched only the
capability words.

Result:

```
uid=0 euid=0 gid=2000 egid=2000 CapEff=ffffff8009ea09b2
```

`gid` stays 2000 because `CAP_VALUE` has no `CAP_SETGID` (bit 6) and no
`CAP_NET_ADMIN`/`CAP_NET_RAW`/`CAP_SYS_MODULE`. This is a deliberate trade-off:
the missing bits are what keep the mask identical to a real kernel value, and
they cost only group-ownership changes and iptables apps.

---

## 6. The su daemon

The beacon becomes a daemon (`run_rootd()`): it binds `/dev/socket/a12su`,
installs the userspace stack, runs self-tests, and serves requests.

### Wire protocol

One connection per command, or per persistent shell. Frames are
`1-byte type + 4-byte LE length + payload`.

```
client → daemon
  'C'  command string            run and stream output
  'I'  shell stdin               (persistent shell)
  'X'  stdin EOF
  'T'  4-byte target uid         run as this uid (setuid before exec)
  'Z'  SELinux context           setexeccon() for the child

daemon → client
  'O'  stdout chunk
  'E'  stderr chunk
  'R'  4-byte exit code
  'D'  denial
```

stdout and stderr are kept separate on purpose. libsu's job protocol writes its
end marker to **both** streams and waits for both to be consumed; a merged
stream makes libsu-based apps hang forever on their root check.

The magic request `"\x01" "A12SHELL"` opens the persistent shell used by libsu
(Neo Backup, App Manager): the first `R` frame means "shell is up", the second
carries the real exit status. A persistent shell never logs `SU done` while the
app is alive — that is normal, and the harness verifies with the per-command log
instead.

### Grant policy

```
/data/local/tmp/a12su/req_<id>     request marker (written before the dialog)
/data/local/tmp/a12su/ans_<id>     answer, "allow" / "always" / "deny"
/data/local/tmp/a12su/policy       "<uid> allow" lines
```

`ask_user()` writes `req_<id>`, launches
`com.a12root.suapp/.PromptActivity` with
`am start --allow-background-activity-starts`, and polls for `ans_<id>` for
30 s. No answer means deny. Implicit allows: uid 0, 2000 (adb shell) and the
manager's own uid. A one-shot `Allow` is cached in memory for that process only;
`Deny` is not cached, so the next request prompts again.

The `Always allow` button appends to `policy`, so a granted app never asks
again — including across `su` invocations from different processes.

### Installing the stack

`install_stack()` copies `su`, `ksud`, `magisk`, `resetprop` and `a12mod.sh`
into `/data/adb/ksu/bin`, then over-mounts a tmpfs on `/system_ext/bin` and
copies `su` there. `/system_ext/bin` is on zygote's `PATH`, so every app and
every `adb shell` finds `su` without any environment setup.

`a12mod.sh` re-mounts that tmpfs and re-copies the binaries after each module
mount pass (`a12_repair_su`), so installing a module can never shadow `su`.

---

## 7. Module engine

`src/modules/a12mod.sh` implements the KernelSU module contract in shell.

### Layout

```
/data/adb/modules/<id>/              installed (system/, *.sh, module.prop)
/data/adb/modules_update/<id>/       staging during install
/data/adb/ksu/bin/                   ksud, magisk, resetprop, a12mod.sh
/data/adb/ksu/log/                   late-load.log, a12mod.log
/data/adb/ksu/module_configs/<id>/   config + action history
/data/adb/{post-fs-data,service,post-mount,boot-completed,late-load}.d/
```

### Install

```
ksud module install <zip>
  → unzip to modules_update/<id>
  → run customize.sh (KSU=true, KSU_MODULE=<id>, KSU_VER=v3.3.1)
  → move modules_update/<id> → modules/<id>
  → mount immediately (hot, no reboot)
  → run post-fs-data.sh, then service.sh
```

### Mounts

Overlayfs is mounted **per first-level directory** (`/system/etc`,
`/system/app`, `/vendor/etc`, …) rather than per file, so one mount covers a
whole tree and the number of mounts stays small. Zygote's mount namespace and
every newly started app see them; already-running apps must be restarted.

`REPLACE` and `REMOVE` are honoured at file level. A module cannot make an
existing directory opaque, because `setfattr trusted.overlay.opaque` needs
`CAP_SYS_ADMIN`, which `CAP_VALUE` lacks.

### Stages

`post-fs-data.sh`, `service.sh`, `post-mount.sh`, `boot-completed.sh` and
`action.sh` are run with `KSU`, `KSU_MODULE`, `KSU_VER` and `KSU_KERNEL_VER`
exported. `ksud module action <id>` runs `action.sh` and records the result in
`module_configs/<id>/`.

### Shims

`ksud`, `magisk` and `resetprop` are shell shims that source `a12mod.sh`. Each
does its own root check per command: `module`, `stage`, `resetprop` and
`sepolicy` require root, while `--version`, `--help` and `feature` work for
anyone — matching KernelSU's behaviour, where the manager app can query
versions without a root grant.

---

## 8. The failure mode

The erase that produces each write also perturbs the PI waiter rbtree of the
chained futex. Occasionally the next walk follows a corrupted link:

```
el1_da → do_mem_abort → do_translation_fault → do_bad_area → die_kernel_fault → die
rb_erase_cached+0x30/0x398
remove_waiter+0x134/0x164
rt_mutex_cleanup_proxy_lock+0x54/0x94
futex_lock_pi+0x2b4/0x39c
do_futex
__arm64_sys_futex
el0_svc
```

This is intrinsic, not a bug in the port: the corrupted tree *is* the shared
chain futex, by construction. Isolating rounds (a fresh futex per write) would
change the primitive, because the whole point of the chain is that each `O`
waiter is requeued onto the target we control.

So the exploit is stochastic, and the tool is built around that:

* one exploit run per boot;
* a panic reboots the box; `/data` is untouched and the bootloader stays locked
  and happy;
* the harness detects the reboot in ~10 s (rather than waiting out the 150 s
  window), pulls the previous boot's console from
  `/sys/fs/pstore/console-ramoops-0` into `evidence/miss_<bootid>_pstore.log`,
  and reuses the auto-rebooted boot for the next attempt;
* up to 5 attempts, one high-information probe per boot.

Observed: 9 of 12 first boots reached L3 (75%), 12 of 12 within three attempts.

---

## 9. Why not a kernel driver

Everything below was checked on the device, not assumed:

| Solution | Blocker |
|---|---|
| KernelSU / KernelSU-Next | manager requires a GKI kernel with `CONFIG_KSU`; this is non-GKI 4.19 Samsung, and there is no `prctl(0xdeadbeef)` handler |
| APatch | installs by patching `boot.img` and flashing — bootloader is locked (`ro.boot.flash.locked=1`, `sys.oem_unlock_allowed=0`) |
| Magisk | patches the boot ramdisk — same blocker |
| ReSukiSU | same GKI/`CONFIG_KSU` requirement |
| `ksud late-load` + prebuilt `kernelsu.ko` | `CONFIG_MODULES` module loading is not permitted for our context, and the `.ko` must match the kernel exactly |

Hence a userspace su daemon plus a KernelSU-shaped CLI, and a bespoke manager
app instead of the official one.
