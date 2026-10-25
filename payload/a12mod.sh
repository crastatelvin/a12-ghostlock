#!/system/bin/sh
# a12mod.sh - KernelSU-compatible module engine for the A12 root.
#
# Sourced by ksud/magisk.  Everything here runs as uid 0.
#
# Layout (matches KernelSU):
#   /data/adb/modules/<id>/module.prop      installed modules
#   /data/adb/modules_update/<id>/          staging during install
#   /data/adb/ksu/bin/                      su, ksud, magisk, resetprop, this file
#   /data/adb/ksu/log/                      logs
#   /data/adb/ksu/mount/                    overlay upper/work dirs (session only)
#   /data/adb/ksu/module_configs/<id>/      persist.config / tmp.config
#   /data/adb/{post-fs-data,service,post-mount,boot-completed,late-load}.d/
#
# Modules are applied with per-directory overlayfs mounts.  A mount made in
# this namespace propagates to zygote (the root mount is shared), so a new app
# process sees the module files; an already-running app must be restarted.

ADB=/data/adb
KSUD=$ADB/ksu
BIN=$KSUD/bin
MODS=$ADB/modules
MODU=$ADB/modules_update
LOGD=$KSUD/log
MNTD=$KSUD/mount
CFGD=$KSUD/module_configs
KSU_VER=v3.3.1
KSU_VER_CODE=33001
KSU_UAPI_VER=2

a12_now() { date '+%Y-%m-%d %H:%M:%S'; }
a12_log() {
  mkdir -p "$LOGD" 2>/dev/null
  echo "[$(a12_now)] $*" >> "$LOGD/a12mod.log" 2>/dev/null
}
a12_msg() { echo "$*"; }
a12_err() { echo "$*" >&2; }

a12_ensure() {
  mkdir -p "$KSUD" "$BIN" "$LOGD" "$MODS" "$MODU" "$CFGD" 2>/dev/null
  mkdir -p "$ADB/post-fs-data.d" "$ADB/service.d" "$ADB/post-mount.d" \
           "$ADB/boot-completed.d" "$ADB/late-load.d" "$ADB/magisk" 2>/dev/null
  chmod 700 "$ADB" "$KSUD" 2>/dev/null
  chmod 755 "$BIN" "$MODS" "$MODU" 2>/dev/null
}

a12_env() {
  export KSU=true
  export KSU_VER KSU_VER_CODE KSU_UAPI_VER
  export KSU_KERNEL_VER_CODE=$KSU_VER_CODE
  export KSU_RUNTIME_MODE=late-load
  export KSU_LATE_LOAD=1
  export ASH_STANDALONE=1
  export MAGISK_VER=25.2
  export MAGISK_VER_CODE=25200
  export BOOTMODE=true
  export ARCH=arm64
  export IS64BIT=true
  export API=31
  export PATH="$PATH:$BIN"
}

a12_json_esc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'
}

# a12_prop <module.prop> <key>
a12_prop() {
  [ -f "$1" ] || return 1
  grep -m1 "^$2=" "$1" 2>/dev/null | sed "s/^$2=//" | tr -d '\r' | sed 's/[[:space:]]*$//'
}

