#!/usr/bin/env bash
# shellcheck shell=bash
#
# mount_all.sh - Robust NAS auto-mounter for RGB-Pi / RetroArch / Kodi setups.
#
# Design goals:
# 1) Easy top-of-file configuration for non-technical users.
# 2) Mount every discovered NAS share under /mnt/nas/<share> for Kodi browsing.
# 3) Optionally bind-map specific ROM folders directly into RGB-Pi ROM paths.
# 4) Never hard-hang boot when NAS is offline or credentials are wrong.
#
# Usage examples:
#   sudo bash mount_all.sh
#   sudo bash mount_all.sh --status
#   sudo bash mount_all.sh --install-boot
#   sudo bash mount_all.sh --remove-boot
#
# Notes:
# - For SMB/CIFS, this script can auto-discover share names with smbclient.
# - For NFS, you can enable showmount discovery or provide explicit NFS exports.
# - Failed mounts are logged and skipped; script continues with remaining entries.

set -u

###############################################################################
# User Configuration (edit this section)
###############################################################################

# NAS connection basics
NAS_PROTOCOL="cifs"            # cifs | nfs
NAS_IP="192.168.1.10"
NAS_USER="nasuser"
NAS_PASS=""
NAS_DOMAIN=""                  # Optional for SMB; leave empty if not needed

# Where all NAS shares are mounted (for Kodi browsing and general access)
NAS_MOUNT_ROOT="/mnt/nas"

# Automatically install/enable a boot service after running this script?
# YES = create+enable systemd service that runs after network-online.
# NO  = one-shot manual run only.
RUN_ON_BOOT="NO"               # YES | NO

# If NAS auto-discovery fails, these shares are still attempted.
# Space separated list. Example: "emulation media movies series"
FALLBACK_SHARES="emulation media downloads"

# RGB-Pi/RetroArch ROM destination root (local on Pi)
RGBPI_ROMS_BASE="/media/sd/roms"

# Automatically map folders found under /mnt/nas/emulation/roms using the
# alias table in `map_remote_system_to_local_dir`.
AUTO_MAP_FROM_EMULATION_ROMS="YES"   # YES | NO

# ROM mapping format:
#   REMOTE_PATH|LOCAL_SYSTEM_DIR
# REMOTE_PATH can be either:
#   - /share/sub/path     (SMB/NFS share + subpath)
#   - /share              (whole share)
# Local target becomes: ${RGBPI_ROMS_BASE}/LOCAL_SYSTEM_DIR
#
# Example from your request:
#   /emulation/roms/snes|snes
#   /emulation/roms/gba|gba
ROM_MAPPINGS=(
  "/emulation/roms/arcade|arcade"
  "/emulation/roms/hbmame|arcade"
  "/emulation/roms/SNES|snes"
  "/emulation/roms/GBA|gba"
  "/emulation/roms/PSX|psx"
  "/emulation/roms/NES|nes"
  "/emulation/roms/SMS|mastersystem"
  "/emulation/roms/MegaDrive|megadrive"
  "/emulation/roms/Genesis|megadrive"
  "/emulation/roms/MegaCD|segacd"
  "/emulation/roms/S32X|sega32x"
  "/emulation/roms/TGFX16|pcengine"
  "/emulation/roms/TGFX16-CD|pcenginecd"
  "/emulation/roms/N64|n64"
  "/emulation/roms/NEOGEO|neogeo"
  "/emulation/roms/NeoGeo-CD|neocd"
  "/emulation/roms/Amiga|amiga"
  "/emulation/roms/Amstrad|amstradcpc"
  "/emulation/roms/PCXT|pc"
  "/emulation/roms/Atari2600|atari2600"
  "/emulation/roms/Atari7800|atari7800"
  "/emulation/roms/MSX|msx"
  "/emulation/roms/MSX1|msx"
  "/emulation/roms/NeoGeoPocket|ngp"
  "/emulation/roms/X68000|x68000"
  "/emulation/roms/Spectrum|zxspectrum"
)

# CIFS tuning
CIFS_VERSION="3.0"
CIFS_UID="1000"
CIFS_GID="1000"
CIFS_FILE_MODE="0664"
CIFS_DIR_MODE="0775"

# NFS tuning (safe defaults for home NAS)
NFS_VERSION="4"

# Timeouts / behavior
MOUNT_TIMEOUT_SECONDS="12"     # hard timeout per mount attempt
PING_TIMEOUT_SECONDS="1"
LOG_FILE="/var/log/mount_all.log"

