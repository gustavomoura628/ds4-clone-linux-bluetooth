#!/bin/bash
# install.sh - build and install the patched BlueZ daemon and the reconnect service.
#
# Usage:
#   sudo ./install.sh --mac AA:BB:CC:DD:EE:FF [options]
#
# Options:
#   --mac ADDR           the controller's Bluetooth address (required unless
#                        --no-service; find it with: bluetoothctl devices)
#   --source distro      (default on Debian/Ubuntu) patch the source package of
#                        the installed bluez version, keeping every fix the
#                        distribution carries
#   --source upstream    patch the kernel.org release tarball of the installed
#                        daemon's version instead; drops the distribution's own
#                        patches (see docs/04-replication.md)
#   --bluez-tarball FILE upstream mode: use a local bluez-<V>.tar.xz
#   --allow-unverified   upstream mode: accept a tarball whose SHA-256 is not
#                        pinned in this script (pinned: 5.64, 5.66, 5.72)
#   --no-service         install the patched daemon only
#   --dry-run            fetch and verify the source, check that the patch
#                        applies, print the plan; nothing is installed
#   -h, --help           show this help
#
# The build runs in a private temporary directory that is removed afterwards
# (unless KEEP_BUILD=1). A $BUILD_ROOT given in the environment is used instead,
# must be owned by root, and is kept.
# Tested on Ubuntu 22.04 (bluez 5.64-0ubuntu1.6), kernel 6.8.
# Reversible with ./uninstall.sh.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SOURCE=""
MAC=""
TARBALL=""
WITH_SERVICE=1
DRY_RUN=0
ALLOW_UNVERIFIED=0
HELPER_DIR="/usr/local/lib/ds4-clone-reconnect"
UNIT="/etc/systemd/system/ds4-clone-reconnect.service"
TOOL_DEPS="curl ca-certificates xz-utils patch dpkg-dev"
BUILD_DEPS="build-essential pkg-config autoconf automake libtool libglib2.0-dev libdbus-1-dev libudev-dev libreadline-dev"

# SHA-256 of kernel.org release tarballs, each checked against its detached
# signature (bluez-<V>.tar.sign, key E932 D120 BC2A EC44 4E55 8F01 06CA 9F5D 1DCF 2659).
declare -A BLUEZ_SHA256=(
	[5.64]=ae437e65b6b3070c198bc5b0109fe9cdeb9eaa387380e2072f9de65fe8a1de34
	[5.66]=39fea64b590c9492984a0c27a89fc203e1cdc74866086efb8f4698677ab2b574
	[5.72]=499d7fa345a996c1bb650f5c6749e1d929111fa6ece0be0e98687fee6124536e
)

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die()   { echo "error: $*" >&2; exit 1; }
say()   { printf '\n== %s\n' "$*"; }
warn()  { printf 'warning: %s\n' "$*" >&2; }
need_arg() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (see --help)"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--mac)              need_arg "$@"; MAC="$2"; shift 2 ;;
		--source)           need_arg "$@"; SOURCE="$2"; shift 2 ;;
		--bluez-tarball)    need_arg "$@"; TARBALL="$2"; shift 2 ;;
		--allow-unverified) ALLOW_UNVERIFIED=1; shift ;;
		--no-service)       WITH_SERVICE=0; shift ;;
		--dry-run)          DRY_RUN=1; shift ;;
		-h|--help)          usage; exit 0 ;;
		*)                  usage >&2; die "unknown option: $1" ;;
	esac
done

[ "$(id -u)" = 0 ] || die "run as root (sudo ./install.sh ...)"
PATCH="$REPO_DIR/tools/bluez-input-hidp-clone.patch"
[ -f "$PATCH" ] || die "patch not found: $PATCH"

if [ "$WITH_SERVICE" = 1 ]; then
	[ -n "$MAC" ] || die "--mac is required (or pass --no-service)"
	[[ "$MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || die "not a Bluetooth address: $MAC"
	MAC="${MAC^^}"
	for t in hcitool busctl bluetoothctl timeout; do
		command -v "$t" >/dev/null || die "$t not found; the reconnect helper needs it (see README, Requirements)"
	done
fi

# --- the installed daemon (the path systemd actually starts) ----------------
DAEMON=""
EXEC="$(systemctl show -p ExecStart --value bluetooth.service 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1 || true)"
for candidate in "$EXEC" /usr/lib/bluetooth/bluetoothd /usr/libexec/bluetooth/bluetoothd /usr/sbin/bluetoothd; do
	[ -n "$candidate" ] && [ -e "$candidate" ] && { DAEMON="$(readlink -f "$candidate")"; break; }
done
[ -n "$DAEMON" ] || die "cannot find the installed bluetoothd"
STOCK_BACKUP="$DAEMON.stock"
DAEMON_VERSION="$("$DAEMON" -v 2>/dev/null || true)"

DISTRO_VERSION="$(dpkg-query -W -f='${Version}' bluez 2>/dev/null || true)"
if [ -z "$SOURCE" ]; then
	if [ -n "$DISTRO_VERSION" ] && command -v apt-get >/dev/null; then
		SOURCE=distro
	else
		die "no Debian/Ubuntu bluez package found. Rebuild your distribution's bluez package with tools/bluez-input-hidp-clone.patch, or pass --source upstream (see docs/04-replication.md)"
	fi
fi
case "$SOURCE" in distro|upstream) ;; *) die "--source must be distro or upstream" ;; esac