a12_valid_id() {
  case "$1" in
    [A-Za-z]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ ${#1} -ge 2 ] || return 1
  return 0
}

a12_enabled() {
  [ -d "$1" ] || return 1
  [ -e "$1/disable" ] && return 1
  [ -e "$1/remove" ] && return 1
  return 0
}

a12_rev_lines() { awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}'; }

# a12_run_script <path> [fg|bg] [timeout-seconds]
a12_run_script() {
  [ -f "$1" ] || return 0
  a12_sdir=${1%/*}
  a12_swait=${2:-fg}
  a12_stmo=${3:-30}
  if [ "$a12_swait" = bg ]; then
    ( cd "$a12_sdir" && timeout "$a12_stmo" sh "$1" ) >>"$LOGD/scripts.log" 2>&1 &
    a12_log "script(bg) $1"
  else
    ( cd "$a12_sdir" && timeout "$a12_stmo" sh "$1" ) >>"$LOGD/scripts.log" 2>&1
    a12_log "script(fg) $1 rc=$?"
  fi
}

# a12_stage <post-fs-data|post-mount|service|boot-completed|late-load>
a12_stage() {
  a12_env
  a12_stage_name=$1
  case "$a12_stage_name" in
    post-fs-data)  a12_gdir=$ADB/post-fs-data.d;  a12_wait=fg; a12_tmo=10 ;;
    post-mount)    a12_gdir=$ADB/post-mount.d;    a12_wait=fg; a12_tmo=30 ;;
    service)       a12_gdir=$ADB/service.d;       a12_wait=bg; a12_tmo=300 ;;
    boot-completed) a12_gdir=$ADB/boot-completed.d; a12_wait=bg; a12_tmo=300 ;;
    late-load)     a12_gdir=$ADB/late-load.d;     a12_wait=fg; a12_tmo=30 ;;
    *) a12_err "ksud: unknown stage $a12_stage_name"; return 1 ;;
  esac
  for a12_f in "$a12_gdir"/*; do
    [ -f "$a12_f" ] || continue
    [ -x "$a12_f" ] || continue
    a12_run_script "$a12_f" "$a12_wait" "$a12_tmo"
  done
  for a12_m in "$MODS"/*; do
    a12_enabled "$a12_m" || continue
    a12_export_mod "$a12_m"
    a12_run_script "$a12_m/$a12_stage_name.sh" "$a12_wait" "$a12_tmo"
    unset KSU_MODULE
  done
}

a12_export_mod() { export KSU_MODULE=${1##*/}; }

# ------------------------------------------------------------------ props
a12_load_props() {
  a12_env
  for a12_m in "$MODS"/*; do
    a12_enabled "$a12_m" || continue
    [ -f "$a12_m/system.prop" ] || continue
    a12_log "system.prop $a12_m"
    "$BIN/resetprop" -n --file "$a12_m/system.prop" >>"$LOGD/scripts.log" 2>&1
  done
}

# ------------------------------------------------------------------ install
a12_clean_install_artifacts() {
  rm -rf "$1/customize.sh" "$1/README.md" "$1/.git" "$1/.gitignore" \
         "$1/.github" "$1/.ksu_hot_install" 2>/dev/null
}

a12_mark_remove() {
  mkdir -p "${1%/*}" 2>/dev/null
  mknod "$1" c 0 0 2>/dev/null || return 1
  chmod 644 "$1" 2>/dev/null
  return 0
}

a12_install() {
  a12_zip=$1
  a12_ensure
  a12_env
  if [ -z "$a12_zip" ]; then
    a12_err "ksud: module install <zip>"
    return 1
  fi
  if [ ! -f "$a12_zip" ]; then
    a12_err "ksud: no such file: $a12_zip"
    return 1
  fi
  a12_zip=$(readlink -f "$a12_zip")
  a12_tmp=$KSUD/tmp/install.$$
  rm -rf "$a12_tmp"; mkdir -p "$a12_tmp" || return 1

  unzip -o -d "$a12_tmp" "$a12_zip" module.prop >/dev/null 2>&1
  if [ ! -f "$a12_tmp/module.prop" ]; then
    a12_err "- Error: module.prop not found at the ZIP root"
    rm -rf "$a12_tmp"
    return 1
  fi

  a12_id=$(a12_prop "$a12_tmp/module.prop" id)
  a12_name=$(a12_prop "$a12_tmp/module.prop" name)
  a12_auth=$(a12_prop "$a12_tmp/module.prop" author)
  a12_ver=$(a12_prop "$a12_tmp/module.prop" version)
  a12_vcode=$(a12_prop "$a12_tmp/module.prop" versionCode)
  if ! a12_valid_id "$a12_id"; then
    a12_err "- Error: invalid module id '$a12_id' (must match ^[a-zA-Z][a-zA-Z0-9._-]+$)"
    rm -rf "$a12_tmp"
    return 1
  fi

  a12_modpath=$MODU/$a12_id
  rm -rf "$a12_modpath"; mkdir -p "$a12_modpath" || return 1

  a12_msg ""
  a12_msg "*******************************"
  a12_msg " $a12_name"
  a12_msg " by $a12_auth"
  a12_msg "*******************************"
  a12_msg "*******************************"
  a12_msg " Powered by KernelSU (A12)"
  a12_msg "*******************************"
  a12_msg ""
  a12_msg "- Installing to $a12_modpath"
  a12_msg "- Extracting module files"

  unzip -o -d "$a12_modpath" "$a12_zip" customize.sh >/dev/null 2>&1
  a12_skip=0
  if [ -f "$a12_modpath/customize.sh" ] && grep -q '^SKIPUNZIP=1' "$a12_modpath/customize.sh" 2>/dev/null; then
    a12_skip=1
  fi
  if [ "$a12_skip" = 0 ]; then
    unzip -o -d "$a12_modpath" "$a12_zip" -x 'META-INF/*' >/dev/null 2>&1
    # ziptool wants the exclude list after the include list; retry if the
    # first form left META-INF behind.
    if [ -d "$a12_modpath/META-INF" ]; then
      rm -rf "$a12_modpath/META-INF"
    fi
    find "$a12_modpath" -type d -exec chmod 755 {} + 2>/dev/null
    find "$a12_modpath" -type f -exec chmod 644 {} + 2>/dev/null
    # Binaries and scripts stay executable; a module that ships a helper in
    # system/bin must not end up with mode 644.
    find "$a12_modpath" -type f -name '*.sh' -exec chmod 755 {} + 2>/dev/null
    for a12_bd in system/bin system/xbin system_ext/bin vendor/bin product/bin odm/bin; do
      [ -d "$a12_modpath/$a12_bd" ] && find "$a12_modpath/$a12_bd" -type f -exec chmod 755 {} + 2>/dev/null
    done
    chown -R 0:0 "$a12_modpath" 2>/dev/null
  fi

  a12_msg "- Running module installer"
  a12_msg "- Module size: $(du -sh "$a12_modpath" 2>/dev/null | cut -f1)"

  a12_zipfile=$a12_zip
  a12_tmpdir=$a12_tmp
  a12_oldpwd=$(pwd)
  cd "$a12_tmp" || cd /
  # Helpers KernelSU exposes to customize.sh
  ui_print() { a12_msg "$1"; }
  abort() { a12_msg "! $1"; cd "$a12_oldpwd" 2>/dev/null; rm -rf "$a12_modpath" "$a12_tmp"; return 1; }
  set_perm() {
    chown "$2:$3" "$1" 2>/dev/null
    chmod "$4" "$1" 2>/dev/null
    [ -n "$5" ] && chcon "$5" "$1" 2>/dev/null
    return 0
  }
  set_perm_recursive() {
    find "$1" -type d 2>/dev/null | while IFS= read -r a12_d; do set_perm "$a12_d" "$2" "$3" "$4" "$6"; done
    find "$1" -type f -o -type l 2>/dev/null | while IFS= read -r a12_f2; do set_perm "$a12_f2" "$2" "$3" "$5" "$6"; done
  }
  mktouch() { mkdir -p "${1%/*}" 2>/dev/null; [ -n "$2" ] && echo "$2" > "$1" || touch "$1"; chmod 644 "$1" 2>/dev/null; }
  mark_remove() { a12_mark_remove "$1"; }
  print_modname() { :; }
  grep_prop() {
    a12_re=$1; shift
    a12_files=$*
    [ -n "$a12_files" ] || a12_files=/system/build.prop
    cat $a12_files 2>/dev/null | tr -d '\r' | sed -n "s/^$a12_re=//p" | head -n 1
  }
  grep_get_prop() {
    a12_r=$(grep_prop "$@")
    [ -n "$a12_r" ] || a12_r=$(getprop "$1")
    echo "$a12_r"
  }
  is_mounted() { mountpoint -q "$1" 2>/dev/null; }
  toupper() { echo "$@" | tr '[:lower:]' '[:upper:]'; }
  MODPATH=$a12_modpath
  TMPDIR=$a12_tmpdir
  ZIPFILE=$a12_zipfile
  if [ -f "$a12_modpath/customize.sh" ]; then
    . "$a12_modpath/customize.sh" || { a12_err "- Error: customize.sh failed"; cd "$a12_oldpwd" 2>/dev/null; rm -rf "$a12_modpath" "$a12_tmp"; return 1; }
  fi

  # REPLACE / REMOVE
  for a12_t in $REPLACE; do
    a12_msg "- Replace target: $a12_t"
    echo "$a12_t" >> "$a12_modpath/.a12_replace"
  done
  for a12_t in $REMOVE; do
    a12_msg "- Remove target: $a12_t"
    if a12_mark_remove "$a12_modpath$a12_t"; then :; else
      echo "$a12_t" >> "$a12_modpath/.a12_remove"
    fi
  done

  # Partitions that are real mount points live at /vendor etc, not /system/vendor.
  for a12_p in vendor system_ext product odm; do
    if [ -e "$a12_modpath/system/$a12_p" ] && [ ! -L "$a12_modpath/system/$a12_p" ] \
       && [ -d "/$a12_p" ] && [ ! -L "/$a12_p" ]; then
      a12_msg "- Handle partition /$a12_p"
      mv -f "$a12_modpath/system/$a12_p" "$a12_modpath/$a12_p"
      ln -sf "../$a12_p" "$a12_modpath/system/$a12_p"
    fi
  done

  a12_clean_install_artifacts "$a12_modpath"

  # Hot install: replace the live module now, not at some later boot.
  rm -f "$MODS/$a12_id/disable" "$MODS/$a12_id/remove" 2>/dev/null
  rm -rf "$MODS/$a12_id"
  mv "$a12_modpath" "$MODS/$a12_id" || { a12_err "- Error: cannot install to $MODS/$a12_id"; cd "$a12_oldpwd" 2>/dev/null; rm -rf "$a12_tmp"; return 1; }
  rm -f "$MODS/$a12_id/update"
  chown -R 0:0 "$MODS/$a12_id" 2>/dev/null
  cd "$a12_oldpwd" 2>/dev/null
  rm -rf "$a12_tmp"

  a12_msg "- Mounting modules"
  a12_export_mod "$MODS/$a12_id"
  a12_run_script "$MODS/$a12_id/post-fs-data.sh" fg 30
  a12_mount
  a12_run_script "$MODS/$a12_id/post-mount.sh" fg 30
  a12_run_script "$MODS/$a12_id/service.sh" bg 300
  unset KSU_MODULE

  a12_msg "- Done"
  a12_msg "- Module installed successfully!"
  a12_log "installed $a12_id from $a12_zip"
  return 0
}

# ------------------------------------------------------------------ list
a12_list() {
  a12_ensure
  echo "["
  a12_first=1
  for a12_m in "$MODS"/*; do
    [ -f "$a12_m/module.prop" ] || continue
    a12_id=$(a12_prop "$a12_m/module.prop" id)
    [ -n "$a12_id" ] || a12_id=${a12_m##*/}
    a12_en=false; a12_enabled "$a12_m" && a12_en=true
    a12_up=false; [ -e "$a12_m/update" ] && a12_up=true
    a12_rm=false; [ -e "$a12_m/remove" ] && a12_rm=true
    a12_web=false; [ -d "$a12_m/webroot" ] && a12_web=true
    a12_act=false; [ -f "$a12_m/action.sh" ] && a12_act=true
    a12_mnt=false
    [ -d "$a12_m/system" ] && [ ! -e "$a12_m/skip_mount" ] && a12_mnt=true
    [ "$a12_first" = 1 ] || echo ","
    a12_first=0
    printf '  {\n'
    printf '    "id": "%s",\n' "$(a12_json_esc "$a12_id")"
    printf '    "name": "%s",\n' "$(a12_json_esc "$(a12_prop "$a12_m/module.prop" name)")"
    printf '    "version": "%s",\n' "$(a12_json_esc "$(a12_prop "$a12_m/module.prop" version)")"
    printf '    "versionCode": "%s",\n' "$(a12_json_esc "$(a12_prop "$a12_m/module.prop" versionCode)")"
    printf '    "author": "%s",\n' "$(a12_json_esc "$(a12_prop "$a12_m/module.prop" author)")"
    printf '    "description": "%s",\n' "$(a12_json_esc "$(a12_prop "$a12_m/module.prop" description)")"
    printf '    "enabled": "%s",\n' "$a12_en"
    printf '    "update": "%s",\n' "$a12_up"
    printf '    "remove": "%s",\n' "$a12_rm"
    printf '    "web": "%s",\n' "$a12_web"
    printf '    "action": "%s",\n' "$a12_act"
    printf '    "mount": "%s"\n' "$a12_mnt"
    printf '  }'
  done
  echo ""
  echo "]"
}