###############################################################################
# End User Configuration
###############################################################################

# Optional per-machine override file.
# Example:
#   NAS_USER="xbmc"
#   NAS_PASS="secret"
#   NAS_IP="192.168.2.3"
LOCAL_OVERRIDE_FILE="${LOCAL_OVERRIDE_FILE:-$(dirname "$0")/mount_all.local.sh}"

if [[ -f "$LOCAL_OVERRIDE_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$LOCAL_OVERRIDE_FILE"
fi

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SERVICE_NAME="mount-all-roms.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
CREDENTIALS_FILE="/etc/mount_all_smb_credentials"

# Keep script resilient even if one mount fails.
set +e

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must run as root. Use: sudo bash $0"
    exit 1
  fi
}

trim_slashes() {
  local v="$1"
  v="${v#/}"
  v="${v%/}"
  echo "$v"
}

ensure_dir() {
  local d="$1"
  [[ -d "$d" ]] || mkdir -p "$d"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_prereqs() {
  local missing=()

  if [[ "$NAS_PROTOCOL" == "cifs" ]]; then
    has_cmd smbclient || missing+=("smbclient")
    has_cmd mount.cifs || missing+=("cifs-utils")
  else
    has_cmd showmount || missing+=("nfs-common")
    has_cmd mount.nfs || missing+=("nfs-common")
  fi

  has_cmd timeout || missing+=("coreutils")
  has_cmd ping || missing+=("iputils-ping")

  if [[ ${#missing[@]} -gt 0 ]]; then
    log "INFO Installing missing packages: ${missing[*]}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y "${missing[@]}" >/dev/null 2>&1
  fi
}

wait_network_brief() {
  local i
  for i in {1..10}; do
    if ping -c 1 -W "$PING_TIMEOUT_SECONDS" "$NAS_IP" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

write_smb_credentials() {
  umask 077
  {
    if [[ -n "$NAS_USER" ]]; then
      echo "username=${NAS_USER}"
    fi
    if [[ -n "$NAS_PASS" ]]; then
      echo "password=${NAS_PASS}"
    fi
    [[ -n "$NAS_DOMAIN" ]] && echo "domain=${NAS_DOMAIN}"
  } > "$CREDENTIALS_FILE"
  chmod 600 "$CREDENTIALS_FILE"
}

normalized_name() {
  local v="$1"
  v="$(echo "$v" | tr '[:lower:]' '[:upper:]')"
  v="${v// /}"
  v="${v//-/}"
  v="${v//_/}"
  echo "$v"
}

map_remote_system_to_local_dir() {
  local raw="$1"
  local key
  key="$(normalized_name "$raw")"

  case "$key" in
    ARCADE|HBMAME|NAOMI) echo "arcade" ;;
    AMIGA) echo "amiga" ;;
    AMSTRAD|AMSTRADPCW) echo "amstradcpc" ;;
    ATARI2600) echo "atari2600" ;;
    ATARI7800) echo "atari7800" ;;
    C64) echo "c64" ;;
    DREAMCAST) echo "dreamcast" ;;
    GBA|GBA2P) echo "gba" ;;
    GAMEGEAR|SMS|MASTERSYSTEM) echo "mastersystem" ;;
    GENESIS|MEGADRIVE) echo "megadrive" ;;
    MEGACD|SEGACD) echo "segacd" ;;
    MSX|MSX1) echo "msx" ;;
    N64) echo "n64" ;;
    NEOGEO) echo "neogeo" ;;
    NEOGEOCD) echo "neocd" ;;
    NES) echo "nes" ;;
    NEOGEOPOCKET|NGP) echo "ngp" ;;
    PC|PCXT) echo "pc" ;;
    PCENGINE|TGFX16) echo "pcengine" ;;
    PCENGINECD|TGFX16CD) echo "pcenginecd" ;;
    PSX) echo "psx" ;;
    S32X|SEGA32X) echo "sega32x" ;;
    SG1000) echo "sg1000" ;;
    SGB) echo "sgb" ;;
    SNES) echo "snes" ;;
    SPECTRUM|ZXSPECTRUM) echo "zxspectrum" ;;
    X68000) echo "x68000" ;;
    *) return 1 ;;
  esac
}

