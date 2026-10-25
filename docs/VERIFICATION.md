# Verification

Everything in this file was produced on the physical test device by the shipped
payload. Nothing here is a projection or an estimate.

---

## Test device

| | |
|---|---|
| Model | Samsung Galaxy A12 (SM-A125F) |
| SoC | MediaTek Helio P35 (MT6765) |
| Android | 12 |
| Build kernel | `4.19.188` (non-GKI) |
| Bootloader | locked (`ro.boot.flash.locked=1`, `sys.oem_unlock_allowed=0`) |
| SELinux at boot | Enforcing, `u:r:shell:s0` |
| Host | Windows 10/11, PowerShell 5.1, USB ADB |

---

## Run table

Twelve recorded one-click runs. "First attempt" is the verdict on the boot the
run started on; a `MISS` is always a kernel panic in the fake-lock erase, never
a logic failure.

| Run | Boot ID | First attempt | Outcome |
|---|---|---|---|
| 1 | (bring-up, not recorded) | PASS | L3 + KernelSU layer |
| 2 | (bring-up, not recorded) | PASS | L3 + KernelSU layer |
| 3 | (bring-up, not recorded) | MISS (panic) | attempt 2 PASS |
| 4 | `ddab04dc-e1a9-4218-8e6e-86dd2ee80055` | PASS | L3 + KernelSU + module checks all true |
| 5 | `78e005c0-8708-4064-b56c-4f84316e0e70` | MISS (panic) | attempt 2 `5b2c8090-a72d-4b46-960d-4589e7d1b48b` PASS |
| 6 | `31c5c047-3e1d-4252-a8f0-7ee2551661e4` | PASS | L3 + KernelSU + module checks all true |
| 7 | `f2245382-7906-4681-97f4-ee08640ab7cd` | PASS | L3 + KernelSU + module checks all true |
| 8 | `e8e6bc3a-9c71-4385-9ea3-cffaded4a6ad` | MISS (panic) | attempt 2 `15d38df5-a2b1-4764-9b64-a4badfa0c9e5` MISS, attempt 3 `d7c25429` PASS |
| 9 | `0121399f-73d6-42ea-8eca-1e87700ba0b6` | root hit, verdict PARTIAL | harness detection gap (see below) |
| 10 | `8945f725-3e7b-488a-9da6-956f2bacad3e` | PASS | prompt detection fixed |
| 11 | `ec96bd80-4a7e-4caf-809a-4641e21295a8` | PASS | Shizuku added; exposed a mis-grant bug |
| 12 | `d7c937ec-49e6-4f38-ba2c-a760c05cb262` | PASS | uid-aware grants + fresh Shizuku install |

**Tally:** 9 of 12 first boots reached L3 (75%); 8 of 12 reached full `PASS` on
the first boot; 12 of 12 within three attempts. Run 9 is counted as an L3 hit
because root was obtained — only the harness's verdict was wrong.

### Run 9 — the detection gap (and why it is listed)

The exploit hit on attempt 1 and `id -u` returned 0, but the harness reported
`PARTIAL`. The cause was in the harness, not the exploit: it decided whether a
grant dialog had appeared by diffing the UI dump *before* and *after* launching
the app. Neo Backup's dialog was answered (by the timeout) between the two
dumps, so the "before" dump already contained a prompt and the diff was empty.

Fixed by asking the daemon instead of the screen: `Count-Prompts <uid>` counts
`SU prompt uid=<uid>` lines in `rootd.log`, and `Get-PendingPrompt` looks for a
`req_<id>` with no matching `ans_<id>`. Run 10 validated the fix.

### Run 11 — the mis-grant (and why the harness got stricter)

Shizuku, once started, registers a start-on-boot request. On run 11 that
request fired while Neo Backup was under test, took over the single visible
dialog, and the harness tapped `Always allow` on it. Root was granted to the
wrong app.

Two fixes, both in the shipped harness:

1. `Grant-Prompt <uid>` refuses to tap a dialog whose text does not contain
   `uid <uid>`.
2. The harness uninstalls Shizuku before the run and reinstalls it in the app
   phase, so the request it drives is the first one.

Run 12 confirmed correct attribution: 10259 → Neo Backup, 10257 → App Manager,
10253 → Shizuku.

---