a12_enable() {
  a12_ensure
  [ -d "$MODS/$1" ] || { a12_err "ksud: module $1 not found"; return 1; }
  rm -f "$MODS/$1/disable" "$MODS/$1/remove"
  a12_log "enabled $1"
  a12_mount >/dev/null 2>&1
  return 0
}

a12_disable() {
  a12_ensure
  [ -d "$MODS/$1" ] || { a12_err "ksud: module $1 not found"; return 1; }
  : > "$MODS/$1/disable"
  a12_log "disabled $1"
  a12_mount >/dev/null 2>&1
  return 0
}

a12_uninstall() {
  a12_ensure
  [ -d "$MODS/$1" ] || { a12_err "ksud: module $1 not found"; return 1; }
  a12_export_mod "$MODS/$1"
  a12_run_script "$MODS/$1/uninstall.sh" fg 30
  unset KSU_MODULE
  rm -rf "$MODS/$1"
  rm -rf "$CFGD/$1"
  a12_log "uninstalled $1"
  a12_mount >/dev/null 2>&1
  return 0
}

a12_undo_uninstall() {
  [ -d "$MODS/$1" ] || { a12_err "ksud: module $1 not found"; return 1; }
  rm -f "$MODS/$1/remove"
  return 0
}

a12_action() {
  [ -f "$MODS/$1/action.sh" ] || { a12_err "ksud: module $1 has no action.sh"; return 1; }
  a12_ensure; a12_env; a12_export_mod "$MODS/$1"
  ( cd "$MODS/$1" && sh action.sh )
  a12_rc=$?
  unset KSU_MODULE
  return $a12_rc
}