# --- tools needed before the build dependencies -----------------------------
missing=""
for t in tar xz patch sha256sum; do command -v "$t" >/dev/null || missing="$missing $t"; done
[ "$SOURCE" = upstream ] && { command -v curl >/dev/null || missing="$missing curl"; }
[ "$SOURCE" = distro ] && { command -v dpkg-source >/dev/null || missing="$missing dpkg-source"; }
if [ -n "$missing" ]; then
	if [ "$DRY_RUN" = 0 ] && command -v apt-get >/dev/null; then
		say "installing required tools:$missing"
		# shellcheck disable=SC2086
		apt-get install -y --no-install-recommends $TOOL_DEPS </dev/null >/dev/null
	else
		die "missing tools:$missing (Debian/Ubuntu: apt-get install $TOOL_DEPS)"
	fi
fi

# --- private build directory ------------------------------------------------
if [ -n "${BUILD_ROOT:-}" ]; then
	mkdir -p "$BUILD_ROOT"
	BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd)"
	[ "$(stat -c %u "$BUILD_ROOT")" = 0 ] || die "BUILD_ROOT $BUILD_ROOT is not owned by root"
	CLEANUP=0
else
	BUILD_ROOT="$(mktemp -d -t bluez-clone-build.XXXXXX)"
	CLEANUP=1
fi
[ "${KEEP_BUILD:-0}" = 1 ] && CLEANUP=0
cleanup() { if [ "$CLEANUP" = 1 ]; then rm -rf "$BUILD_ROOT"; fi; }
trap cleanup EXIT

say "patch:   $PATCH"
say "daemon:  $DAEMON (${DAEMON_VERSION:-unknown version})"
say "build:   $BUILD_ROOT"

# --- source -----------------------------------------------------------------
if [ "$SOURCE" = distro ]; then
	say "source:  distribution package bluez $DISTRO_VERSION"
	# A throwaway apt configuration with deb-src entries for the archives the
	# installed bluez came from; the system's apt configuration is not changed
	# and apt still verifies the signed Release files.
	APTD="$BUILD_ROOT/apt"
	mkdir -p "$APTD/lists/partial" "$APTD/cache/archives/partial" "$APTD/parts"
	: > "$APTD/sources.list"
	# archives (URIs) that provide the installed version
	URIS="$(apt-cache policy bluez | awk '
		/^ \*\*\* / { f = 1; next }
		f && /^     [^ ]/ { f = 0 }
		f && $2 ~ /^https?:/ { print $2 }
	' | sort -u)"
	[ -n "$URIS" ] || die "cannot determine the archive of the installed bluez ($DISTRO_VERSION)"
	# the system's own entries for those archives, as deb-src: one-line
	# format (*.list) and deb822 (*.sources), keeping options such as signed-by
	for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
		[ -f "$f" ] || continue
		awk -v uris="$URIS" '
			BEGIN { n = split(uris, u, "\n") }
			/^[[:space:]]*deb[[:space:]]/ {
				for (i = 1; i <= n; i++) if (index($0, u[i] "/") || index($0, u[i] " ")) {
					sub(/^[[:space:]]*deb[[:space:]]/, "deb-src "); print; break
				}
			}' "$f" >> "$APTD/sources.list"
	done
	for f in /etc/apt/sources.list.d/*.sources; do
		[ -f "$f" ] || continue
		awk -v uris="$URIS" '
			BEGIN { n = split(uris, u, "\n"); RS = ""; ORS = "\n\n" }
			{
				hit = 0
				for (i = 1; i <= n; i++) if (index($0, u[i] "/") || index($0, u[i] "\n") || index($0, u[i] " ")) hit = 1
				if (hit && $0 ~ /(^|\n)Types:[^\n]*deb([ \n]|$)/) {
					gsub(/(^|\n)Types:[^\n]*/, "\nTypes: deb-src"); sub(/^\n/, ""); print
				}
			}' "$f" >> "$APTD/parts/system.sources"
	done
	[ -s "$APTD/sources.list" ] || [ -s "$APTD/parts/system.sources" ] || \
		die "no apt source entry found for $URIS"
	APTOPT=(-o Dir::Etc::SourceList="$APTD/sources.list" -o Dir::Etc::SourceParts="$APTD/parts"
		-o Dir::State::Lists="$APTD/lists" -o Dir::Cache="$APTD/cache" -o APT::Sandbox::User=root)
	apt-get "${APTOPT[@]}" update >/dev/null || die "apt-get update for the bluez source failed"
	mkdir -p "$BUILD_ROOT/pkg"
	( cd "$BUILD_ROOT/pkg" && apt-get "${APTOPT[@]}" source --download-only "bluez=$DISTRO_VERSION" >/dev/null ) \
		|| die "cannot download the source of bluez $DISTRO_VERSION"
	SRC="$BUILD_ROOT/bluez-src"
	dpkg-source -x "$BUILD_ROOT"/pkg/bluez_*.dsc "$SRC" >/dev/null 2>&1 || die "dpkg-source could not unpack the bluez source"
	echo "   source package fetched and verified by apt"