## Run 12 — full transcript of the verified state

```
=== A12 one-shot root (CVE-2026-43499) ===
Payload: kernel uid 0 + forged caps + su daemon + grant dialog + root apps
Device: SM-A125F / 12

[attempt 1/5] fresh boot (one exploit run per boot)
  boot_id: d7c937ec-49e6-4f38-ba2c-a760c05cb262
  pushing payload
  running exploit (rootd)
  --- KernelSU compatibility ---
v3.3.1:KernelSU
33001
v3.3.1 (uapi: 2)
25.2:MAGISK
25200
  su 2000 -c id -u -> 2000
  resetprop round-trip -> hello
  --- module install (hot) ---
- Installing to /data/adb/modules_update/a12mod_test
- Extracting module files
- Running module installer
- Module size: 31K
- Mounting modules
- Done
- Module installed successfully!
  overlay file -> hello from a12 module overlay
  service.sh -> service ran | KSU=true KSU_MODULE=a12mod_test KSU_VER=v3.3.1

  --- kernel proof (rootproof.txt) ---
uid=0 euid=0 gid=2000 egid=2000 CapEff=ffffff8009ea09b2
  --- id_caps.out ---
0
uid=0(root) gid=2000(shell) groups=2000(shell),1004(input),1007(log),1011(adb),1015(sdcard_rw),1028(sdcard_r),1078(ext_data_rw),1079(ext_obb_rw),3001(net_bt_admin),3002(net_bt),3003(inet),3006(net_bw_stats),3009(readproc),3011(uhid) context=u:r:shell:s0
Uid:	0	0	0	0
Gid:	2000	2000	2000	2000
  --- /system_ext/bin/su -c id (from adb shell) ---
uid=0(root) gid=2000(shell) groups=2000(shell),1004(input),1007(log),1011(adb),...
  --- su daemon selftest (uid 2000) ---
uid=0(root) ... 0
  --- interactive shell selftest ---
[84956] SU shell test OK status=0 out='SHELL_TEST

[apps] installing manager + root apps
  payload\SuApp.apk -> Success
  payload\apps\NeoBackup.apk -> Success
  payload\apps\AppManager.apk -> Success
  payload\apps\Shizuku.apk -> Success

[app] neobackup (com.machiav3lli.backup)
  uid=10259
  PROMPT VISIBLE
  tapped grant: True
  decision: [156801] SU decision uid=10259 allow=1
  shell cmds: [157467] SU shellcmd uid=10259 '"toybox" ls -ld /' ...
              [157703] SU shellcmd uid=10259 'sh .../checkroot.internal_sh' ...
  still shows 'ROOT missing': False
  app ran root commands successfully: True

[app] appmanager (io.github.muntashirakon.AppManager)
  uid=10257
  PROMPT VISIBLE
  tapped grant: True
  decision: [227230] SU decision uid=10257 allow=1
  shell cmds: [251926] SU shellcmd uid=10257 'su 1000 -c keystore_cli_v2 list' ...
              [252029] SU shellcmd uid=10257 'su 10019 -c keystore_cli_v2 list' ...
  still shows 'Root access is not available': False
  app ran root commands successfully: True

[app] Shizuku (moe.shizuku.privileged.api)
  uid=10253
  tapped Start (rooted): True
  PROMPT VISIBLE
  tapped grant: True
  shizuku_server pid: 10802
  running: True  root mode: True
  server cred: Uid:	0	0	0	0
  Shizuku rooted and running: True

[app] A12 su manager
  manager shows uid=0: True
  app process sees module overlay: hello from a12 module overlay

--- grant policy ---
10259 allow
10257 allow
10253 allow

KernelSU compatibility: version=True modules=True target-uid=True resetprop=True app-overlay=True
PASS: kernel root, su on PATH, grant dialog shown, Neo Backup / App Manager / Shizuku granted root,
      KernelSU-compatible CLI (ksud/magisk/su) and hot module install verified
```

Note the two `allow=0` decisions before Neo's `allow=1`: the first tap on a
freshly shown dialog can be consumed as a window focus, so the dialog auto-denies
after 30 s and the daemon asks again. `Grant-Prompt` polls the daemon-side
decision and retries, which is why the final state is `allow=1`. It costs ~40 s
per app that hits it. The harness verifies the *decision*, not the tap.

