#!/bin/bash
# lmp-id.sh - identify a Bluetooth controller's baseband vendor.
#
# Reads the Link Manager Protocol version, subversion and manufacturer ID of the
# *remote* device with `hcitool info`. On DS4-compatible clones this names the
# radio silicon (e.g. manufacturer 1494 = Zhuhai Jieli), independently of the USB
# descriptors the device may be copying.
#
# The controller must be connected (or at least pairable) for this to work;
# the command queries the live ACL link.
#
# Read-only. No writes to the controller.
#
# Usage: ./lmp-id.sh <BD_ADDR>
# Licence: MIT (see LICENSE).
set -u

MAC=${1:-}
if [ -z "$MAC" ]; then
    echo "usage: $0 <BD_ADDR>   (find it with: bluetoothctl devices)" >&2
    exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
LOGDIR=${LOGDIR:-$HERE/../logs}
mkdir -p "$LOGDIR"
LOG="$LOGDIR/lmp-id-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "### lmp-id $(date -Is)  target=$MAC  log=$LOG"

if ! hcitool con 2>/dev/null | grep -qi "$MAC"; then
    echo "### controller is not connected yet; turn it on and let it connect"
    echo "### (with the reconnect helper installed, pressing PS is enough)"
fi

echo "=== hcitool con ==="
hcitool con

echo "=== hcitool info (name, class, LMP version / subversion / manufacturer) ==="
hcitool info "$MAC"

echo "=== remote LMP feature pages ==="
hcitool features "$MAC" 2>/dev/null || true

echo "=== link quality ==="
hcitool rssi "$MAC" 2>/dev/null || true
hcitool lq "$MAC" 2>/dev/null || true

echo "### done $(date -Is)"
echo "### Look for the 'Manufacturer:' line above: that is the baseband vendor."
