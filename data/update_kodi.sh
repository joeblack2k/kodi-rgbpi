#!/usr/bin/env bash
# Manifest-driven Kodi updater for RGB-Pi.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-$SCRIPT_DIR}"
APP_ROOT="${APP_ROOT:-$(cd -- "${DATA_ROOT}/.." && pwd)}"
. "${DATA_ROOT}/common.sh"

DOWNLOAD_DIR="${DATA_ROOT}/debs"
KODI_DEB_PATH="${DOWNLOAD_DIR}/kodi.deb"
JOYSTICK_PAYLOAD_PATH="${DOWNLOAD_DIR}/kodi-omega-peripheral-joystick.tar.gz"
BACKUP_ROOT="/opt/backups/agents/kodi"
LOG_FILE="/var/log/update_kodi.log"
LOG_DIR="/var/log/kodi-updater"
RUNTIME_DEPS=(libtinyxml2-8)
AUTO_FIX_BROKEN="YES"
DRY_RUN="NO"
MODE="update"
RUN_KODI_SMOKE_TEST="${RUN_KODI_SMOKE_TEST:-YES}"
KODI_SMOKE_TIMEOUT="${KODI_SMOKE_TIMEOUT:-20}"

LOCAL_SHARE_ADDON_DIR="/usr/local/share/kodi/addons/peripheral.joystick"
LOCAL_LIB_ADDON_DIR="/usr/local/lib/aarch64-linux-gnu/kodi/addons/peripheral.joystick"
LEGACY_SHARE_ADDON_DIR="/usr/share/kodi/addons/peripheral.joystick"
LEGACY_LIB_ADDON_DIR="/usr/lib/aarch64-linux-gnu/kodi/addons/peripheral.joystick"
OLD_PACKAGES=(kodi-bin kodi-peripheral-joystick)
KODI_JS0_BRIDGE_DST="/usr/local/bin/kodi_js0_bridge.py"
KODI_JS0_BRIDGE_SERVICE="/etc/systemd/system/kodi-js0-bridge.service"

REPAIR_REASONS=()

parse_args() {
  case "${1:-}" in
    --status) MODE="status" ;;
    --update|"") MODE="update" ;;
    *) echo "Usage: sudo bash $0 [--status|--update]"; exit 1 ;;
  esac
}

installed_kodi_version() {
  if dpkg-query -W -f='${Version}\n' kodi >/dev/null 2>&1; then
    dpkg-query -W -f='${Version}\n' kodi
    return 0
  fi
  if dpkg-query -W -f='${Version}\n' kodi-bin >/dev/null 2>&1; then
    dpkg-query -W -f='${Version}\n' kodi-bin
    return 0
  fi
  echo "not-installed"
}

xml_field() {
  local xml_path="$1" query="$2"
  [[ -f "$xml_path" ]] || {
    echo "not-installed"
    return 0
  }
  python3 - "$xml_path" "$query" <<'PY'
import sys
import xml.etree.ElementTree as ET

xml_path, query = sys.argv[1:]
root = ET.parse(xml_path).getroot()
if query == "addon_version":
    print(root.attrib.get("version", "not-installed"))
elif query == "peripheral_abi":
    result = "not-installed"
    requires = root.find("requires")
    if requires is not None:
        for item in requires.findall("import"):
            if item.attrib.get("addon") == "kodi.binary.instance.peripheral":
                result = item.attrib.get("version") or item.attrib.get("minversion") or "not-installed"
                break
    print(result)
else:
    raise SystemExit(f"unknown query: {query}")
PY
}

installed_addon_version() {
  xml_field "${LOCAL_SHARE_ADDON_DIR}/addon.xml" addon_version
}

installed_addon_peripheral_abi() {
  xml_field "${LOCAL_SHARE_ADDON_DIR}/addon.xml" peripheral_abi
}