# ------------------------------------------------------------------ mount
a12_unmount() {
  [ -f "$MNTD/mounted" ] || return 0
  a12_rev_lines < "$MNTD/mounted" > "$MNTD/um.tmp"
  while IFS= read -r a12_t; do
    [ -n "$a12_t" ] || continue
    umount -l "$a12_t" 2>/dev/null && a12_log "unmounted $a12_t"
  done < "$MNTD/um.tmp"
  rm -f "$MNTD/mounted" "$MNTD/um.tmp"
}

a12_mount_one() {
  # <target> <colon-separated lowers>
  a12_t=$1
  a12_lowers=$2
  a12_key=$(printf '%s' "$a12_t" | tr '/' '_')
  a12_seq=$(cat "$MNTD/seq" 2>/dev/null)
  [ -n "$a12_seq" ] || a12_seq=0
  a12_seq=$((a12_seq + 1))
  echo "$a12_seq" > "$MNTD/seq"
  a12_u=$MNTD/$a12_key/u$a12_seq
  a12_w=$MNTD/$a12_key/w$a12_seq
  mkdir -p "$a12_u" "$a12_w" 2>/dev/null
  if mount -t overlay overlay -o "lowerdir=$a12_lowers:$a12_t,upperdir=$a12_u,workdir=$a12_w" "$a12_t" 2>>"$LOGD/mount.log"; then
    echo "$a12_t" >> "$MNTD/mounted"
    a12_log "mounted $a12_t"
  else
    a12_log "MOUNT FAILED $a12_t"
    a12_err "! mount failed: $a12_t"
  fi
}

