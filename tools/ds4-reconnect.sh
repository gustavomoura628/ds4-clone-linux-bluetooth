#!/bin/bash
# ds4-reconnect.sh - activate the HID profile for a DualShock-4-compatible
# controller as soon as its ACL link appears.
#
# Why this is needed: on a plain power-on these controllers request the HIDP
# control channel before their link is encrypted; the kernel refuses it, the
# controller never retries, and BlueZ does not initiate profiles for inbound
# connections - so the unused link is dropped after a few seconds. Activating
# the HID profile from the host side inside that window (Device1.ConnectProfile
# with the HID UUID) makes the connection succeed; `bluetoothctl connect` is
# used only as a fallback.
#
# Host-side only. Nothing is written to the controller.
#
# Usage:   ./ds4-reconnect.sh <BD_ADDR>
# Runs until killed (this is what the systemd unit does). Logs to stdout and to
# $LOGDIR (default: <repository>/logs).
#
# Licence: MIT (see LICENSE).

set -u
MAC=${1:-}
if ! [[ "$MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
  echo "usage: $0 <BD_ADDR>   (find it with: bluetoothctl devices)" >&2
  exit 2
fi
MAC=${MAC^^}
for t in hcitool busctl bluetoothctl; do
  command -v "$t" >/dev/null || { echo "error: $t not found (see README, Requirements)" >&2; exit 1; }
done
MAC_LC=${MAC,,}
HID_UUID=00001124-0000-1000-8000-00805f9b34fb
DEV=/org/bluez/hci0/dev_${MAC//:/_}
HERE=$(cd "$(dirname "$0")" && pwd)
LOGDIR=${LOGDIR:-$HERE/../logs}
mkdir -p "$LOGDIR"
LOG="$LOGDIR/reconnect-$(date +%Y%m%d-%H%M%S).log"

say() { echo "$(date +%T.%3N) $*" | tee -a "$LOG"; }
# joystick nodes belonging to this controller (matched by the input device's uniq = its address)
jsdevs() {
  local d
  for d in /sys/class/input/js*; do
    [ -e "$d/device/uniq" ] && [ "$(cat "$d/device/uniq")" = "$MAC_LC" ] && printf '/dev/input/%s ' "${d##*/}"
  done
}

say "watching $MAC (log $LOG)  input devices before: [$(jsdevs)]"
seen=0
while true; do
  if hcitool con 2>/dev/null | grep -qi "$MAC"; then
    if [ "$seen" = 0 ]; then
      seen=1
      if [ -n "$(jsdevs)" ]; then
        say "link up, input device already present - nothing to do"
      else
        say "link up -> ConnectProfile $HID_UUID"
        timeout 10 busctl call org.bluez "$DEV" org.bluez.Device1 \
                ConnectProfile s "$HID_UUID" 2>&1 | tee -a "$LOG"
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          sleep 0.2
          [ -n "$(jsdevs)" ] && break
        done
        if [ -z "$(jsdevs)" ]; then
          say "no input device yet - falling back to a plain connect"
          bluetoothctl --timeout 6 connect "$MAC" 2>&1 | tail -2 | tee -a "$LOG"
          sleep 0.5
        fi
        say "result: input=[$(jsdevs)]  links=$(hcitool con | grep -ci "$MAC")"
      fi
    fi
  else
    seen=0
  fi
  sleep 0.1
done