auto_map_emulation_roms() {
  [[ "$AUTO_MAP_FROM_EMULATION_ROMS" == "YES" ]] || return 0

  local root="${NAS_MOUNT_ROOT}/emulation/roms"
  if [[ ! -d "$root" ]]; then
    log "INFO Auto-map root not found: $root"
    return 0
  fi

  local dir base local_dir
  for dir in "$root"/*; do
    [[ -d "$dir" ]] || continue
    base="$(basename "$dir")"
    if local_dir="$(map_remote_system_to_local_dir "$base")"; then
      bind_mount_rom_mapping "/emulation/roms/${base}|${local_dir}"
    fi
  done
}

# Returns share names, one per line.
discover_cifs_shares() {
  if has_cmd smbclient; then
    smbclient -g -L "//${NAS_IP}" -A "$CREDENTIALS_FILE" 2>/dev/null \
      | awk -F'|' '$1=="Disk" {print $2}' \
      | sed '/^$/d' \
      | sort -u
  fi
}

# Returns export paths, one per line (e.g. /volume1/roms)
discover_nfs_exports() {
  if has_cmd showmount; then
    showmount -e "$NAS_IP" 2>/dev/null \
      | awk 'NR>1 {print $1}'
  fi
}

mount_cifs_share() {
  local share="$1"
  local target="${NAS_MOUNT_ROOT}/${share}"

  ensure_dir "$target"

  if mountpoint -q "$target"; then
    log "OK   CIFS already mounted: //$NAS_IP/$share -> $target"
    return 0
  fi

  timeout "$MOUNT_TIMEOUT_SECONDS" mount -t cifs "//${NAS_IP}/${share}" "$target" \
    -o "credentials=${CREDENTIALS_FILE},vers=${CIFS_VERSION},uid=${CIFS_UID},gid=${CIFS_GID},file_mode=${CIFS_FILE_MODE},dir_mode=${CIFS_DIR_MODE},iocharset=utf8,nofail,_netdev,x-systemd.automount,x-systemd.idle-timeout=120"

  if mountpoint -q "$target"; then
    log "OK   CIFS mounted: //$NAS_IP/$share -> $target"
    return 0
  fi

  log "WARN CIFS failed: //$NAS_IP/$share"
  return 1
}

mount_nfs_export() {
  local export_path="$1"
  local clean
  clean="$(trim_slashes "$export_path")"
  local target="${NAS_MOUNT_ROOT}/${clean//\//_}"

  ensure_dir "$target"

  if mountpoint -q "$target"; then
    log "OK   NFS already mounted: ${NAS_IP}:${export_path} -> $target"
    return 0
  fi

  timeout "$MOUNT_TIMEOUT_SECONDS" mount -t nfs "${NAS_IP}:${export_path}" "$target" \
    -o "vers=${NFS_VERSION},soft,timeo=10,retrans=2,nofail,_netdev,x-systemd.automount,x-systemd.idle-timeout=120"

  if mountpoint -q "$target"; then
    log "OK   NFS mounted: ${NAS_IP}:${export_path} -> $target"
    return 0
  fi

  log "WARN NFS failed: ${NAS_IP}:${export_path}"
  return 1
}

# Convert /share/sub/path -> share + subpath
split_remote_path() {
  local remote="$1"
  remote="$(trim_slashes "$remote")"
  local share="${remote%%/*}"
  local sub=""
  if [[ "$remote" == */* ]]; then
    sub="${remote#*/}"
  fi
  echo "$share|$sub"
}

bind_mount_rom_mapping() {
  local mapping="$1"
  local remote_path="${mapping%%|*}"
  local local_dir="${mapping##*|}"

  local parsed share sub
  parsed="$(split_remote_path "$remote_path")"
  share="${parsed%%|*}"
  sub="${parsed##*|}"

  local source="${NAS_MOUNT_ROOT}/${share}"
  [[ -n "$sub" ]] && source="${source}/${sub}"

  local target="${RGBPI_ROMS_BASE}/${local_dir}"

  ensure_dir "${NAS_MOUNT_ROOT}/${share}"
  ensure_dir "$target"

  # Best effort: ensure share is mounted first.
  if ! mountpoint -q "${NAS_MOUNT_ROOT}/${share}"; then
    if [[ "$NAS_PROTOCOL" == "cifs" ]]; then
      mount_cifs_share "$share" >/dev/null 2>&1
    else
      # For NFS we don't know exact export from /share syntax universally.
      # User should ensure export is mounted via discovery/fallback.
      :
    fi
  fi

  if [[ ! -d "$source" ]]; then
    log "WARN Source missing, skip bind: $source -> $target"
    return 1
  fi

  if mountpoint -q "$target"; then
    log "OK   Bind already mounted: $source -> $target"
    return 0
  fi

  timeout "$MOUNT_TIMEOUT_SECONDS" mount --bind "$source" "$target"

  if mountpoint -q "$target"; then
    log "OK   Bind mounted: $source -> $target"
    return 0
  fi

  log "WARN Bind failed: $source -> $target"
  return 1
}

