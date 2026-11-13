#!/bin/bash
# uninstall.sh - restore the stock BlueZ daemon and remove the reconnect service.
#
# Usage: sudo ./uninstall.sh [--keep-backup]
#
#   --keep-backup   keep <daemon>.stock after restoring it
#   -h, --help      show this help
set -euo pipefail

KEEP=0
HELPER_DIR="/usr/local/lib/ds4-clone-reconnect"
UNIT="/etc/systemd/system/ds4-clone-reconnect.service"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die()   { echo "error: $*" >&2; exit 1; }
say()   { printf '\n== %s\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--keep-backup) KEEP=1; shift ;;
		-h|--help)     usage; exit 0 ;;
		*)             usage >&2; die "unknown option: $1" ;;
	esac
done
[ "$(id -u)" = 0 ] || die "run as root (sudo ./uninstall.sh)"

say "removing ds4-clone-reconnect.service"
systemctl disable --now ds4-clone-reconnect.service 2>/dev/null || true
rm -f "$UNIT"
rm -rf "$HELPER_DIR" /var/log/ds4-clone-reconnect
systemctl daemon-reload

DAEMON=""
EXEC="$(systemctl show -p ExecStart --value bluetooth.service 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1 || true)"
for candidate in "$EXEC" /usr/lib/bluetooth/bluetoothd /usr/libexec/bluetooth/bluetoothd /usr/sbin/bluetoothd; do
	[ -n "$candidate" ] && [ -e "$candidate" ] && { DAEMON="$(readlink -f "$candidate")"; break; }
done
[ -n "$DAEMON" ] || die "cannot find the installed bluetoothd"
STOCK_BACKUP="$DAEMON.stock"

reinstall_package() {
	say "reinstalling the bluez package"
	local log
	log="$(mktemp)"
	if command -v apt-get >/dev/null; then
		apt-get install --reinstall -y bluez </dev/null >"$log" 2>&1 || { cat "$log" >&2; rm -f "$log"; die "reinstalling bluez failed"; }
	elif command -v dnf >/dev/null; then
		dnf reinstall -y bluez >"$log" 2>&1 || { cat "$log" >&2; rm -f "$log"; die "reinstalling bluez failed"; }
	else
		rm -f "$log"
		die "cannot restore automatically - reinstall the installed version of your bluez package (on Arch from the package cache with pacman -U, to avoid a partial upgrade)"
	fi
	rm -f "$log"
}

if ! grep -qa "adopting device" "$DAEMON"; then
	say "$DAEMON is not the patched daemon - leaving it as is"
elif [ -f "$STOCK_BACKUP" ] && [ -f /var/lib/dpkg/info/bluez.md5sums ]; then
	# Only restore the backup if it is the binary of the currently installed
	# package version; after a distribution upgrade it is not.
	want="$(awk -v p="${DAEMON#/}" '$2 == p { print $1 }' /var/lib/dpkg/info/bluez.md5sums)"
	if [ -n "$want" ] && [ "$(md5sum < "$STOCK_BACKUP" | cut -d' ' -f1)" = "$want" ]; then
		say "restoring stock daemon: $STOCK_BACKUP -> $DAEMON"
		install -m755 -o root -g root "$STOCK_BACKUP" "$DAEMON"
	else
		echo "   $STOCK_BACKUP does not match the installed bluez package"
		reinstall_package
	fi
elif [ -f "$STOCK_BACKUP" ]; then
	say "restoring stock daemon: $STOCK_BACKUP -> $DAEMON"
	echo "   (backup made at install time; reinstall bluez if the package was upgraded since)"
	install -m755 -o root -g root "$STOCK_BACKUP" "$DAEMON"
else
	say "no stock backup found"
	reinstall_package
fi
if [ -f "$STOCK_BACKUP" ]; then
	if [ "$KEEP" = 1 ]; then
		echo "   backup kept at $STOCK_BACKUP"
	else
		rm -f "$STOCK_BACKUP"; echo "   backup removed (use --keep-backup to keep it)"
	fi
fi

if grep -qa "adopting device" "$DAEMON"; then
	die "$DAEMON is still the patched daemon - reinstall your bluez package manually"
fi
systemctl restart bluetooth || true
sleep 2
if systemctl is-active --quiet bluetooth; then
	echo "   bluetooth.service running with the stock daemon"
else
	echo "warning: bluetooth.service is not running - check: journalctl -u bluetooth -n 30" >&2
fi

cat <<EOT

== done

The controller will behave as before the fix (it will need SHARE+PS pairing mode
to connect). The udev rule for the viewer, if installed, is separate:
   sudo rm -f /etc/udev/rules.d/70-ds4-debug.rules
Additional units created by hand for a second controller are not removed.
EOT
