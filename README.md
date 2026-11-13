# Bluetooth connection drops on a third-party DualShock 4-compatible controller

Technical write-up and working fix for a class of DS4 clones that connect for a
few seconds and then disconnect on Linux, while reportedly working with other
hosts.

The fix has two parts: a small patch to BlueZ's input plugin, and a helper that
activates the HID profile from the host side when the controller appears. Both
are included, with build/install scripts, the evidence they are based on, and
tools used during the investigation.

- **Tested on:** Ubuntu 22.04, kernel 6.8.0 (HWE), bluez 5.64-0ubuntu1.6, x86-64
- **Controller:** `054c:09cc` / `054c:0268` (DualShock 4 v2 / Sixaxis identities),
  JieLi-based clone
- **Result:** plain power-on + `PS` connects and stays connected with full input;
  no pairing-mode workaround needed. Rumble and lightbar do not work over
  Bluetooth (section 8)
- **Nothing is written to the controller.** All changes are host-side and
  reversible. On Debian/Ubuntu the patched daemon is built from the
  distribution's own bluez source package, so its security fixes are kept.

---

## 1. Summary

| | |
|---|---|
| **Symptom** | On a plain power-on the controller connects, produces no input, and drops the link after about 4 s. Only `SHARE+PS` (pairing mode) ever worked. |
| **Cause (controller)** | The firmware requests the HIDP control channel about 55 ms before its own link is encrypted. The kernel refuses it (`security block`), and the firmware never retries. |
| **Cause (host)** | BlueZ does not initiate HIDP for inbound ACL connections, so no channel is ever opened; the kernel drops the unused link after ~4 s with reason `0x05`, and the controller powers off. |
| **Second failure mode** | When the host does initiate, the controller still opens its own interrupt channel and sends its input only on that one. The daemon rejects it with `-EALREADY` and closes it, and the controller hangs up. |
| **Fix** | (1) BlueZ patch: for Sony-VID devices, adopt the controller-initiated interrupt channel instead of refusing it with `-EALREADY`, and abort the host's superseded connect safely. (2) Helper: call `Device1.ConnectProfile` for the HID UUID as soon as the link appears, so that the host opens the control channel on the encrypted link. |
| **Verified** | `js0` and full evdev input (all buttons, both sticks, both triggers, d-pad); reconnects after a power cycle. What ran with which patch revision: [`docs/05-evidence.md`](docs/05-evidence.md). |
| **Not working** | Rumble and lightbar over Bluetooth with the fix: the controller ignores output reports on the channel it opened itself. Rumble works in a `SHARE+PS` session; the lightbar works only over USB. See [`evidence/output-tests.txt`](evidence/output-tests.txt). |

## 2. The device

A third-party controller that presents itself as a genuine Sony DualShock 4 and
switches to a Sixaxis (`054c:0268`) personality at runtime. It reproduces the
DS4 report descriptor and genuine firmware-identity values, but has no motion sensors, a
much lower report rate, and a different Bluetooth baseband (JieLi, manufacturer
ID 1494) than any Sony part. Details, fingerprints and the analysis method:
[`docs/01-device-identification.md`](docs/01-device-identification.md).

The identification is useful for two reasons: it explains why vendor tools and
"is my controller genuine" websites misclassify the device, and it makes the
failure mode reproducible - the same Bluetooth bug is likely to affect other
controllers built on the same firmware family.

## 3. Root cause in one trace

Power-on, from the Bluetooth trace
([`evidence/btmon-failed-connect.txt`](evidence/btmon-failed-connect.txt)):

| time from Connect Complete | event |
|---|---|
| +126 ms | controller requests authentication; host supplies the stored link key |
| +208 ms | controller requests HIDP **PSM 17** |
| +208 ms | kernel: `Connection refused - security block (0x0003)` |
| +264 ms | link encryption completes |
| +4.07 s | kernel disconnects the unused link, reason `0x05` |

The controller asks 56 ms too early (54.6-56.3 ms across the three captures) and never
retries; the kernel is right to refuse it (`net/bluetooth/l2cap_core.c` refuses
every PSM except SDP until a Secure Simple Pairing link is encrypted). Full
analysis with the relevant kernel and BlueZ source paths:
[`docs/02-root-cause.md`](docs/02-root-cause.md).

## 4. The fix

**Part 1 - BlueZ patch** ([`tools/bluez-input-hidp-clone.patch`](tools/bluez-input-hidp-clone.patch),
`profiles/input/device.c` only):

- `input_device_set_channel()`: for a device with Sony's vendor ID (`0x054c`),
  adopt the interrupt channel the controller opened while the host's own
  interrupt connect is still pending, instead of returning `-EALREADY`; abort
  the pending connect, and report a failure if the session cannot be created.
- `interrupt_connect_cb()`: close the aborted host connect without touching the
  adopted channel or the session.
- Every other device, and a session already running on a host-opened channel,
  is handled as upstream.

**Part 2 - reconnect helper** ([`tools/ds4-reconnect.sh`](tools/ds4-reconnect.sh),
installed as `ds4-clone-reconnect.service`): when the controller's ACL link
appears, it calls `Device1.ConnectProfile` with the HID UUID
`00001124-0000-1000-8000-00805f9b34fb`. That makes the host open the HIDP
control channel once the link is encrypted, which the controller never does
itself after its early request is refused. The working session combines that
host-opened control channel with the controller's own interrupt channel.

Rationale, alternatives considered and limitations:
[`docs/03-the-fix.md`](docs/03-the-fix.md).

## 5. Quick start

