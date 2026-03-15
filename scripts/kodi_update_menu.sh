#!/usr/bin/env bash
# Controller-friendly menu wrapper for Kodi updater.
# Shows "UPDATE NOW" only when a newer version is available.

set -euo pipefail

UPDATER_SCRIPT="/home/pi/ports/update_kodi.sh"
STATUS_FILE="/tmp/kodi_update_status.txt"

if [[ ! -x "$UPDATER_SCRIPT" ]]; then
  echo "Updater script not found: $UPDATER_SCRIPT"
  exit 1
fi

# Build status snapshot from updater itself (single source of truth).
sudo bash "$UPDATER_SCRIPT" --status > "$STATUS_FILE" 2>&1 || true

INSTALLED="$(grep -E 'Installed version\s*:' "$STATUS_FILE" | tail -n1 | sed 's/.*: //')"
AVAILABLE="$(grep -E 'Available version\s*:' "$STATUS_FILE" | tail -n1 | sed 's/.*: //')"
UPD_AVAILABLE_LINE="$(grep -E '^UPDATE_AVAILABLE=' "$STATUS_FILE" | tail -n1 || true)"

if [[ "$UPD_AVAILABLE_LINE" == "UPDATE_AVAILABLE=YES" ]]; then
  MENU_TEXT="Installed: ${INSTALLED:-unknown}\nAvailable: ${AVAILABLE:-unknown}\n\nA new update is available."
  if command -v whiptail >/dev/null 2>&1; then
    CHOICE=$(whiptail --title "Kodi Updater" --menu "$MENU_TEXT" 20 78 10 \
      "UPDATE" "UPDATE NOW" \
      "LOG" "View latest updater log" \
      "EXIT" "Return" 3>&1 1>&2 2>&3) || exit 0
  else
    echo -e "$MENU_TEXT"
    echo "1) UPDATE NOW"
    echo "2) View latest updater log"
    echo "3) Exit"
    read -r -p "Choice: " n
    case "$n" in
      1) CHOICE="UPDATE" ;;
      2) CHOICE="LOG" ;;
      *) CHOICE="EXIT" ;;
    esac
  fi
else
  MENU_TEXT="Installed: ${INSTALLED:-unknown}\nAvailable: ${AVAILABLE:-unknown}\n\nKodi is up to date."
  if command -v whiptail >/dev/null 2>&1; then
    CHOICE=$(whiptail --title "Kodi Updater" --menu "$MENU_TEXT" 20 78 10 \
      "LOG" "View latest updater log" \
      "EXIT" "Return" 3>&1 1>&2 2>&3) || exit 0
  else
    echo -e "$MENU_TEXT"
    echo "1) View latest updater log"
    echo "2) Exit"
    read -r -p "Choice: " n
    case "$n" in
      1) CHOICE="LOG" ;;
      *) CHOICE="EXIT" ;;
    esac
  fi
fi

case "$CHOICE" in
  UPDATE)
    sudo bash "$UPDATER_SCRIPT"
    ;;
  LOG)
    if command -v less >/dev/null 2>&1; then
      sudo less /var/log/kodi-updater/latest.log
    else
      sudo tail -n 200 /var/log/kodi-updater/latest.log
    fi
    ;;
  *)
    exit 0
    ;;
esac
