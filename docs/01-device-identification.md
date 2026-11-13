# 01 - What the controller is

The controller reports itself as a Sony DualShock 4 v2 (`054c:09cc`) over USB and
Bluetooth, and can switch to a Sixaxis personality (`054c:0268`) at runtime. It
is not a Sony device. This document records what was measured, how, and what
each observation implies - because the identification explains both the
misclassification by existing tools and the Bluetooth failure analysed in
`02-root-cause.md`.

All observations below are reproducible with the tools in `tools/` and the raw
captures in `evidence/`.

## 1. Enumerated identities

| Mode | VID:PID | Interfaces | HID report descriptor | Notes |
|---|---|---|---|---|
| DS4 | `054c:09cc` | 4: audio control, audio out, audio in, HID | 507 bytes | same length as a genuine CUH-ZCT2 descriptor; declares the DS4 report set (48 feature reports) |
| PS3 | `054c:0268` | 1: HID | 137 bytes | a generic gamepad descriptor (usage Game Pad, no report IDs, a vendor 0x2621 feature/output report) - not the genuine Sixaxis descriptor, which is a 148-byte joystick collection with report IDs |

- USB device descriptor: full speed, `bcdUSB 1.10`, `bcdDevice 0100`,
  `bmAttributes 0xc0` (self-powered, no remote wakeup) while the device reports
  "Bus Powered".
- The mode switch happens at runtime and is **not sticky**: a power cycle always
  returns to the DS4 identity.
- Both descriptor trees: `evidence/lsusb-ds4-mode.txt`,
  `evidence/lsusb-ps3-mode.txt`; HID report descriptors (read from sysfs
  `report_descriptor`, since lsusb cannot read them while a driver is bound):
  `evidence/hid-report-descriptor-ds4.txt`,
  `evidence/hid-report-descriptor-ps3.txt`.

Broadcasting both identities is normal for multi-mode clone silicon and is not
itself a defect; it is the reason the device appears as a PS3 controller on some
hosts.

## 2. What is genuinely emulated, and what is not

| Property | Measured | Implication |
|---|---|---|
| Motion sensors | always zero in the input report (raw bytes) | **no IMU**; the device still serves a plausible, non-zero calibration block (report `0x02`), i.e. calibration data is copied, not measured |
| USB report rate | about 100 Hz, read off `tools/ds4view.py`'s live counter (no capture included; genuine DS4 ~250 Hz) | slower polling loop, harmless for input |
| Bluetooth input reports | every report sent twice (identical payload, including the sequence counter); the host receives the copies 0-6 ms apart; ~60 unique reports/s (`evidence/btmon-successful-connect.txt`) | firmware retransmission bug; harmless |
| Feature reports (DS4 mode) | declares 48; 6 answer at their declared size (`0x02`, `0x12`, `0x81`, `0xA3`, `0xF1`, `0xF2`), everything else stalls (`evidence/feature-sweep-ds4-usb.txt`) | copied descriptor table, partial implementation |
| `0x81` ("get MAC") | constant `c0 61 f2 e2 1f 00`, unrelated to the device MAC | stubbed implementation |

The "Motion Sensors" evdev node that the Linux driver creates is therefore
functional but always reports zero - worth knowing before blaming a game for
ignoring motion input.

## 3. Firmware identity block (`0xA3`)

Report `0xA3` returns 49 bytes (including the report id). Decoded with the layout
used by public DualShock 4 tooling (`jedi_tool.py`, see `NOTICE`) - `compile_date[16]`, `compile_time[16]`,
`hw_major u16le`, `hw_minor u16le`, `sw_major u32le`, `sw_minor u16le`,
`sw_series u16le`, `code_size u32le` - and cross-checked against the Linux
driver, which reads `hw_version = u16le(buf[35])` and
`fw_version = u16le(buf[41])`:

| field | USB | Bluetooth |
|---|---|---|
| compile date/time | `May 17 2016 06:36:26` | `Jul 11 2016 12:33:38` |
| hw | `0x0100` / `0x6404` | `0x0100` / `0x6404` |
| sw | `1.7008` | `1.7009` |
| series | `0x0200` | `0x0200` |
| last 4 bytes | code size `0x00038000` | CRC32 `0x2b62450c` |

