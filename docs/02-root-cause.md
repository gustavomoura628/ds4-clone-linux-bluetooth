# 02 - Root cause

The controller fails on Linux in two distinct ways depending on who opens the
HIDP channels first. Both are visible in the trace in `evidence/`, and both are
explained by one property of this firmware: it opens the HIDP control channel
while its own link is still being configured, and it treats any refusal as a
fatal connection error.

## 1. Background: who opens HIDP, and why it matters

A classic Bluetooth HID device exposes two L2CAP PSMs: `17` (control) and `19`
(interrupt). Either side can open them. After pairing, the **host** connects to
them (host-initiated). When a bonded device reconnects - pressing PS on a
switched-off controller - the device pages the host and normally opens PSM 17
and 19 itself once the link is encrypted (device-initiated).

The Linux HID stack (BlueZ's `input` plugin plus the kernel `hidp` module)
supports both directions:

- **host-initiated**: `btd_profile` connect → L2CAP PSM 17 → PSM 19 →
  `HIDPCONNADD` → `/dev/input/event*`;
- **device-initiated**: the device connects to the host's HIDP listener, which
  BlueZ accepts for known HID devices.

For an *inbound* ACL connection BlueZ does not start the host-initiated path by
itself. It expects the device to open the channels; if none gets established,
the kernel drops the unused link after a few seconds.

This firmware does open the channels itself, as a reconnecting device should,
but it requests PSM 17 before the link is encrypted. The kernel refuses that
request, the firmware never repeats it, and the host-initiated path - the one
that would work - never starts on its own.

## 2. Failure mode A: device-initiated request arrives too early

`evidence/btmon-failed-connect.txt`, power-on with Ubuntu's unmodified
`bluez 5.64-0ubuntu1.6` daemon:

| time from Connect Complete | event |
|---|---|
| +126 ms | controller requests authentication (`Link Key Request`) |
| +133 ms | host's `Link Key Request Reply` with the stored key completes |
| +208 ms | controller sends `L2CAP Connection Request` for PSM 17 |
| +208 ms | host replies `Connection refused - security block (0x0003)` |
| +264 ms | `Encryption Change: Enabled with E0` |
| +4.07 s | host sends HCI `Disconnect`, reason `0x05` (Authentication Failure) |

Why the host refuses - kernel `net/bluetooth/l2cap_core.c`, incoming connection
handler:

```c
	/* Check if the ACL is secure enough (if not SDP) */
	if (psm != cpu_to_le16(L2CAP_PSM_SDP) &&
	    !hci_conn_check_link_mode(conn->hcon)) {
		conn->disc_reason = HCI_ERROR_AUTH_FAILURE;
		result = L2CAP_CR_SEC_BLOCK;
		goto response;
	}
```

`hci_conn_check_link_mode()` (`net/bluetooth/hci_conn.c`) requires the link to
be **encrypted** whenever both sides use Secure Simple Pairing, which this
controller does (see the feature list in the trace). At +208 ms the stored key
has been supplied (+133 ms) but encryption has not completed (+264 ms). The kernel is behaving
correctly - the request genuinely arrives on an unencrypted link.

Two things then turn a survivable race into a dead connection:

1. **The controller never retries PSM 17.** It sends the request once. There is
   no back-off and no second attempt on the same link.
2. **Nobody opens HIDP.** BlueZ does not start the host-initiated path for an
   inbound connection, so the link carries no L2CAP channel. About 4 s after
   setup the kernel disconnects the unused link. The reason code `0x05`
   (Authentication Failure) is the `disc_reason` the kernel recorded when it
   refused PSM 17 (the excerpt above), not an actual authentication failure -
   the link key works, as the trace shows. bluetoothd issues no disconnect of
   its own (`evidence/bluetoothd-debug.txt`, part 1). The controller treats
   the drop as a rejected connection and powers off.

Note on timing: this is deterministic, not flaky. In all three published
captures the PSM 17 request arrived 54.6-56.3 ms before encryption completed,
although its offset from link setup varied (+208, +164, +163 ms). When the host starts
encryption earlier - as `ConnectProfile` does in
`evidence/btmon-duplicate-channel-refused.txt` - the controller's request moves
earlier with it, so the race cannot be won from the host side.

### Why "pairing mode" always worked

Holding `SHARE+PS` puts the controller into pairing mode. In that state the host
performs a fresh pairing *and an outgoing connection*, i.e. the host-initiated
path. The controller makes no attempt of its own, so the race never happens.
That is the entire reason for the "it only works when I hold SHARE+PS" symptom.
It is also the likely reason the controller is reported to work on other hosts
whose HID stack opens the device's PSMs itself; that was not tested here.

## 3. Failure mode B: the controller's own interrupt channel is refused

If the host does start the good path (by activating the HID profile while the
link is up, as the helper in `03-the-fix.md` does), the controller still opens
its own interrupt channel a moment later. Observed with the unmodified daemon
(`evidence/btmon-duplicate-channel-refused.txt`, `evidence/bluetoothd-debug.txt`
part 2):

```
profiles/input/server.c:connect_event_cb() Incoming connection from ED:9D:F7:CA:32:D1 on PSM 19
profiles/input/device.c:input_device_set_channel() idev 0x56cc93939180 psm 19
profiles/input/server.c:connect_event_cb() Refusing input device connect: Operation already in progress (114)
```

`114` is `-EALREADY`: `input_device_set_channel()` refuses a second channel for a
PSM the session already holds:

```c
	case L2CAP_PSM_HIDP_INTR:
		if (idev->intr_io)
			return -EALREADY;
```

`connect_event_cb()` treats **any** non-zero return as fatal and closes the
channel:

```c
	ret = input_device_set_channel(&src, &dst, psm, chan);
	if (ret == 0)
		return;
	...
	error("Refusing input device connect: %s (%d)", strerror(-ret), -ret);
	g_io_channel_shutdown(chan, TRUE, NULL);
```

The trace shows why that is fatal: the controller sends its input reports only
on the interrupt channel it opened itself (host CID `0x0041`), never on the one
the host opened. The first reports arrive 3 ms after the daemon has already
asked to close that channel; about 200 ms later the controller terminates the
link (`0x13`, Remote User Terminated Connection). Neither path works on its
own: the controller's control-channel request always comes too early, and it
does not accept a session without its own interrupt channel. The working
combination is the host's control channel plus the controller's interrupt
channel, which needs the daemon to keep the controller's channel.

Full daemon output: `evidence/bluetoothd-debug.txt`.

## 4. Why existing clone workarounds do not apply

Each row follows from the traces and the source cited above; the configuration
changes were also tried during the investigation, but those logs are not
included.

| Workaround | Why it does not help here |
|---|---|
| `ClassicBondedOnly=false` | lowers the daemon's listener security requirement, but the refusal in failure mode A comes from the kernel's link-mode check, not from the listener |
| `JustWorksRepairing=always` | assumes the stored link key is unusable; here authentication succeeds (see trace), so there is nothing to repair |
| Removing the stored link key / re-pairing | buys one working session (pairing mode) and then reproduces the same race |
| PS4-style pairing over USB (`SET_FEATURE 0x13`: host address + link key) | only changes the stored pairing data; it does not change who opens the HIDP channels, so the race remains |
| `userspace HID` (`UserspaceHID=true`) | changes how the HID device is created, not the channel ownership problem |
| Driver-side tolerance for failed feature-report reads | helps controllers whose *feature report* reads fail while the driver probes them; this failure happens before any HID channel exists |

## 5. Scope of the bug

Everything on the controller side is firmware behaviour: the PSM 17 request
~55 ms before encryption, the single attempt, sending input only on its own
interrupt channel, and the power-off on disconnect. None of that can be changed from the host. What *can* be changed is
how the host responds:

- start the working (host-initiated) path as soon as the link appears, and
- tolerate the controller's duplicate channel instead of closing it.

That is exactly what `03-the-fix.md` does.
