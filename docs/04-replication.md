# 04 - Replication

Target: reproduce the fix on another Linux host, verify it, and be able to undo
it.

Tested environment: Ubuntu 22.04, kernel 6.8.0 (HWE), bluez 5.64-0ubuntu1.6,
x86-64.

Patch compatibility (checked here):

| BlueZ source | applies | builds | run against the controller |
|---|---|---|---|
| Ubuntu 22.04 `5.64-0ubuntu1.6` (distro mode) | yes | yes | yes (see `05-evidence.md` for the patch revision) |
| Ubuntu 24.04 `5.72-0ubuntu5.8` (distro mode) | yes | yes (`install.sh` in a container) | no |
| Debian 12 `5.66-1+deb12u2` (distro mode) | yes | yes (`install.sh` in a container) | no |
| upstream 5.64 | yes | yes (clean Ubuntu 22.04 container) | earlier patch revisions only |
| upstream 5.66 | yes (line offsets only) | yes (clean Ubuntu 22.04 container) | no |
| upstream 5.72 | yes (line offsets only) | yes (clean Ubuntu 22.04 container) | no |

If `patch` reports fuzz on another version, it applied a hunk to slightly
different context, which must be checked by hand.

Two ways to install: the script, or the manual steps. Use the manual steps if
your distribution builds BlueZ differently (for example with separate plugin
modules), because the script assumes the plugins are linked into
`bluetoothd`, as they are in the Debian/Ubuntu and upstream builds.

---

## 1. Before you start

1. Confirm the controller is the same family: it must present `054c:09cc` and
   show the behaviour in `02-root-cause.md` (connects, drops after a few
   seconds, only `SHARE+PS` works).

   ```sh
   bluetoothctl info <BD_ADDR> | grep -E "Name|Paired|Trusted"
   ./tools/lmp-id.sh <BD_ADDR>        # expect manufacturer 1494 (JieLi)
   ```

2. Note the controller's Bluetooth address - the helper needs it:

   ```sh
   bluetoothctl devices            # or: hcitool con
   ```

3. Confirm the installed BlueZ version:

   ```sh
   bluetoothd -v
   dpkg-query -W bluez             # Debian/Ubuntu: the package version that will be patched
   ```

4. Ensure normal Bluetooth works on the host (adapter up, other devices fine).
   This fix does not touch adapter settings, only the input plugin's behaviour.

## 2. Install with the script

```sh
sudo ./install.sh --mac <BD_ADDR> --dry-run    # fetch, verify, check the patch, show the plan
sudo ./install.sh --mac <BD_ADDR>              # build + install + enable
```

What it does, in order:

1. checks that `hcitool`, `busctl`, `bluetoothctl` and `timeout` exist (the
   helper needs them) and installs `curl`, `ca-certificates`, `xz-utils`,
   `patch` and `dpkg-dev` if a tool is missing (`--dry-run` only reports it);