---

## Independent checks you can repeat

On the rooted boot, from `adb shell`:

```sh
id -u                                     # 0
su -c id                                  # uid=0(root) gid=2000(shell) ...
su -v                                     # v3.3.1:KernelSU
su -V                                     # 33001
su 2000 -c 'id -u'                        # 2000   (target-uid frame works)
ksud --version                            # v3.3.1 (uapi: 2)
magisk -v                                 # 25.2:MAGISK
magisk --path                             # /data/adb/ksu/bin
resetprop debug.a12 hello && getprop debug.a12   # hello
ksud module list                          # JSON array of installed modules
cat /system/etc/a12mod_test.txt           # hello from a12 module overlay
grep -c '' /data/local/tmp/a12su/policy   # number of granted uids
```

Shizuku:

```sh
pidof shizuku_server                      # pid, owned by root
grep ^Uid /proc/$(pidof shizuku_server)/status   # Uid: 0 0 0 0
```

and its UI must say `Shizuku is running` / `Version …, root`.

---

## Panic analysis (why a miss looks like a miss)

Captured from `/sys/fs/pstore/console-ramoops-0` after run 8's first miss
(boot `e8e6bc3a`), reproduced identically on the other misses:

```
[   84.560306] -(5)[4998:a12main] die+0xc8/0x408
[   84.560317] -(5)[4998:a12main] die_kernel_fault+0x78/0x88
[   84.560334] -(5)[4998:a12main] do_bad_area+0x4c/0xbc
[   84.560345] -(5)[4998:a12main] do_translation_fault+0x58/0x6c
[   84.560354] -(5)[4998:a12main] do_mem_abort+0x5c/0x124
[   84.560363] -(5)[4998:a12main] el1_da+0x1c/0xac
[   84.560372] -(5)[4998:a12main] rb_erase_cached+0x30/0x398
[   84.560382] -(5)[4998:a12main] remove_waiter+0x134/0x164
[   84.560390] -(5)[4998:a12main] rt_mutex_cleanup_proxy_lock+0x54/0x94
[   84.560399] -(5)[4998:a12main] futex_lock_pi+0x2b4/0x39c
[   84.560408] -(5)[4998:a12main] do_futex+0xbcc/0x11d8
```

Read bottom-up: a later round's `FUTEX_LOCK_PI` on the chained futex walks the
PI waiter tree that an earlier erase left inconsistent, and faults on a bad
link inside `rb_erase_cached`. The task that dies is `a12main` — the process
performing writes — at ~84 s uptime, i.e. mid-chain, not at setup.

`rootd.log` for the same boot ends mid-request:

```
[84500] MATCH beacon cred=ffffffc0c7acd540
[84503] REQ[5] cred_secbits ...
[84506] REQ[6] cred_prm    ...
```

so the crash is in the write immediately after `cap_permitted` was forged. The
credential state was already partially modified when the box went down — which
is exactly why the tool treats a reboot as a full reset and never tries to
resume a half-written chain.

Each miss produced three files:

```
evidence/miss_<bootid>_rootd.log     last rootd lines before the crash
evidence/miss_<bootid>_dmesg.log     post-reboot dmesg (usually empty)
evidence/miss_<bootid>_pstore.log    console-ramoops from the crashed boot
```

and the harness then reused the auto-rebooted boot for the next attempt instead
of issuing another `adb reboot`.

---

## Evidence index

All files in `evidence/` come from run 12 unless the name says otherwise.

