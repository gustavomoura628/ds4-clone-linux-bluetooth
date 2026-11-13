# 05 - Evidence index

Raw captures, how each was taken, and what it supports. The controller's
Bluetooth address (`ED:9D:F7:CA:32:D1`) is shown as-is - it is not
vendor-assigned (see `01-device-identification.md` section 4). In every file the host adapter's address is
replaced with `11:22:33:44:55:66`, the BR/EDR link key with `<redacted>`, and the
host name and local paths are removed.

The three Bluetooth runs were captured on the tested host, each from a plain
power-on of the controller, with `btmon`, `bluetoothd -d` and the kernel log
recording at the same time: failure modes A and B with Ubuntu's unmodified
`bluez 5.64-0ubuntu1.6` daemon, the fix with that package's source rebuilt by
`install.sh`.

Patch revisions: the fix run (and the power cycle in `bluetoothd-debug.txt`
part 4) used the published patch except for one condition added afterwards -
the `g_io_channel_get_close_on_unref()` check in hunk 3, which refuses a host
connect that was already shut down. On the captured path that channel is a
live btio connect, for which the check is true, so the run's code path is
unchanged; the final patch was build-tested but not re-run with the
controller. The input test and the output tests in `output-tests.txt` ran with
earlier revisions that kept the same controller-opened channel for the
session.

## Bluetooth traces

| File | How it was taken | What it shows |
|---|---|---|
| `btmon-failed-connect.txt` | `btmon -w` during a plain power-on, **unmodified** daemon, no helper (failure mode A) | Link Key Request at +126 ms, PSM 17 request at +208 ms refused with `security block`, encryption at +264 ms, kernel `Disconnect` with reason `0x05` at +4.07 s |
| `btmon-duplicate-channel-refused.txt` | same, **unmodified** daemon with `tools/ds4-reconnect.sh` running (failure mode B) | host-initiated PSM 17/19 after encryption; the controller's own PSM 19 channel is closed by the daemon while the controller is sending input on it; the controller terminates the link 200 ms later |
| `btmon-successful-connect.txt` | same, **patched** daemon + `ds4-clone-reconnect.service` (the fix) | the controller's early PSM 17 is still refused (expected); the controller's PSM 19 channel is kept and carries the input reports; the host's own pending PSM 19 channel is torn down at adoption; no disconnect for the rest of the 20 s capture; also contains the Bluetooth `0xA3` firmware-info exchange |
| `bluetoothd-debug.txt` | `bluetoothd -d` (systemd drop-in), read with `journalctl -o short-precise`, for the same three runs | A: no profile activity, disconnect reported with reason 0; B: `Refusing input device connect: Operation already in progress (114)`; fix: `adopting device intr channel`, profile reaches `connected (0)`, `closing superseded intr channel` 0.2 ms later, `encrypt_notify()`; part 4 (complete): power-off and reconnect with the same sequence |
| `reconnect-helper-log.txt` | logs of `tools/ds4-reconnect.sh` from runs B and the fix (the latter including the power cycle) | B: `ConnectProfile` fails after the controller hangs up; fix: `input=[/dev/input/js0 ]` ~0.6 s after the link, both times |
| `output-tests.txt` | evdev input check and rumble/lightbar tests over Bluetooth and USB, results as observed on the controller | all buttons, sticks, triggers and d-pad work over Bluetooth; rumble/lightbar work over USB, are ignored over Bluetooth on the controller-opened channel, and rumble (only) works on host-opened channels |

`btmon` ships with BlueZ (package `bluez` on Debian/Ubuntu, `bluez-utils` on
Arch); traces were decoded with `btmon -r <file>.btsnoop -t`.

## Device descriptors and feature reports

| File | How it was taken | What it shows |
|---|---|---|
| `lsusb-ds4-mode.txt` | `lsusb -v -d 054c:09cc` | full descriptor tree of the DS4 personality: 4 interfaces (audio control/out/in, HID), 507-byte report descriptor, full-speed |
| `lsusb-ps3-mode.txt` | `lsusb -v -d 054c:0268` | the same device after its runtime switch to the Sixaxis personality: 1 interface, 137-byte report descriptor |
| `hid-report-descriptor-ds4.txt`, `hid-report-descriptor-ps3.txt` | read from sysfs `/sys/bus/usb/devices/<port>/<if>/<hid>/report_descriptor` in each mode | the two HID report descriptors: 507 bytes with the DS4 report set; 137 bytes, a generic gamepad layout rather than the genuine Sixaxis descriptor |
| `feature-reports-usb.txt` | `tools/ds4_features.py` (hidraw `HIDIOCGFEATURE`) | the reports used by public DS4 tooling: `0x02` calibration, `0x12` pairing block, `0x81` constant "MAC", `0xA3` firmware identity answer; `0x05`, `0x06`, `0x08`, `0x10` stall |
| `feature-sweep-ds4-usb.txt` | `HIDIOCGFEATURE` for each of the 48 feature report IDs the DS4-mode descriptor declares, at the declared length and length+1 | 6 IDs answer (`0x02`, `0x12`, `0x81`, `0xA3`, `0xF1`, `0xF2`), the rest stall (`EPIPE`) |
| `feature-report-0xa3-usb-vs-bt.txt` | from the USB capture plus the Bluetooth trace | the same report over both transports, decoded: different build dates, different software versions, identical hardware/series; CRC verified |
| `bluetooth-baseband.txt` | `hcitool info <BD_ADDR>` (also wrapped by `tools/lmp-id.sh`) | LMP 5.1, subversion `0x22bb`, manufacturer 1494 = Zhuhai Jieli; identifies the radio silicon independently of the USB descriptors |

## Kernel

| File | How it was taken | What it shows |
|---|---|---|
| `dmesg-registration.txt` | `dmesg` around USB plug-in, and during the Bluetooth run with the fix | enumeration, `hid-playstation` binding, the three input nodes (gamepad, "motion sensors", touchpad), and the `Registered DualShock4 controller` line for both transports (`fw_version` `0x7008` over USB, `0x7009` over Bluetooth) |

## What is deliberately not included

- **No firmware image.** The device exposes no flash-read primitive over USB; the
  only documented read path on genuine hardware (`SET 0x08` + `GET 0x11`,
  0x800-byte flash mirror) is not implemented by this firmware. Nothing that
  writes to the device (such as a vendor programming interface) was attempted.
- **No full packet captures.** Each published trace is the window from the
  controller's Connect Request to the disconnect (or, for the fix, to the 20th
  input report); the reconnect helper's `hcitool con` polling lines are
  omitted. No other Bluetooth device appears in these windows.
- **No personal or host-identifying data.** Hostnames, user paths, and unrelated
  addresses were removed from every file in this directory.

## Reproducing a capture

```sh
sudo btmon -w /tmp/controller.btsnoop &        # start capture
# ... turn the controller off, press PS ...
sudo pkill -x btmon
btmon -r /tmp/controller.btsnoop -t > /tmp/controller.txt
```

For a successful connection, start the capture before the controller is switched
on so the whole link-setup sequence is recorded. `btmon` timestamps are
wall-clock, so the sequence in `02-root-cause.md` can be followed directly in the
file.