a12_mount() {
  a12_ensure
  a12_unmount
  rm -rf "$MNTD"
  mkdir -p "$MNTD"
  : > "$MNTD/pairs"
  : > "$MNTD/seq"
  : > "$MNTD/mounted"

  for a12_m in "$MODS"/*; do
    a12_enabled "$a12_m" || continue
    [ -e "$a12_m/skip_mount" ] && continue
    for a12_part in system vendor product odm system_ext; do
      a12_src=$a12_m/$a12_part
      [ -d "$a12_src" ] || continue
      case "$a12_part" in
        system) a12_root=/system ;;
        system_ext) a12_root=/system/system_ext ;;
        *) a12_root=/$a12_part ;;
      esac
      [ -d "$a12_root" ] || continue
      for a12_d in "$a12_src"/*; do
        [ -e "$a12_d" ] || continue
        [ -L "$a12_d" ] && continue
        a12_n=${a12_d##*/}
        case "$a12_part:$a12_n" in
          system:system_ext)
            for a12_e in "$a12_d"/*; do
              [ -e "$a12_e" ] || continue
              a12_en=${a12_e##*/}
              if [ -e "/system/system_ext/$a12_en" ]; then
                echo "/system/system_ext/$a12_en|$a12_e" >> "$MNTD/pairs"
              else
                echo "ROOT|/system/system_ext|$a12_d" >> "$MNTD/pairs"
              fi
            done
            ;;
          system:vendor)
            if [ -d /vendor ] && [ ! -L /vendor ]; then
              for a12_e in "$a12_d"/*; do
                [ -e "$a12_e" ] || continue
                echo "/vendor/${a12_e##*/}|$a12_e" >> "$MNTD/pairs"
              done
            else
              echo "/system/vendor|$a12_d" >> "$MNTD/pairs"
            fi
            ;;
          *)
            a12_t=$a12_root/$a12_n
            if [ -e "$a12_t" ]; then
              echo "$a12_t|$a12_d" >> "$MNTD/pairs"
            else
              echo "ROOT|$a12_root|$a12_src" >> "$MNTD/pairs"
            fi
            ;;
        esac
      done
    done
  done

  # Partition-root fallbacks (module adds a new top-level entry).
  awk -F'|' '$1=="ROOT"{print $2"|"$3}' "$MNTD/pairs" | sort -u > "$MNTD/roots"
  while IFS='|' read -r a12_r a12_src; do
    [ -n "$a12_r" ] || continue
    a12_log "root overlay $a12_r (new top-level entry)"
    awk -F'|' -v r="$a12_r" '$1=="ROOT" && $2==r {print $3}' "$MNTD/pairs" | sort -u | a12_rev_lines > "$MNTD/l.tmp"
    a12_lowers=""
    while IFS= read -r a12_d; do
      [ -n "$a12_d" ] || continue
      if [ -z "$a12_lowers" ]; then a12_lowers=$a12_d; else a12_lowers="$a12_lowers:$a12_d"; fi
    done < "$MNTD/l.tmp"
    [ -n "$a12_lowers" ] && a12_mount_one "$a12_r" "$a12_lowers"
  done < "$MNTD/roots"

  awk -F'|' '$1!="ROOT"{print $1"|"$2}' "$MNTD/pairs" | sort -u > "$MNTD/use"
  cut -d'|' -f1 "$MNTD/use" | sort -u > "$MNTD/targets"
  while IFS= read -r a12_t; do
    [ -n "$a12_t" ] || continue
    a12_skip=0
    while IFS='|' read -r a12_r a12_src; do
      [ -n "$a12_r" ] || continue
      case "$a12_t" in "$a12_r"|"$a12_r"/*) a12_skip=1 ;; esac
    done < "$MNTD/roots"
    [ "$a12_skip" = 1 ] && continue
    awk -F'|' -v t="$a12_t" '$1==t{print $2}' "$MNTD/use" | a12_rev_lines > "$MNTD/l.tmp"
    a12_lowers=""
    while IFS= read -r a12_d; do
      [ -n "$a12_d" ] || continue
      if [ -z "$a12_lowers" ]; then a12_lowers=$a12_d; else a12_lowers="$a12_lowers:$a12_d"; fi
    done < "$MNTD/l.tmp"
    [ -n "$a12_lowers" ] && a12_mount_one "$a12_t" "$a12_lowers"
  done < "$MNTD/targets"

  a12_apply_removals
  a12_repair_su
  rm -f "$MNTD/pairs" "$MNTD/use" "$MNTD/targets" "$MNTD/roots" "$MNTD/l.tmp"
  a12_log "mount pass done: $(wc -l < "$MNTD/mounted" 2>/dev/null || echo 0) targets"
}

# Deletions that the kernel cannot whiteout at install time (no CAP_MKNOD in
# every path) are replayed through the merged overlay.
a12_apply_removals() {
  for a12_m in "$MODS"/*; do
    a12_enabled "$a12_m" || continue
    if [ -f "$a12_m/.a12_remove" ]; then
      while IFS= read -r a12_rel; do
        [ -n "$a12_rel" ] || continue
        case "$a12_rel" in
          /system/*|/vendor/*|/product/*|/odm/*|/system_ext/*) ;;
          *) a12_log "skip remove outside system partitions: $a12_rel"; continue ;;
        esac
        rm -rf "/${a12_rel#/}" 2>/dev/null
        a12_log "remove $a12_rel"
      done < "$a12_m/.a12_remove"
    fi
    if [ -f "$a12_m/.a12_replace" ]; then
      while IFS= read -r a12_rel; do
        [ -n "$a12_rel" ] || continue
        case "$a12_rel" in
          /system/*|/vendor/*|/product/*|/odm/*|/system_ext/*) ;;
          *) a12_log "skip replace outside system partitions: $a12_rel"; continue ;;
        esac
        a12_tgt="/${a12_rel#/}"
        [ -d "$a12_tgt" ] || continue
        for a12_e in "$a12_tgt"/*; do
          [ -e "$a12_e" ] || continue
          a12_en=${a12_e##*/}
          [ -e "$a12_m$a12_rel/$a12_en" ] || rm -rf "$a12_e" 2>/dev/null
        done
        a12_log "replace $a12_rel"
      done < "$a12_m/.a12_replace"
    fi
  done
}