| File | Contents |
|---|---|
| `run.log` | full harness transcript |
| `rootd.log` | exploit + su daemon log (requests, grants, commands) |
| `id_caps.out` | `id -u`, `id`, `/proc/self/status` from the root child |
| `rootproof.txt` (on device) | `uid=0 euid=0 gid=2000 egid=2000 CapEff=ffffff8009ea09b2` |
| `su_selftest.out` | `su -c` and interactive shell selftests |
| `ksu-version.txt` | `su -v`, `su -V`, `ksud --version`, `magisk -v`, `magisk -V` |
| `modules.txt` | `ksud module list` JSON |
| `late-load.log` | KernelSU-style late-load stage log |
| `a12mod.log` | module engine log (mounts, scripts, repairs) |
| `policy.txt` | granted uids |
| `prompt_neobackup.png` | grant dialog for uid 10259 |
| `prompt_appmanager.png` | grant dialog for uid 10257 |
| `prompt_shizuku.png` | grant dialog for uid 10253 |
| `after_neobackup.png` | Neo Backup after the grant, no `ROOT missing` banner |
| `after_appmanager.png` | App Manager after the grant |
| `after_shizuku.png` | Shizuku `Shizuku is running` / `Version …, root` |
| `shizuku_starter.png` | Shizuku starter at `Starting with root…` |
| `suapp.png`, `suapp_ui.xml` | A12 Root Manager showing `uid=0` |
| `neobackup_ui.xml`, `appmanager_ui.xml`, `shizuku_ui.xml` | raw UI dumps backing the verdicts |
| `miss_*_rootd.log`, `miss_*_dmesg.log`, `miss_*_pstore.log` | the three recorded panics |

---

## Payload hashes (SHA-256)

Shipped binaries, exactly as in the release ZIP:

```
452e4ebad5a930878c457b532eb510848fe290aafea0278245c0196cba81cbb7  exploit
b436ad5b57702508bdb6dab1ae778233da6019a1adda0464c50c5480f2866895  su
45e7d85f9bfcceac8c3ea9b448faee30e81e71e4c35ac3d8aa2cced64097f73d  ksud
d29a8c84189d73b3d987dc436cbd45bfb76186d0e74858a9cd410182f1c87a76  magisk
ce9d9b2058cb025030531efa65d8be135018b1a8cdf541eec4d894bf80bf7e89  resetprop
b7617e9fce435f1105873075b65cd8f40059a1b0830368172817a83830e542c8  a12mod.sh
811c3179d486027615c16b6477e05896ebb5b2bfe6771eedab4b4caee66b9ca  SuApp.apk
4fcde9c7700b466d889e3877742ff25a32d7651f7982cc18fdbecf6248fb532c  a12mod_test.zip
```

---

## Third-party APKs

Not committed to the repository (size + upstream licensing). They are bundled in
the release ZIP; verify against upstream:

| App | Version | Package | SHA-256 | Upstream |
|---|---|---|---|---|
| Neo Backup | 8.3.18 (8331) | `com.machiav3lli.backup` | `1485c964ba52b45c1057c2d6f7299286e456c61109f381d842c094ab5ec7e9c6` | <https://github.com/NeoApplications/Neo-Backup/releases> |
| App Manager | 4.1.1 (451) | `io.github.muntashirakon.AppManager` | `e1f6ba10812c74016ad626e11e27a1ae450aec2c0964a11466abb9e7a9c8ef84` | <https://github.com/MuntashirAkon/AppManager/releases> |
| Shizuku | 13.6.0.r1086 (1086) | `moe.shizuku.privileged.api` | `6e273ab0e991c4e79bc8b1bbb9b9dd739ccac1a8712a541a214078886b7b790f` | <https://github.com/RikkaApps/Shizuku/releases/tag/v13.6.0> |

The A12 Root Manager (`payload/SuApp.apk`, `com.a12root.suapp` 1.2 / 3) is built
from `src/manager/` in this repository.

---

## What is *not* verified

Being explicit about the boundaries:

* **No persistence across reboot.** Reboot = root gone. Not claimed, not tested.
* **One firmware.** All addresses are for `4.19.188` on SM-A125F Android 12.
  A different build is expected to fail (and may panic).
* **No `iptables` / `AFWall+`.** The capability mask has no `CAP_NET_ADMIN` or
  `CAP_NET_RAW`; AFWall+ was tested and dropped for this reason.
* **No `CAP_SETGID`.** Supplementary groups and gid changes do not work; the
  shell stays in gid 2000.
* **No module that needs `CAP_SYS_ADMIN`.** Directory-level opaque overlays are
  not possible; file-level `REPLACE` is.
* **The daemon is not a hardened security boundary.** It accepts any local uid,
  its policy is a plain file under `/data/local/tmp`, and it logs to
  `rootd.log`. Do not treat it as a production root manager.
* **`resetprop` is best-effort.** `debug.*` and `persist.sys.*` work; `ro.*` is
  write-once and unknown namespaces are rejected by the property service.
