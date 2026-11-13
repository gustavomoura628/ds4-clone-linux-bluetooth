#!/usr/bin/env python3
"""Read DS4 feature reports via the hidraw ioctl HIDIOCGFEATURE.

Only GET_REPORT requests are sent; the node is opened read-only.

Usage: ds4_features.py /dev/hidrawN
Licence: MIT (see LICENSE).
"""
import fcntl, os, sys
def HIDIOCGFEATURE(n): return (3 << 30) | (n << 16) | (ord('H') << 8) | 0x07
REPORTS = {0x02: (37, "calibration (USB)"), 0x05: (41, "calibration (BT-style)"),
           0x12: (16, "pairing info: dev MAC + host MAC"), 0x81: (7, "MAC (USB)"),
           0xa3: (49, "firmware info"), 0x06: (64, "?"), 0x08: (4, "?"), 0x10: (5, "?")}
if len(sys.argv) != 2:
    sys.exit(__doc__)
fd = os.open(sys.argv[1], os.O_RDONLY)
for rid, (ln, desc) in REPORTS.items():
    buf = bytearray(ln); buf[0] = rid
    try:
        r = fcntl.ioctl(fd, HIDIOCGFEATURE(ln), buf, True)
        print(f"0x{rid:02x} [{desc}] ret={r}: {buf[:r].hex(' ')}")
    except OSError as e:
        print(f"0x{rid:02x} [{desc}] ERROR {e}")