# Keep the su stack above every module overlay.  A module that ships
# system/system_ext (or a new /system top-level entry) forces an overlay on
# /system or /system/system_ext, which would hide the tmpfs holding su.
a12_repair_su() {
  mkdir -p /system/system_ext/bin 2>/dev/null
  if ! mountpoint -q /system/system_ext/bin 2>/dev/null; then
    mount -t tmpfs tmpfs /system/system_ext/bin 2>>"$LOGD/mount.log" || a12_err "! su tmpfs remount failed"
  fi
  for a12_f in su ksud magisk resetprop a12mod.sh; do
    [ -f "$BIN/$a12_f" ] || continue
    cp -f "$BIN/$a12_f" "/system/system_ext/bin/$a12_f" 2>/dev/null
    chmod 755 "/system/system_ext/bin/$a12_f" 2>/dev/null
  done
  a12_log "su stack repaired"
}

# ------------------------------------------------------------------ lifecycle
a12_prune() {
  for a12_m in "$MODS"/*; do
    [ -d "$a12_m" ] || continue
    [ -e "$a12_m/remove" ] || continue
    a12_export_mod "$a12_m"
    a12_run_script "$a12_m/uninstall.sh" fg 30
    unset KSU_MODULE
    rm -rf "$a12_m"
    a12_log "pruned ${a12_m##*/}"
  done
}

