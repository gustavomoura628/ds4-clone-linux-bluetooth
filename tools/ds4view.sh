#!/bin/bash
# Launch the DS4 debug viewer (tools/ds4view.py).
# Extra args are passed through, e.g.:  ./ds4view.sh --match "Wireless Controller"
# Dependencies (pygame-ce, evdev) are declared inline in ds4view.py and fetched by uv.
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
export DISPLAY="${DISPLAY:-:0}"
if [ ! -f /etc/udev/rules.d/70-ds4-debug.rules ]; then
  echo "note: udev rule not installed; motion/touchpad nodes may be unreadable."
  echo "      install: sudo cp $DIR/70-ds4-debug.rules /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger"
fi
exec uv run "$DIR/ds4view.py" "$@"
