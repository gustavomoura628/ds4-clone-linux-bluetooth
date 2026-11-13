# 03 - The fix

Two changes, both on the host, both reversible. Neither writes anything to the
controller.

1. **BlueZ patch** - adopt the controller's own interrupt channel instead of
   refusing it (devices with Sony's vendor ID only).
2. **Reconnect helper** - activate the HID profile from the host side the moment
   the link appears, because the daemon does not do that for inbound
   connections.

They address the two failure modes in `02-root-cause.md`: the helper starts the
direction that works (failure mode A), and the patch keeps that session alive
when the controller adds its own interrupt channel (failure mode B).

---

## 1. Part 1 - the BlueZ patch

File: `tools/bluez-input-hidp-clone.patch`, target `profiles/input/device.c`
only: an `#include <sys/socket.h>` (hunk 1), a guard in
`interrupt_connect_cb()` (hunk 2) and the adoption in
`input_device_set_channel()` (hunks 3 and 4).

### Adopt the controller's interrupt channel (hunks 3-4)

```c
	case L2CAP_PSM_HIDP_INTR:
		if (idev->intr_io && (idev->intr_watch ||
				!g_io_channel_get_close_on_unref(idev->intr_io) ||
				btd_device_get_vendor(idev->device) != 0x054c))
			return -EALREADY;
		if (idev->intr_io) {
			DBG("adopting device intr channel %p", io);
			shutdown(g_io_channel_unix_get_fd(idev->intr_io),
								SHUT_RDWR);
			g_io_channel_unref(idev->intr_io);
			idev->intr_io = NULL;
			adopted = true;
		}
		idev->intr_io = g_io_channel_ref(io);
		...
	if (idev->intr_io && idev->ctrl_io) {
		err = input_device_connadd(idev);
		if (err < 0 && adopted)
			btd_service_connecting_complete(idev->service, err);
	}
```

This is the change that addresses failure mode B. When the helper's
`ConnectProfile` is running, `idev->intr_io` holds the host's own PSM 19
connect, which has not completed when the controller's PSM 19 request arrives.
Upstream returns `-EALREADY`, and `connect_event_cb()` closes the controller's
channel; the controller reads that as a rejected connection. With the patch the
daemon takes the controller's channel instead:

- the controller's channel stays open, so it does not abandon the connection,
  and the session reads input from the only channel the controller sends it on;
- the control channel is already connected at this point, so the HIDP session
  is created immediately (`input_device_connadd()`), on connected sockets;
- if creating the session fails, the pending profile connect is completed with
  the error. Without that, nothing would report the outcome: the only path that
  does so upstream, the host connect's callback, now ignores the aborted
  connect (below).

The condition keeps everything else as upstream:

- `intr_watch` is set as soon as an interrupt channel is in use - by
  `input_device_set_channel()` for a device-opened channel, by
  `interrupt_connect_cb()` once a host-opened one has connected - so a channel
  that is already active is never replaced;
- a host connect that was already shut down (upstream `ctrl_watch_cb()` and
  `input_device_close_channels()` shut `idev->intr_io` down without clearing
  it) is recognised because `g_io_channel_shutdown()` clears `close_on_unref`,
  which btio sets on every channel it creates. Its fd number may already belong
  to another socket, so it must not be touched;
- devices whose Device ID vendor is not Sony's (`0x054c`) are refused as
  before, so an ordinary connection collision with another HID device is not
  affected. Only the interrupt channel is adopted:
this controller's own control-channel request always arrives before the link is
encrypted and is refused by the kernel, so the daemon never sees it.

### Abort and close the superseded connect (hunks 2 and 4)

The host's pending connect is owned by btio, whose connect watch keeps the
channel alive and calls `interrupt_connect_cb()` when the connect completes or
fails. Upstream, that callback acts on `idev->intr_io` - after adoption, the
controller's channel - and on failure unrefs both channels and fails the
service.

The patch therefore:

1. aborts the pending connect at adoption with `shutdown(fd, SHUT_RDWR)`. The
   kernel tears the L2CAP channel down (the host sends a Disconnection Request
   for it in the same millisecond, `evidence/btmon-successful-connect.txt`) and
   btio's callback runs at once;
2. recognises the superseded channel in `interrupt_connect_cb()`
   (`chan != idev->intr_io`), closes it, and returns without touching the
   adopted channel or the session (`closing superseded intr channel`, 0.2 ms
   after adoption in `evidence/bluetoothd-debug.txt`, parts 3 and 4).

The pending channel is shut down, not closed, at adoption. Closing it there
frees its file descriptor while btio still watches it; the next socket the
daemon opens (SDP, a fraction of a millisecond later) can reuse that number,
and btio then sees a connected fd and runs the callback against the adopted
channel. An earlier revision of this patch did that, with the result that the
kernel session kept working while the daemon marked the profile disconnected. Without any abort, the
pending connect instead stays open until the kernel's L2CAP connect timeout
(`L2CAP_CONN_TIMEOUT`, 40 s), during which removing the device would leave
btio's callback with a freed `idev`.

### What the patch does not change

- It does not relax authentication or encryption: the kernel's link-mode check is
  untouched, and the controller still authenticates against the stored link key.
- It does not change the daemon's security policy. Built from Ubuntu's source,
  `ClassicBondedOnly` keeps its distribution default (`true`); the published
  run exercises that path (`encrypt_notify()` in `evidence/bluetoothd-debug.txt`).
- It does not alter the HID report paths, the input mapping, or the report
  descriptor handling.
- For devices without Sony's vendor ID, only the guard in
  `interrupt_connect_cb()` can apply: when a host connect completes after the
  device's own interrupt channel has already been dropped again, the callback
  closes it instead of calling upstream's failure path on a NULL channel.

### The cost: no rumble or lightbar over Bluetooth

The session's output reports (rumble, lightbar) travel on the adopted channel,
and the controller ignores them there. In a `SHARE+PS` session, where the host
opens the channel, rumble works (`evidence/output-tests.txt`). The kernel's
HIDP session uses one interrupt channel for both directions, so the patch
cannot read input from one channel and write output to the other.

---

## 2. Part 2 - the reconnect helper

File: `tools/ds4-reconnect.sh`. `install.sh` installs a root-owned copy as
`/usr/local/lib/ds4-clone-reconnect/ds4-reconnect.sh` and runs it as
`ds4-clone-reconnect.service`, logging to `/var/log/ds4-clone-reconnect/`.

Behaviour: poll the HCI connection list (10 x per second); when the
controller's ACL link appears and no joystick device with the controller's
address exists yet, run

```sh
busctl call org.bluez /org/bluez/hci0/dev_<MAC> \
       org.bluez.Device1 ConnectProfile s 00001124-0000-1000-8000-00805f9b34fb
```

and, if no input device for that address appears within ~2 s, fall back to
`bluetoothctl --timeout 6 connect <MAC>`.

`Device1.ConnectProfile(<HID UUID>)` goes straight into the input plugin's
connect path: `dev_connect()` opens PSM 17 with a security level of
`BT_IO_SEC_MEDIUM` (the device is bonded), then PSM 19, then `HIDPCONNADD`.
`Device1.Connect` - what `bluetoothctl connect` calls - connects all
auto-connect profiles of the device; the helper uses it only as a fallback.

The host's own PSM 17 request is held by the kernel until the link meets that
security level, so it always goes out on an encrypted link and is accepted -
3 ms after `Encryption Change` in `evidence/btmon-successful-connect.txt`.

The helper is a systemd service rather than a udev rule because the trigger is a
Bluetooth link event, not a device node appearance, and it must act before the
kernel drops the unused link (~4 s).

### Why not one of the simpler options

| Option | Problem |
|---|---|
| Disconnect + reconnect from the host | the controller gives up and powers off within a few seconds; the window is too short to win reliably |
| A kernel HIDP client (raw `BTPROTO_HIDP` socket) | HIDP sockets have no `connect()`; the kernel API is `HIDPCONNADD` via ioctl, which needs both L2CAP channels first - i.e. reimplementing the input plugin |
| Patching the kernel's link-mode check | would weaken Bluetooth security for every device on the host |
| Config-only changes | see `02-root-cause.md` §4 |

---

## 3. What the user experiences

Before: power on → link comes up, no input device → link drops after ~4 s →
controller powers off. Works only after `SHARE+PS`.

After: power on → `js0` appears ~0.6 s after the link → stays connected, input
works. The reconnect helper re-arms automatically after every power-off.

Measured in the functional test (see `evidence/reconnect-helper-log.txt`):

```
00:38:50.603 link up -> ConnectProfile 00001124-0000-1000-8000-00805f9b34fb
00:38:51.161 result: input=[/dev/input/js0 ]  links=1
```

Kernel side (`evidence/dmesg-registration.txt`):

```
input: Wireless Controller as /devices/.../hci0:1/0005:054C:09CC.0022/input/input...
playstation 0005:054C:09CC.0022: Registered DualShock4 controller hw_version=0x00006404 fw_version=0x00007009
```

Verified on the patched host: all 13 buttons, both sticks, both analog triggers
and the d-pad (evdev, `evidence/output-tests.txt`), and reconnection after a
power cycle (`evidence/bluetoothd-debug.txt`, part 4, and
`evidence/reconnect-helper-log.txt`). Not working over Bluetooth: rumble and
lightbar (see above). Which patch revision each of these ran with is listed in
`05-evidence.md`.

---

## 4. Maintenance notes

- **Distro upgrades replace the daemon.** Any `bluez` package update reinstalls
  the daemon and silently removes the patch. Re-run `install.sh` afterwards; it
  backs up the new stock daemon before replacing it.
- **Ordering assumption.** The patch handles the order seen in every capture:
  the controller's PSM 19 request arrives while the host's own PSM 19 connect is
  still pending. If the host's session were fully up first, the controller's
  channel is refused as upstream does, and the controller disconnects (failure
  mode B). If the controller's interrupt channel arrived while the host's
  control channel was still connecting, the unpatched code path applies:
  `input_device_set_channel()` would try to create the session at once
  (`ctrl_io` is already set) and `control_connect_cb()` would later overwrite
  `idev->intr_io`. In every capture the controller's request follows the
  completed PSM 17 connect.
- **A second controller of the same model:** run one helper per address.
  Install a second copy of the unit under another name, with that address
  substituted for `@CONTROLLER_MAC@` and the helper path for `@HELPER@`. The
  helper only counts joystick devices whose `uniq` matches its own address, so
  the instances do not interfere.