a12_apply_updates() {
  for a12_u in "$MODU"/*; do
    [ -d "$a12_u" ] || continue
    a12_id=${a12_u##*/}
    a12_was_disabled=0; [ -e "$MODS/$a12_id/disable" ] && a12_was_disabled=1
    rm -rf "$MODS/$a12_id"
    mv "$a12_u" "$MODS/$a12_id" || continue
    [ "$a12_was_disabled" = 1 ] && : > "$MODS/$a12_id/disable"
    rm -f "$MODS/$a12_id/update"
    a12_log "applied update $a12_id"
  done
}

a12_late_load() {
  a12_ensure
  a12_bootid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  a12_lock=$KSUD/.late-load.lock
  if [ -d "$a12_lock" ]; then
    a12_lb=$(cat "$a12_lock/boot_id" 2>/dev/null)
    a12_p=$(cat "$a12_lock/pid" 2>/dev/null)
    # A pid from a previous boot can be reused by an unrelated process, so the
    # lock is only valid when it carries the current boot_id.
    if [ -n "$a12_bootid" ] && [ "$a12_lb" = "$a12_bootid" ] \
       && [ -n "$a12_p" ] && kill -0 "$a12_p" 2>/dev/null; then
      a12_msg "ksud: late-load already running (pid $a12_p)"
      return 0
    fi
    rm -rf "$a12_lock"
  fi
  mkdir -p "$a12_lock"
  echo $$ > "$a12_lock/pid"
  echo "$a12_bootid" > "$a12_lock/boot_id"

  a12_msg "ksud: late-load (userspace KernelSU emulation)"
  a12_prune
  a12_apply_updates
  a12_stage late-load
  # post-fs-data.sh normally runs before mounts; here the system is already up,
  # so it is a late-load stage (same compromise KernelSU documents).
  a12_stage post-fs-data
  a12_load_props
  a12_mount
  a12_stage post-mount
  a12_stage service
  a12_stage boot-completed
  a12_msg "ksud: late-load done"
  rm -rf "$a12_lock"
  return 0
}