2. **distro mode** (default on Debian/Ubuntu): writes a temporary apt
   configuration with `deb-src` entries for the archives the installed `bluez`
   came from, and fetches the source package of exactly the installed version
   with `apt-get source` (apt verifies it against the signed archive index; the
   system's apt sources are not changed), then unpacks it with the
   distribution's patches applied;
   **upstream mode** (`--source upstream`): downloads `bluez-<version>.tar.xz`
   from kernel.org for the installed daemon's version (`bluetoothd -v`) and
   checks its SHA-256
   against the value pinned in the script (5.64, 5.66 and 5.72 are pinned).
   It refuses to run unless `ClassicBondedOnly=true` is set in
   `/etc/bluetooth/input.conf`, because upstream releases before 5.71 default
   to false (CVE-2023-45866), and it warns that the distribution's own patches
   are dropped;
3. checks the patch applies (`patch --dry-run`) before touching anything;
4. installs the build dependencies with `apt-get` (`build-essential pkg-config
   autoconf automake libtool libglib2.0-dev libdbus-1-dev libudev-dev
   libreadline-dev`; on other distributions it lists them);
5. configures with the daemon's install paths and, in distro mode, the daemon
   features the package enables in `debian/rules` (`--enable-sixaxis`,
   `--enable-experimental`, `--enable-deprecated`) and the distribution's
   hardening flags (`dpkg-buildflags`), in upstream mode `--enable-sixaxis`
   only (other distribution-specific options are not reproduced); OBEX, CUPS
   and mesh support - separate programs, not part of `bluetoothd` - are
   disabled to keep the build dependencies small. Source packages that ship
   without a generated `configure` (Debian) are bootstrapped first. Then it
   builds and strips the daemon;
6. finds the daemon that `bluetooth.service` actually starts and, if it is not
   patched, backs it up next to itself as `<daemon>.stock`;
7. installs the patched daemon there and restarts `bluetooth.service`; if the
   restart fails or the service does not come back up, it restores the backup
   and stops;
8. installs a root-owned copy of `tools/ds4-reconnect.sh` in
   `/usr/local/lib/ds4-clone-reconnect/` and the unit
   `/etc/systemd/system/ds4-clone-reconnect.service` for the given address,
   then enables and starts it. The helper logs to the journal and to
   `/var/log/ds4-clone-reconnect/`.

All of this runs in a private temporary directory that is removed afterwards.
Nothing is written to the controller.

## 3. Manual install (Debian/Ubuntu source package)

Enable `deb-src` for the archive of the installed `bluez` (or follow the
temporary-configuration approach in `install.sh`), then:

```sh
sudo apt install dpkg-dev patch build-essential pkg-config autoconf automake libtool \
                 libglib2.0-dev libdbus-1-dev libudev-dev libreadline-dev

REPO=/path/to/this/repository
cd "$(mktemp -d)"
apt-get source "bluez=$(dpkg-query -W -f='${Version}' bluez)"
cd bluez-*/
patch -p1 --dry-run < "$REPO/tools/bluez-input-hidp-clone.patch"   # expect: checking file profiles/input/device.c
patch -p1          < "$REPO/tools/bluez-input-hidp-clone.patch"

eval "$(dpkg-buildflags --export=sh)"
./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
            --libdir=/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH) --libexecdir=/usr/lib \
            --enable-sixaxis --enable-experimental --enable-deprecated \
            --disable-obex --disable-cups --disable-mesh --disable-manpages
make -j"$(nproc)"
strip --strip-unneeded src/bluetoothd

# the daemon systemd starts:
DAEMON=$(systemctl show -p ExecStart --value bluetooth.service | sed -n 's/.*path=\([^ ;]*\).*/\1/p')
sudo cp -a "$DAEMON" "$DAEMON.stock"
sudo install -m755 src/bluetoothd "$DAEMON"
sudo systemctl restart bluetooth
```

Check `debian/rules` for the `--enable-*` flags of your release; the three
above are Ubuntu 22.04's daemon-relevant ones. On other distributions, apply
the patch in the distribution's own package build (`rpmbuild`, `makepkg`, ...)
instead.

Then the helper:

```sh
sudo install -D -m755 "$REPO/tools/ds4-reconnect.sh" /usr/local/lib/ds4-clone-reconnect/ds4-reconnect.sh
sed -e "s|@HELPER@|/usr/local/lib/ds4-clone-reconnect/ds4-reconnect.sh|g" \
    -e "s|@CONTROLLER_MAC@|<BD_ADDR>|g" \
    "$REPO/tools/ds4-clone-reconnect.service.in" \
  | sudo tee /etc/systemd/system/ds4-clone-reconnect.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now ds4-clone-reconnect.service
```

## 4. Verify

1. Turn the controller off (hold `PS` ~10 s), then press `PS` once.
2. Within a couple of seconds:

   ```sh
   ls /dev/input/js*
   sudo dmesg | tail -5
   ```

   Expect `js0` and:

   ```
   playstation 0005:054C:09CC.xxxx: Registered DualShock4 controller
                hw_version=0x00006404 fw_version=0x00007009
   ```

3. Exercise the input. The included viewer prints every event (its rumble and
   lightbar keys work over USB only; see `README.md` §8):

   ```sh
   ./tools/ds4view.sh            # keys: 1/2 rumble, r/g/b lightbar, q quit
   ```

   Non-interactive check of buttons/sticks/triggers:

   ```sh
   sudo evtest /dev/input/eventXX     # pick "Wireless Controller"
   ```

4. Power-cycle the controller twice more. It should reconnect on every plain
   power-on without `SHARE+PS`.

5. If it does not connect:

   ```sh
   journalctl -u ds4-clone-reconnect -n 30 --no-pager
   journalctl -u bluetooth -n 30 --no-pager
   hcitool con
   ```

   The helper log should show `link up -> ConnectProfile ...` followed by
   `result: input=[/dev/input/js0 ]`.

## 5. Undo

```sh
sudo ./uninstall.sh              # restore the stock daemon, remove the service
sudo ./uninstall.sh --keep-backup
```

`uninstall.sh` always removes the service and helper. It replaces the daemon
only if the file on disk is the patched one: on Debian/Ubuntu it restores
`<daemon>.stock` only if that file matches the checksum the installed `bluez`
package records for the daemon, and otherwise (for example after a `bluez`
upgrade) reinstalls the package; it then checks that the patched daemon is
gone. Units added by hand for a second controller are not removed.

Or, without the script:

```sh
sudo systemctl disable --now ds4-clone-reconnect.service
sudo rm -rf /etc/systemd/system/ds4-clone-reconnect.service \
            /usr/local/lib/ds4-clone-reconnect /var/log/ds4-clone-reconnect
sudo systemctl daemon-reload
DAEMON=$(systemctl show -p ExecStart --value bluetooth.service | sed -n 's/.*path=\([^ ;]*\).*/\1/p')
sudo apt install --reinstall bluez     # or, if the package was not upgraded since:
                                       # sudo install -m755 "$DAEMON.stock" "$DAEMON"
sudo systemctl restart bluetooth
```

After reverting, the controller behaves as before the fix (needs `SHARE+PS`).

## 6. Troubleshooting

| Symptom | Check |
|---|---|
| Service runs, no `js0` | `hcitool con` while the controller is on: if there is no ACL, the helper is not the problem - the controller is not paging the host (link key/trust). |
| `ConnectProfile` returns an error | the D-Bus path is `/org/bluez/hci0/dev_<MAC with underscores>`; verify the adapter number (`hci0`) and that `bluetoothd` is running. |
| Connects, then drops at ~4 s | the patched daemon is not the one running: `sudo grep -ac "adopting device" /proc/$(pgrep -x bluetoothd)/exe` should print 1. |
| Patch does not apply | BlueZ version mismatch. Check `patch -p1 --dry-run` output; adapt the hunks (they are small and context-based). |
| `install.sh` stops with a SHA-256 error | the downloaded tarball is not the pinned release; do not continue. |
| `install.sh` cannot fetch the source package | the archive of the installed `bluez` version no longer carries its source (a superseded version); upgrade `bluez` first. |
| `install.sh --source upstream` refuses to run | set `ClassicBondedOnly=true` in `/etc/bluetooth/input.conf`, or use the distribution's source instead. |
| Works until the next `apt upgrade` | the `bluez` package replaced the daemon. Re-run `install.sh`. |
| Input works but no rumble/lightbar | expected over Bluetooth with this fix (`evidence/output-tests.txt`). Over USB, check udev permissions for `/dev/input/event*` and `/sys/class/leds/*` (`tools/70-ds4-debug.rules`). |
| A second identical controller | add a second unit under another name for that address (see `03-the-fix.md`, maintenance notes). |

## 7. Notes on what is replaced

- The patch modifies only `profiles/input/device.c`; no other files, no build
  system changes.
- `make install` is deliberately not used: it would overwrite more of the
  installed BlueZ than necessary. Only the daemon binary is replaced.
- In distro mode the daemon is built from the installed package's own source
  with the package's daemon features and hardening flags; on Ubuntu 22.04 the
  stripped result is 16 bytes larger than the packaged binary. Restoring the
  stock binary with `uninstall.sh` or `apt install --reinstall bluez` returns
  the host to its original state.