```sh
# 1. find the controller's Bluetooth address (turn it on first)
bluetoothctl devices

# 2. fetch and verify the bluez source, check that the patch applies, see the plan
sudo ./install.sh --mac <BD_ADDR> --dry-run

# 3. build and install (installs build deps, the patched bluetoothd and the
#    systemd service; the stock daemon is backed up)
sudo ./install.sh --mac <BD_ADDR>

# 4. test: controller off (hold PS ~10 s), press PS once
ls /dev/input/js*
sudo dmesg | tail -5        # expect "Registered DualShock4 controller ..."
```

Step-by-step manual build, verification checklist, troubleshooting and revert:
[`docs/04-replication.md`](docs/04-replication.md).
Revert: `sudo ./uninstall.sh`.

## 6. Requirements

- **Runtime:** systemd (`busctl`), coreutils `timeout`, and BlueZ's
  `bluetoothctl` and `hcitool`. Ubuntu 22.04's `bluez` package includes both;
  distributions that dropped `hcitool` ship it separately (e.g.
  `bluez-deprecated-tools` on Arch, `bluez-deprecated` on Fedora), and Arch has
  `bluetoothctl` in `bluez-utils`.
- **Build:** a C toolchain plus the BlueZ build dependencies. On Debian/Ubuntu
  `install.sh` installs them: `curl ca-certificates xz-utils patch dpkg-dev
  build-essential pkg-config autoconf automake libtool libglib2.0-dev
  libdbus-1-dev libudev-dev libreadline-dev`. The `deb-src` lines it needs are created in a
  temporary apt configuration; the system's apt sources are not changed.
- **Viewer (optional):** [`uv`](https://docs.astral.sh/uv/), which fetches
  `pygame-ce` and `evdev` for `tools/ds4view.py`.

## 7. What is in this repository

```
README.md                     this file
install.sh / uninstall.sh     build + install / restore
MANIFEST.sha256               SHA-256 of every file
.gitignore                    ignores logs/ written by the tools
docs/
  01-device-identification.md what the controller is, and how that was established
  02-root-cause.md            the failure analysis, with kernel and BlueZ references
  03-the-fix.md               the patch and the helper, why each is needed
  04-replication.md           clean-system walkthrough, verify, revert, troubleshooting
  05-evidence.md              index of the raw evidence and how it was captured
  LICENSE-CC-BY-4.0.txt       licence of the documentation
tools/
  bluez-input-hidp-clone.patch BlueZ patch (GPL-2.0-or-later; see NOTICE)
  ds4-reconnect.sh            profile-activation helper (installed for the service)
  ds4-clone-reconnect.service.in   systemd unit template
  lmp-id.sh                   reads the controller's Bluetooth baseband vendor
  ds4_features.py             reads feature reports (firmware identity, pairing info)
  ds4view.py / ds4view.sh     live input viewer with rumble/lightbar test keys (USB only)
  70-ds4-debug.rules          optional udev rule for the viewer (input nodes, LEDs)
evidence/                     Bluetooth traces, daemon logs, descriptors, feature reports, I/O tests
LICENSE                       MIT (code and scripts)
NOTICE                        third-party licences and attributions
```

## 8. Scope

- **Distributions.** On Debian/Ubuntu, `install.sh` patches the source package
  of the installed `bluez` version, so the daemon keeps every fix the
  distribution ships; it was run with Ubuntu 22.04's `5.64-0ubuntu1.6`. On
  other distributions, rebuild the distribution's `bluez` package with the
  patch. `install.sh --source upstream` patches the kernel.org tarball of the
  installed daemon's version instead; that drops the distribution's patches,
  including security fixes, and its configure options other than
  `--enable-sixaxis`, and it is refused unless `ClassicBondedOnly=true` is set
  (CVE-2023-45866).
- **Versions.** The patch also applies to upstream 5.64, 5.66 and 5.72 (line
  offsets only, no fuzz), and those trees build in a clean Ubuntu 22.04
  container; only 5.64 was run against the controller.
- **Upgrades.** Distribution packages overwrite the daemon on upgrade - re-run
  `install.sh` after `bluez` updates.
- **Scope of the patch.** Adoption is limited to devices with Sony's vendor ID
  (`0x054c`), which includes genuine Sony controllers; for them it only changes
  the case where their interrupt channel request collides with a pending host
  connect.
- The helper uses `hci0`; adapt `DEV` in
  `tools/ds4-reconnect.sh` for other adapter numbering.
- Rumble and lightbar do not work over Bluetooth with the fix. In the tests the
  controller acted on output reports only when they arrived on a host-opened
  interrupt channel (rumble then worked; the lightbar never changed over
  Bluetooth), but it sends input only on the channel it opened itself, and the
  kernel's HIDP session uses one interrupt channel for both directions. Fixing
  that is outside this patch.
- Not addressed: the controller's own quirks (no IMU, low report rate, PS3-mode
  switching, transport-dependent firmware identity). Those are documented, not
  fixed - they are firmware behaviour.
- If rebuilding BlueZ is not an option, `SHARE+PS` pairing remains a working
  (if inconvenient) fallback: it forces the host-initiated path that the
  unpatched daemon also accepts.

## 9. Licence and attribution

Code and scripts: MIT (see `LICENSE`). Documentation and the files in
`evidence/`: CC BY 4.0. The BlueZ patch
is a derivative of BlueZ and stays under GPL-2.0-or-later (see `NOTICE`).
Nothing in this repository is derived from Sony firmware or Sony tooling; the
firmware-identity analysis is based on publicly available device behaviour and
public documentation of the protocol.