else
	BLUEZ_VERSION="$DAEMON_VERSION"
	[[ "$BLUEZ_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || die "cannot determine the installed daemon's version ('$BLUEZ_VERSION')"
	if [ -n "$DISTRO_VERSION" ] || command -v rpm >/dev/null || command -v pacman >/dev/null; then
		warn "the upstream tarball drops every patch your distribution applies to bluez,"
		warn "including security fixes; prefer --source distro or a rebuilt distribution package"
	fi
	grep -Eq '^[[:space:]]*ClassicBondedOnly[[:space:]]*=[[:space:]]*true' /etc/bluetooth/input.conf 2>/dev/null || \
		die "set ClassicBondedOnly=true in /etc/bluetooth/input.conf first: upstream releases before 5.71 default to false (CVE-2023-45866)"
	say "source:  upstream bluez-$BLUEZ_VERSION.tar.xz"
	SRC_TAR="$BUILD_ROOT/bluez-$BLUEZ_VERSION.tar.xz"
	if [ -n "$TARBALL" ]; then
		cp "$TARBALL" "$SRC_TAR"
	else
		curl -fsSL -o "$SRC_TAR" "https://www.kernel.org/pub/linux/bluetooth/bluez-$BLUEZ_VERSION.tar.xz"
	fi
	SUM="$(sha256sum "$SRC_TAR" | cut -d' ' -f1)"
	EXPECTED="${BLUEZ_SHA256[$BLUEZ_VERSION]:-}"
	if [ -n "$EXPECTED" ]; then
		[ "$SUM" = "$EXPECTED" ] || die "SHA-256 mismatch for bluez-$BLUEZ_VERSION.tar.xz: got $SUM"
		echo "   SHA-256 verified"
	elif [ "$ALLOW_UNVERIFIED" = 1 ]; then
		warn "no pinned SHA-256 for $BLUEZ_VERSION; continuing because of --allow-unverified ($SUM)"
	else
		die "no pinned SHA-256 for BlueZ $BLUEZ_VERSION; verify the tarball's .sign yourself and pass --allow-unverified"
	fi
	tar xf "$SRC_TAR" -C "$BUILD_ROOT"
	SRC="$BUILD_ROOT/bluez-$BLUEZ_VERSION"
fi
[ -d "$SRC" ] || die "source directory not found: $SRC"

# --- patch ------------------------------------------------------------------
say "checking the patch applies"
CHECK="$(patch -p1 -N -d "$SRC" --dry-run < "$PATCH" 2>&1)" || {
	printf '%s\n' "$CHECK" >&2
	die "patch does not apply to this bluez source"
}
printf '%s\n' "$CHECK" | sed 's/^/   /'

# configure flags: install paths of the installed daemon; for distro sources
# also the daemon features the package enables in debian/rules
CONFIG_FLAGS=(--prefix=/usr --sysconfdir=/etc --localstatedir=/var
	--disable-obex --disable-cups --disable-mesh --disable-manpages)
if [ "$SOURCE" = upstream ]; then
	# the plugin most distributions enable; other distribution-specific
	# configure options are not reproduced (see docs/04-replication.md)
	CONFIG_FLAGS+=(--enable-sixaxis)
fi
if [ "$SOURCE" = distro ]; then
	MA="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null)"
	CONFIG_FLAGS+=(--libdir="/usr/lib/$MA" --libexecdir="$(dirname "$(dirname "$DAEMON")")")
	for f in sixaxis experimental deprecated; do
		grep -q -- "--enable-$f" "$SRC/debian/rules" && CONFIG_FLAGS+=("--enable-$f")
	done
fi

if [ "$DRY_RUN" = 1 ]; then
	say "dry run complete - would now build and install:"
	cat <<EOF
   apt-get install $BUILD_DEPS
   ./configure ${CONFIG_FLAGS[*]} && make
   back up $DAEMON to $STOCK_BACKUP if it is unpatched
   install the patched bluetoothd over it and restart bluetooth.service
EOF
	[ "$WITH_SERVICE" = 1 ] && cat <<EOF
   install tools/ds4-reconnect.sh to $HELPER_DIR/
   install $UNIT for $MAC, enable and start it
EOF
	exit 0
fi

# --- build ------------------------------------------------------------------
patch -p1 -N -d "$SRC" < "$PATCH" >/dev/null
if command -v apt-get >/dev/null; then
	# systemd.pc moved to systemd-dev in newer Debian/Ubuntu releases
	if apt-cache show systemd-dev >/dev/null 2>&1; then BUILD_DEPS="$BUILD_DEPS systemd-dev"; fi
	say "installing build dependencies"
	# shellcheck disable=SC2086
	apt-get install -y --no-install-recommends $BUILD_DEPS </dev/null >/dev/null
else
	warn "apt-get not found: install the equivalents of these packages yourself:"
	warn "  $BUILD_DEPS"
fi

say "configure + build (this takes a few minutes)"
(
	cd "$SRC"
	if command -v dpkg-buildflags >/dev/null; then eval "$(dpkg-buildflags --export=sh)"; fi
	if [ ! -x configure ]; then
		# some source packages (Debian) ship without the generated configure
		if [ -x bootstrap ]; then ./bootstrap >/dev/null 2>&1; else autoreconf -fi >/dev/null 2>&1; fi
	fi
	./configure "${CONFIG_FLAGS[@]}" >/dev/null
	make -j"$(nproc)" >/dev/null
	strip --strip-unneeded src/bluetoothd
)
grep -qa "adopting device" "$SRC/src/bluetoothd" || die "built daemon does not contain the patch"
echo "   built: $SRC/src/bluetoothd"

# --- install daemon ---------------------------------------------------------
say "installing patched daemon to $DAEMON"
if grep -qa "adopting device" "$DAEMON"; then
	if [ -e "$STOCK_BACKUP" ]; then
		echo "   installed daemon is already patched; keeping the backup at $STOCK_BACKUP"
	else
		warn "$DAEMON is already patched and there is no backup; uninstall.sh will reinstall the package"
	fi
else
	cp -a "$DAEMON" "$STOCK_BACKUP"
	echo "   stock daemon backed up to $STOCK_BACKUP"
fi
install -m755 -o root -g root "$SRC/src/bluetoothd" "$DAEMON"
if ! systemctl restart bluetooth || { sleep 2; ! systemctl is-active --quiet bluetooth; }; then
	warn "bluetooth.service did not start with the patched daemon - restoring the backup"
	[ -e "$STOCK_BACKUP" ] && install -m755 -o root -g root "$STOCK_BACKUP" "$DAEMON"
	systemctl restart bluetooth || true
	die "patched daemon failed to start; see: journalctl -u bluetooth -n 30"
fi
echo "   bluetooth.service restarted"

# --- install service --------------------------------------------------------
if [ "$WITH_SERVICE" = 1 ]; then
	say "installing ds4-clone-reconnect.service for $MAC"
	install -D -m755 -o root -g root "$REPO_DIR/tools/ds4-reconnect.sh" "$HELPER_DIR/ds4-reconnect.sh"
	sed -e "s|@HELPER@|$HELPER_DIR/ds4-reconnect.sh|g" -e "s|@CONTROLLER_MAC@|$MAC|g" \
		"$REPO_DIR/tools/ds4-clone-reconnect.service.in" > "$UNIT"
	systemctl daemon-reload
	systemctl enable ds4-clone-reconnect.service >/dev/null 2>&1 || warn "could not enable ds4-clone-reconnect.service"
	systemctl restart ds4-clone-reconnect.service || true
	sleep 1
	if systemctl is-active --quiet ds4-clone-reconnect.service; then
		echo "   service running"
	else
		warn "service is not running - check: journalctl -u ds4-clone-reconnect"
	fi
fi

cat <<EOF

== done

Now test it:
  1. turn the controller off (hold PS ~10 s), then press PS once
  2. within a few seconds you should see:  ls /dev/input/js*
  3. and:  sudo dmesg | tail -5     (expect "Registered DualShock4 controller ...")
  4. if it does not connect:  journalctl -u ds4-clone-reconnect -n 20 --no-pager

Revert with:  sudo ./uninstall.sh
EOF