package_installed() {
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

legacy_packages_present() {
  local pkg
  for pkg in "${OLD_PACKAGES[@]}"; do
    if package_installed "$pkg"; then
      return 0
    fi
  done
  return 1
}

bridge_present() {
  [[ -e "$KODI_JS0_BRIDGE_DST" || -e "$KODI_JS0_BRIDGE_SERVICE" ]]
}

local_addon_layout_ok() {
  [[ -d "$LOCAL_SHARE_ADDON_DIR" && ! -L "$LOCAL_SHARE_ADDON_DIR" ]]
  [[ -d "$LOCAL_LIB_ADDON_DIR" && ! -L "$LOCAL_LIB_ADDON_DIR" ]]
  [[ -f "$LOCAL_SHARE_ADDON_DIR/addon.xml" ]]
  compgen -G "$LOCAL_LIB_ADDON_DIR/peripheral.joystick.so*" >/dev/null
}

collect_repair_reasons() {
  local expected_addon_version="$1" expected_addon_abi="$2"
  REPAIR_REASONS=()

  if legacy_packages_present; then
    REPAIR_REASONS+=("legacy-packages-installed")
  fi
  if [[ -e "$LEGACY_SHARE_ADDON_DIR" || -e "$LEGACY_LIB_ADDON_DIR" ]]; then
    REPAIR_REASONS+=("legacy-addon-path-present")
  fi
  if bridge_present; then
    REPAIR_REASONS+=("legacy-bridge-present")
  fi
  if ! local_addon_layout_ok; then
    REPAIR_REASONS+=("local-addon-layout-broken")
  fi
  if [[ "$(installed_addon_version)" != "$expected_addon_version" ]]; then
    REPAIR_REASONS+=("addon-version-mismatch")
  fi
  if [[ "$(installed_addon_peripheral_abi)" != "$expected_addon_abi" ]]; then
    REPAIR_REASONS+=("addon-abi-mismatch")
  fi
}

update_required() {
  local installed="$1" available="$2"
  compare_pkg_update "$installed" "$available"
}

use_local_asset() {
  local filename="$1"
  [[ -n "$filename" && -f "${ASSET_ROOT}/${filename}" ]]
}

fetch_asset() {
  local asset_key="$1" destination="$2" log_file="$3" dry_run="$4"
  local filename url checksum actual
  filename="$(manifest_field "$asset_key" filename)"
  url="$(manifest_field "$asset_key" url)"
  checksum="$(manifest_field "$asset_key" sha256)"

  mkdir -p "$(dirname "$destination")"

  if use_local_asset "$filename"; then
    run_cmd "$log_file" "$dry_run" "cp '${ASSET_ROOT}/${filename}' '$destination'"
  elif [[ -n "$url" ]]; then
    run_cmd "$log_file" "$dry_run" "curl -fL --retry 3 --connect-timeout 15 '$url' -o '$destination'"
  else
    line
    log "$log_file" "ERROR: missing source for asset '$asset_key'"
    exit 1
  fi

  if [[ "$dry_run" == "YES" ]]; then
    return 0
  fi

  if [[ -n "$checksum" && "$checksum" != "unknown" ]]; then
    actual="$(sha256_file "$destination")"
    if [[ "$actual" != "$checksum" ]]; then
      line
      log "$log_file" "ERROR: checksum mismatch for $(basename "$destination")"
      exit 1
    fi
  fi
}

validate_kodi_package() {
  local log_file="$1"
  local arch pkg
  arch="$(dpkg-deb -f "$KODI_DEB_PATH" Architecture 2>/dev/null || echo bad)"
  pkg="$(dpkg-deb -f "$KODI_DEB_PATH" Package 2>/dev/null || echo bad)"
  log "$log_file" "Package validation : pkg=$pkg arch=$arch"
  if [[ "$arch" != "arm64" || "$pkg" != "kodi" ]]; then
    line
    log "$log_file" "ERROR: downloaded file is not valid kodi arm64 package"
    exit 1
  fi
}

validate_joystick_payload() {
  local log_file="$1" expected_version="$2" expected_abi="$3"
  local tmpdir addon_xml payload_version payload_abi
  tmpdir="$(mktemp -d)"
  tar -xzf "$JOYSTICK_PAYLOAD_PATH" -C "$tmpdir"
  addon_xml="$tmpdir/share/kodi/addons/peripheral.joystick/addon.xml"
  payload_version="$(xml_field "$addon_xml" addon_version)"
  payload_abi="$(xml_field "$addon_xml" peripheral_abi)"
  rm -rf "$tmpdir"

  if [[ "$payload_version" != "$expected_version" || "$payload_abi" != "$expected_abi" ]]; then
    line
    log "$log_file" "ERROR: joystick payload mismatch version=$payload_version abi=$payload_abi"
    exit 1
  fi
}

find_kodi_binary() {
  local candidate
  for candidate in \
    /usr/local/lib/aarch64-linux-gnu/kodi/kodi-gbm \
    /usr/local/lib/aarch64-linux-gnu/kodi/kodi.bin \
    /usr/lib/aarch64-linux-gnu/kodi/kodi.bin
  do
    [[ -x "$candidate" ]] && printf '%s\n' "$candidate" && return 0
  done
  return 1
}

backup_item() {
  local source="$1" target_dir="$2" name="$3"
  if [[ -e "$source" || -L "$source" ]]; then
    cp -a "$source" "$target_dir/$name"
  fi
}

create_backup() {
  local log_file="$1"
  local ts backup
  ts="$(date +%F_%H%M%S)"
  backup="${BACKUP_ROOT}/${ts}"
  mkdir -p "$backup"
  backup_item /usr/local/bin/kodi "$backup" local-bin-kodi
  backup_item /usr/local/bin/kodi-TexturePacker "$backup" local-bin-kodi-TexturePacker
  backup_item /usr/local/bin/kodi-standalone "$backup" local-bin-kodi-standalone
  backup_item /usr/local/lib/aarch64-linux-gnu/kodi "$backup" local-lib-kodi
  backup_item /usr/local/share/kodi "$backup" local-share-kodi
  backup_item "$LOCAL_SHARE_ADDON_DIR" "$backup" local-share-peripheral.joystick
  backup_item "$LOCAL_LIB_ADDON_DIR" "$backup" local-lib-peripheral.joystick
  backup_item "$LEGACY_SHARE_ADDON_DIR" "$backup" legacy-share-peripheral.joystick
  backup_item "$LEGACY_LIB_ADDON_DIR" "$backup" legacy-lib-peripheral.joystick
  backup_item "$KODI_JS0_BRIDGE_DST" "$backup" kodi_js0_bridge.py
  backup_item "$KODI_JS0_BRIDGE_SERVICE" "$backup" kodi-js0-bridge.service
  log "$log_file" "backup=$backup"
}

purge_old_packages() {
  local pkg to_remove=()
  for pkg in "${OLD_PACKAGES[@]}"; do
    if package_installed "$pkg"; then
      to_remove+=("$pkg")
    fi
  done
  if ((${#to_remove[@]} > 0)); then
    apt-get -y remove --purge "${to_remove[@]}" >/dev/null
  fi
}

remove_bridge() {
  systemctl disable --now "$(basename "$KODI_JS0_BRIDGE_SERVICE")" >/dev/null 2>&1 || true
  rm -f "$KODI_JS0_BRIDGE_SERVICE" "$KODI_JS0_BRIDGE_DST"
  systemctl daemon-reload
}

install_joystick_payload() {
  rm -rf "$LOCAL_SHARE_ADDON_DIR" "$LOCAL_LIB_ADDON_DIR" "$LEGACY_SHARE_ADDON_DIR" "$LEGACY_LIB_ADDON_DIR"
  mkdir -p /usr/local/share/kodi/addons /usr/local/lib/aarch64-linux-gnu/kodi/addons
  tar -xzf "$JOYSTICK_PAYLOAD_PATH" -C /usr/local --no-same-owner
  chown -R root:root "$LOCAL_SHARE_ADDON_DIR" "$LOCAL_LIB_ADDON_DIR"
  rm -rf /home/pi/.kodi/userdata/addon_data/peripheral.joystick /root/.kodi/userdata/addon_data/peripheral.joystick
}

validate_static_state() {
  local log_file="$1" available_kodi="$2" expected_addon_version="$3" expected_addon_abi="$4"
  local kodi_binary current_addon_version current_addon_abi

  if [[ "$(installed_kodi_version)" != "$available_kodi" ]]; then
    line
    log "$log_file" "ERROR: kodi version mismatch after install"
    exit 1
  fi

  current_addon_version="$(installed_addon_version)"
  current_addon_abi="$(installed_addon_peripheral_abi)"
  log "$log_file" "Installed joystick addon version : $current_addon_version"
  log "$log_file" "Installed joystick addon ABI     : $current_addon_abi"

  if [[ "$current_addon_version" != "$expected_addon_version" ]]; then
    line
    log "$log_file" "ERROR: joystick addon version mismatch"
    exit 1
  fi
  if [[ "$current_addon_abi" != "$expected_addon_abi" ]]; then
    line
    log "$log_file" "ERROR: joystick addon ABI mismatch"
    exit 1
  fi
  if legacy_packages_present; then
    line
    log "$log_file" "ERROR: legacy Kodi packages still installed"
    exit 1
  fi
  if [[ -e "$LEGACY_SHARE_ADDON_DIR" || -e "$LEGACY_LIB_ADDON_DIR" ]]; then
    line
    log "$log_file" "ERROR: legacy joystick addon paths still present"
    exit 1
  fi
  if bridge_present; then
    line
    log "$log_file" "ERROR: legacy js0 bridge still present"
    exit 1
  fi
  if ! local_addon_layout_ok; then
    line
    log "$log_file" "ERROR: joystick addon layout invalid after install"
    exit 1
  fi

  kodi_binary="$(find_kodi_binary || true)"
  if [[ -n "$kodi_binary" ]]; then
    ldd "$kodi_binary" | tee -a "$log_file"
    if ldd "$kodi_binary" | grep -q 'not found'; then
      line
      log "$log_file" "ERROR: unresolved shared libraries for $kodi_binary"
      exit 1
    fi
  fi
}

pick_smoke_log() {
  local newest=""
  local candidate
  for candidate in /home/pi/.kodi/temp/kodi.log /root/.kodi/temp/kodi.log; do
    if [[ -f "$candidate" ]]; then
      if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
        newest="$candidate"
      fi
    fi
  done
  [[ -n "$newest" ]] && printf '%s
' "$newest"
}

run_smoke_test() {
  local log_file="$1"
  local kodi_log js_present="NO"

  [[ "$RUN_KODI_SMOKE_TEST" == "YES" ]] || {
    log "$log_file" "Smoke test        : skipped (RUN_KODI_SMOKE_TEST=$RUN_KODI_SMOKE_TEST)"
    return 0
  }
  [[ -x /opt/rgbpi/kodi.sh ]] || {
    log "$log_file" "Smoke test        : skipped (/opt/rgbpi/kodi.sh missing)"
    return 0
  }

  rm -f /home/pi/.kodi/temp/kodi.log /root/.kodi/temp/kodi.log
  timeout "${KODI_SMOKE_TIMEOUT}s" /opt/rgbpi/kodi.sh >/dev/null 2>&1 || true

  [[ -e /dev/input/js0 ]] && js_present="YES"
  kodi_log="$(pick_smoke_log || true)"

  if [[ -z "$kodi_log" || ! -f "$kodi_log" ]]; then
    line
    log "$log_file" "ERROR: Kodi smoke test did not produce kodi.log"
    exit 1
  fi
  log "$log_file" "Smoke log         : $kodi_log"
  if grep -qi 'incompatible' "$kodi_log"; then
    line
    log "$log_file" "ERROR: incompatible addon warning detected after install"
    exit 1
  fi
  if grep -qi 'failed to load user settings' "$kodi_log"; then
    line
    log "$log_file" "ERROR: stale joystick user settings still break startup"
    exit 1
  fi
  if ! grep -q 'AddOnLog: peripheral.joystick: Enabling joystick interface "linux"' "$kodi_log"; then
    line
    log "$log_file" "ERROR: joystick addon did not enable linux interface"
    exit 1
  fi
  if [[ "$js_present" == "YES" ]] && ! grep -q 'Register - new joystick device registered on addon->peripheral.joystick/0' "$kodi_log"; then
    line
    log "$log_file" "ERROR: js0 present but Kodi did not register a joystick device"
    exit 1
  fi

  log "$log_file" "Smoke test        : passed (js0_present=$js_present)"
  grep -nEi 'incompatible|peripheral\.joystick|Initialized joystick 0|new joystick device' "$kodi_log" | tee -a "$log_file" >/dev/null
}

main() {
  parse_args "${1:-}"
  require_root
  mkdir -p "$DOWNLOAD_DIR" "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  set_run_log "$LOG_DIR"

  bar 5 "Preparing Kodi updater"
  ensure_tooling "$LOG_FILE" "$DRY_RUN"
  bar 15 "Fetching manifest"
  if ! fetch_manifest "$LOG_FILE" "$DRY_RUN"; then
    line
    log "$LOG_FILE" "Available version : unknown"
    emit_status_lines "$(installed_kodi_version)" "unknown" "NO"
    exit 1
  fi

  local available_kodi available_addon addon_abi installed_kodi update_flag kodi_needs_update
  available_kodi="$(manifest_field kodi version)"
  available_addon="$(manifest_field kodi_joystick version)"
  addon_abi="$(manifest_field kodi_joystick peripheral_abi)"
  installed_kodi="$(installed_kodi_version)"

  collect_repair_reasons "$available_addon" "$addon_abi"

  if update_required "$installed_kodi" "$available_kodi"; then
    kodi_needs_update="YES"
  else
    kodi_needs_update="NO"
  fi

  if [[ "$kodi_needs_update" == "YES" || ${#REPAIR_REASONS[@]} -gt 0 ]]; then
    update_flag="YES"
  else
    update_flag="NO"
  fi

  log "$LOG_FILE" "Installed version : $installed_kodi"
  log "$LOG_FILE" "Available version : $available_kodi"
  log "$LOG_FILE" "Addon target      : $available_addon (ABI $addon_abi)"
  if ((${#REPAIR_REASONS[@]} > 0)); then
    log "$LOG_FILE" "Repair reasons    : ${REPAIR_REASONS[*]}"
  fi

  if [[ "$MODE" == "status" ]]; then
    bar 100 "Status ready"
    line
    emit_status_lines "$installed_kodi" "$available_kodi" "$update_flag"
    exit 0
  fi

  if [[ "$update_flag" != "YES" ]]; then
    bar 100 "No update needed"
    line
    log "$LOG_FILE" "No update performed (already clean and up to date)."
    emit_status_lines "$installed_kodi" "$available_kodi" "NO"
    exit 0
  fi

  if [[ "$kodi_needs_update" == "YES" || ! -x /usr/local/bin/kodi ]]; then
    bar 28 "Fetching kodi.deb"
    fetch_asset kodi "$KODI_DEB_PATH" "$LOG_FILE" "$DRY_RUN"
    if [[ "$DRY_RUN" != "YES" ]]; then
      bar 34 "Validating kodi.deb"
      validate_kodi_package "$LOG_FILE"
    fi
  fi

  bar 42 "Fetching joystick payload"
  fetch_asset kodi_joystick "$JOYSTICK_PAYLOAD_PATH" "$LOG_FILE" "$DRY_RUN"
  if [[ "$DRY_RUN" != "YES" ]]; then
    bar 48 "Validating joystick payload"
    validate_joystick_payload "$LOG_FILE" "$available_addon" "$addon_abi"
  fi

  bar 56 "Creating rollback backup"
  if [[ "$DRY_RUN" != "YES" ]]; then
    create_backup "$LOG_FILE"
  fi

  if [[ "$kodi_needs_update" == "YES" || ! -x /usr/local/bin/kodi ]]; then
    bar 68 "Installing kodi.deb"
    run_cmd "$LOG_FILE" "$DRY_RUN" "dpkg -i '$KODI_DEB_PATH'"
  fi

  if ((${#RUNTIME_DEPS[@]} > 0)); then
    bar 74 "Installing Kodi runtime deps"
    run_cmd "$LOG_FILE" "$DRY_RUN" "apt-get install -y ${RUNTIME_DEPS[*]} >/dev/null"
  fi

  if [[ "$AUTO_FIX_BROKEN" == "YES" ]]; then
    bar 80 "Fixing dependencies"
    run_cmd "$LOG_FILE" "$DRY_RUN" "apt-get -y --fix-broken install >/dev/null"
  fi

  bar 86 "Purging legacy Kodi pieces"
  if [[ "$DRY_RUN" != "YES" ]]; then
    purge_old_packages
  fi

  bar 92 "Installing Omega joystick addon"
  if [[ "$DRY_RUN" != "YES" ]]; then
    install_joystick_payload
    remove_bridge
  fi

  bar 96 "Validating clean state"
  if [[ "$DRY_RUN" != "YES" ]]; then
    validate_static_state "$LOG_FILE" "$available_kodi" "$available_addon" "$addon_abi"
    run_smoke_test "$LOG_FILE"
  fi

  bar 100 "Kodi update complete"
  line
  log "$LOG_FILE" "Kodi update finished"
  emit_status_lines "$(installed_kodi_version)" "$available_kodi" "NO"
}

main "$@"