Two observations matter:

1. **The identity is copied from genuine hardware, not invented.**
   `0x6404` is the board code of a genuine JDM-040 (DualShock 4 v2) and `1.70xx`
   is the matching firmware generation; the series value `0x0200` matches as
   well. The controller claims to be a launch-era DS4 v2, which is exactly what a
   clone of `054c:09cc` should claim. Consequence: this stamp does **not**
   identify the clone vendor, and it collides with real 2016 controllers.
2. **The same controller reports two different firmware identities depending on
   the transport.** A genuine controller has one firmware and answers
   identically over USB and Bluetooth. Here the two code paths (USB HID class and
   Bluetooth HIDP) carry separately copied constants - evidence of two
   implementations in one firmware, and the most distinctive fingerprint found
   on this device.

The Bluetooth variant's last four bytes are a standard Sony-style feature-report
CRC (seed `0xA3`); it was verified against the captured bytes
(`crc32(b"\xa3" + report[0:45])`, where `report[0]` is the report id, equals the
stored value). Raw bytes and the
verification: `evidence/feature-report-0xa3-usb-vs-bt.txt`,
`evidence/feature-reports-usb.txt`.

## 4. Pairing block (`0x12`) and OUI checks

`0x12` returns the device address, the device's Class of Device (`0x002508`,
gamepad - the same value it reports over Bluetooth), and the last host address -
the same layout as genuine hardware:

```
12  d1 32 ca f7 9d ed  08 25 00  66 55 44 33 22 11
    <device MAC, LE>   <CoD, LE> <last host MAC, LE>
```

(The host address is redacted to `11:22:33:44:55:66` here and in `evidence/`.)

The device address (`ed:9d:f7:ca:32:d1`) is **not vendor-assigned**: its first
octet has the multicast bit set, so no OUI database can resolve it and no unicast
allocation can exist. It is most likely generated by the firmware rather than
programmed by a module vendor. OUI lookups are therefore a dead end for this
device class.

## 5. Bluetooth baseband

The LMP layer identifies the radio silicon, independent of the USB descriptors:

```
$ hcitool info ED:9D:F7:CA:32:D1
	LMP Version: 5.1 (0xa)  LMP Subversion: 0x22bb
	Manufacturer: Zhuhai Jieli technology Co.,Ltd (1494)
```

The host adapter in the same session reports Realtek (93), so the value belongs
to the controller. JieLi (杰理) is a Chinese SoC vendor whose parts are common in
low-cost wireless peripherals. Which JieLi family it belongs to is not
determined here; LMP 5.1 only rules out JieLi parts that predate Bluetooth 5.1.

This explains the behavioural cluster in one step: the DS4 and Sixaxis
personalities are **application code written against a vendor SDK**, which is why
the identity blocks are tables of copied constants (two of them, one per
transport), why there is no IMU, why the report rate is low, why `0x81` is a
stub, and why the pairing behaviour in `02-root-cause.md` is not what a Sony
device would do.

The exact part number is printed on the package under the vendor logo and cannot
be determined from the USB or Bluetooth metadata. Reading it requires opening the
enclosure, which was out of scope.

Capture: `evidence/bluetooth-baseband.txt`.

## 6. Markings

The label reads `MODEL CUH-ZCT2E` (the European DS4 v2 model), the correct
printed rating (`DC 5V 800mA`), Sony Interactive Entertainment, EAC/CE/WEEE marks
and a barcode serial. The serial is not unique to the unit: the same string
appears on unrelated units offered in different countries, which indicates
duplicated label artwork rather than a per-unit serial. This is consistent with
everything else above - the enclosure, descriptors, label and firmware identity
are all faithful copies.

(No photograph is included in this repository.)

## 7. What this means for tooling

- Websites and applications that decide "genuine or clone" from `0xA3` alone
  will misclassify this device, because the block carries genuine values.
- Applications that use a **timeout on `0x81`** as their clone test will also
  misclassify it, because this firmware answers `0x81` (with a constant).
- The reliable tells for this family are behavioural: transport-dependent
  identity blocks, absent IMU with present calibration data, duplicate Bluetooth
  reports, a low report rate, and LMP manufacturer 1494.