# ------------------------------------------------------------------ module config
a12_cfg_file() {
  # <id> <temp|persist>
  if [ "$2" = temp ]; then echo "$CFGD/$1/tmp.config"; else echo "$CFGD/$1/persist.config"; fi
}

a12_cfg_valid_key() {
  case "$1" in
    *[!A-Za-z0-9._-]*|'') return 1 ;;
  esac
  return 0
}

a12_cfg_get() {
  a12_f=$(a12_cfg_file "$1" persist)
  a12_t=$(a12_cfg_file "$1" temp)
  a12_v=""
  [ -f "$a12_t" ] && a12_v=$(grep -m1 "^$2=" "$a12_t" | sed "s/^$2=//")
  if [ -z "$a12_v" ] && [ -f "$a12_f" ]; then
    a12_v=$(grep -m1 "^$2=" "$a12_f" | sed "s/^$2=//")
  fi
  [ -n "$a12_v" ] || return 1
  printf '%s\n' "$a12_v"
}

a12_cfg_set() {
  # <id> <key> <value> <temp|persist>
  a12_f=$(a12_cfg_file "$1" "$4")
  mkdir -p "${a12_f%/*}" 2>/dev/null
  a12_v="$3"
  if [ -z "$a12_v" ]; then a12_v=$(cat); fi
  case "$a12_v" in *'
'*) a12_err "ksud: config value must be a single line"; return 1 ;; esac
  touch "$a12_f"
  grep -v "^$2=" "$a12_f" > "$a12_f.tmp" 2>/dev/null
  mv "$a12_f.tmp" "$a12_f"
  printf '%s=%s\n' "$2" "$a12_v" >> "$a12_f"
  return 0
}

a12_cfg_del() {
  a12_f=$(a12_cfg_file "$1" "$3")
  [ -f "$a12_f" ] || return 0
  grep -v "^$2=" "$a12_f" > "$a12_f.tmp" 2>/dev/null
  mv "$a12_f.tmp" "$a12_f"
  return 0
}

a12_cfg_list() {
  a12_f=$(a12_cfg_file "$1" persist)
  a12_t=$(a12_cfg_file "$1" temp)
  [ -f "$a12_f" ] && cat "$a12_f"
  [ -f "$a12_t" ] && cat "$a12_t"
  return 0
}

a12_cfg_clear() {
  a12_f=$(a12_cfg_file "$1" "$2")
  : > "$a12_f"
  return 0
}