mount_all_shares() {
  ensure_dir "$NAS_MOUNT_ROOT"

  local shares=()
  local discovered

  if [[ "$NAS_PROTOCOL" == "cifs" ]]; then
    discovered="$(discover_cifs_shares)"
    if [[ -n "$discovered" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && shares+=("$line")
      done <<< "$discovered"
    fi

    if [[ ${#shares[@]} -eq 0 ]]; then
      log "INFO SMB discovery empty; using FALLBACK_SHARES"
      # shellcheck disable=SC2206
      shares=($FALLBACK_SHARES)
    fi

    local s
    for s in "${shares[@]}"; do
      mount_cifs_share "$s"
    done
  else
    local exports
    exports="$(discover_nfs_exports)"

    if [[ -n "$exports" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && mount_nfs_export "$line"
      done <<< "$exports"
    else
      log "INFO NFS discovery empty; trying FALLBACK_SHARES as exports"
      local e
      # shellcheck disable=SC2206
      for e in $FALLBACK_SHARES; do
        [[ "$e" != /* ]] && e="/$e"
        mount_nfs_export "$e"
      done
    fi
  fi
}

mount_all_rom_mappings() {
  local item
  for item in "${ROM_MAPPINGS[@]}"; do
    [[ -z "$item" ]] && continue
    if [[ "$item" != *"|"* ]]; then
      log "WARN Invalid ROM mapping format (skip): $item"
      continue
    fi
    bind_mount_rom_mapping "$item"
  done

  auto_map_emulation_roms
}

show_status() {
  log "STATUS NAS mounts under $NAS_MOUNT_ROOT"
  findmnt -R "$NAS_MOUNT_ROOT" 2>/dev/null || true
  log "STATUS ROM bind mounts under $RGBPI_ROMS_BASE"
  findmnt -R "$RGBPI_ROMS_BASE" 2>/dev/null || true
}

install_boot_service() {
  cat > "$SERVICE_PATH" <<SERVICE
[Unit]
Description=Mount NAS shares and RGB-Pi ROM binds (non-blocking)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${SCRIPT_PATH} --boot-run
TimeoutStartSec=90
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  log "OK   Installed boot service: $SERVICE_NAME"
}

remove_boot_service() {
  if [[ -f "$SERVICE_PATH" ]]; then
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$SERVICE_PATH"
    systemctl daemon-reload
    log "OK   Removed boot service: $SERVICE_NAME"
  else
    log "INFO Boot service not present"
  fi
}

main() {
  need_root
  ensure_dir "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  case "${1:-}" in
    --status)
      show_status
      exit 0
      ;;
    --install-boot)
      install_boot_service
      exit 0
      ;;
    --remove-boot)
      remove_boot_service
      exit 0
      ;;
    --boot-run)
      # Boot mode: do not install service recursively.
      ;;
    "")
      ;;
    *)
      echo "Usage: sudo bash $0 [--status|--install-boot|--remove-boot|--boot-run]"
      exit 1
      ;;
  esac

  if [[ "$NAS_PROTOCOL" != "cifs" && "$NAS_PROTOCOL" != "nfs" ]]; then
    log "ERROR NAS_PROTOCOL must be 'cifs' or 'nfs'"
    exit 1
  fi

  ensure_prereqs

  if [[ "$NAS_PROTOCOL" == "cifs" ]]; then
    write_smb_credentials
  fi

  if ! wait_network_brief; then
    log "WARN NAS $NAS_IP not reachable yet; continuing non-blocking"
  fi

  log "INFO Start mounting NAS shares to $NAS_MOUNT_ROOT"
  mount_all_shares

  log "INFO Start mounting ROM bindings to $RGBPI_ROMS_BASE"
  mount_all_rom_mappings

  if [[ "${1:-}" != "--boot-run" && "$RUN_ON_BOOT" == "YES" ]]; then
    install_boot_service
  fi

  log "INFO mount_all.sh finished"
  show_status
}

main "$@"
