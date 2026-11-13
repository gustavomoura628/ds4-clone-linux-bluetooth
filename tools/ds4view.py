#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["pygame-ce>=2.4", "evdev>=1.7"]
# ///
"""ds4view - live debug viewer for DualShock 4 controllers (and clones) via Linux evdev.

Shows buttons, sticks, triggers, d-pad, touchpad, motion sensors, report rates, battery,
and a timestamped connect/disconnect log (with how long each connection lasted).
Everything in the logs is also written to logs/ds4view-<timestamp>.log.

Keys:  1 weak rumble   2 strong rumble   r/g/b/w/0 lightbar colour
       Tab next controller   c clear logs   q / Esc quit

Run:   uv run tools/ds4view.py            (needs read access to /dev/input/event*;
                                            see tools/70-ds4-debug.rules)
"""
import argparse
import collections
import datetime
import glob
import os
import select
import time

import evdev
from evdev import ecodes as E
import pygame

# ---------------------------------------------------------------- colours
BG = (22, 24, 28)
BODY = (48, 52, 60)
IDLE = (78, 84, 96)
ON = (255, 190, 40)
TXT = (225, 225, 225)
DIM = (130, 135, 145)
GOOD = (90, 210, 120)
BAD = (240, 90, 90)
WHITE = (255, 255, 255)

DS4_NAMES = {
    E.BTN_SOUTH: "Cross", E.BTN_EAST: "Circle", E.BTN_NORTH: "Triangle", E.BTN_WEST: "Square",
    E.BTN_TL: "L1", E.BTN_TR: "R1", E.BTN_TL2: "L2", E.BTN_TR2: "R2",
    E.BTN_SELECT: "Share", E.BTN_START: "Options", E.BTN_MODE: "PS",
    E.BTN_THUMBL: "L3", E.BTN_THUMBR: "R3",
}
TOUCH_NOISE = {E.BTN_TOUCH, E.BTN_TOOL_FINGER, E.BTN_TOOL_DOUBLETAP, E.BTN_TOOL_TRIPLETAP,
               E.BTN_TOOL_QUADTAP}
BUS = {E.BUS_USB: "USB", E.BUS_BLUETOOTH: "Bluetooth"}


def code_name(table, code):
    n = table.get(code, str(code))
    return n[-1] if isinstance(n, (list, tuple)) else n


def role_of(name):
    n = name.lower()
    if n.endswith("motion sensors"):
        return "motion"
    if n.endswith("touchpad"):
        return "touchpad"
    return "main"


def sysfs_name(path):
    try:
        with open(f"/sys/class/input/{os.path.basename(path)}/device/name") as f:
            return f.read().strip()
    except OSError:
        return ""


def is_gamepad(d):
    keys = d.capabilities().get(E.EV_KEY, [])
    return E.BTN_SOUTH in keys or E.BTN_TRIGGER in keys


# ---------------------------------------------------------------- model
class Ctl:
    """One physical controller = up to 3 evdev nodes (main/motion/touchpad) sharing a uniq."""

    def __init__(self, key):
        self.key = key
        self.devs = {}
        self.keys = set()
        self.abs = {}
        self.absinfo = {}
        self.slots = {}
        self.cur_slot = 0
        self.reports = collections.defaultdict(lambda: collections.deque(maxlen=3000))
        self.name = ""
        self.bus = None
        self.uniq = ""
        self.connected_at = time.time()
        self.connected = True
        self.ff_id = None
        self.connections = 0

    def rate(self, role):
        q = self.reports[role]
        now = time.monotonic()
        while q and now - q[0] > 1.0:
            q.popleft()
        return len(q)

    def axis(self, role, code, centered=True):
        ai = self.absinfo.get((role, code))
        v = self.abs.get((role, code))
        if ai is None or v is None or ai.max == ai.min:
            return 0.0
        f = (v - ai.min) / (ai.max - ai.min)
        return f * 2 - 1 if centered else f


class App:
    def __init__(self, args):
        self.args = args
        self.ctls = {}
        self.order = []
        self.sel = 0
        self.denied = {}
        self.events = collections.deque(maxlen=16)
        self.conns = collections.deque(maxlen=16)
        os.makedirs(args.logdir, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.logpath = os.path.join(args.logdir, f"ds4view-{stamp}.log")
        self.logf = open(self.logpath, "a", buffering=1)
        self.last_scan = 0.0

    # ------------------------------------------------------------ logging
    def log(self, text, conn=False):
        ts = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
        (self.conns if conn else self.events).appendleft((ts, text))
        self.logf.write(f"{ts} {'CONN ' if conn else ''}{text}\n")

    # ------------------------------------------------------------ hotplug
    def open_paths(self):
        return {d.path for c in self.ctls.values() for d in c.devs.values()}

    def scan(self):
        opened = self.open_paths()
        cands = []
        for path in sorted(glob.glob("/dev/input/event*")):
            if path in opened:
                continue
            try:
                d = evdev.InputDevice(path)
            except PermissionError:
                n = sysfs_name(path)
                if path not in self.denied and ("controller" in n.lower() or "sony" in n.lower()):
                    self.denied[path] = n
                    self.log(f"NO PERMISSION to read {path} ({n})", conn=True)
                continue
            except OSError:
                continue
            cands.append(d)
        pad_uniqs = {c.uniq for c in self.ctls.values() if c.uniq}
        pad_uniqs |= {d.uniq for d in cands if d.uniq and (is_gamepad(d) or d.info.vendor == 0x054C)}
        for d in cands:
            want = (d.info.vendor == 0x054C or is_gamepad(d) or (d.uniq and d.uniq in pad_uniqs))
            if self.args.match:
                want = self.args.match.lower() in d.name.lower()
            if want:
                self.attach(d)
            else:
                d.close()
        for p in list(self.denied):
            if not os.path.exists(p):
                del self.denied[p]

    def attach(self, d):
        key = d.uniq or d.phys.rsplit("/", 1)[0] or d.path
        role = role_of(d.name)
        c = self.ctls.get(key)
        if c is None:
            c = self.ctls[key] = Ctl(key)
            self.order.append(key)
        if not c.devs:
            c.connected, c.connected_at = True, time.time()
            c.connections += 1
            c.keys.clear()
            c.slots.clear()
            c.ff_id = None
            self.sel = self.order.index(key)
        c.devs[role] = d
        if role == "main" or not c.name:
            c.name, c.bus, c.uniq = d.name, d.info.bustype, d.uniq
        caps = d.capabilities()
        for code, ai in caps.get(E.EV_ABS, []):
            c.absinfo[(role, code)] = ai
            c.abs[(role, code)] = ai.value
        try:
            c.keys |= set(d.active_keys())
        except OSError:
            pass
        bus = BUS.get(d.info.bustype, hex(d.info.bustype))
        self.log(f"+ {role:8s} {d.path} [{bus}] {d.name} uniq={d.uniq or '-'} "
                 f"vid:pid={d.info.vendor:04x}:{d.info.product:04x}"
                 + (f"  (connection #{c.connections})" if role == "main" else ""), conn=True)

    def detach(self, c, role, d, err):
        self.log(f"- {role:8s} {d.path} gone ({err.__class__.__name__}: {err.strerror or err})", conn=True)
        try:
            d.close()
        except OSError:
            pass
        c.devs.pop(role, None)
        if not c.devs:
            c.connected = False
            c.keys.clear()
            c.slots.clear()
            self.log(f"DISCONNECTED {c.name} after {time.time() - c.connected_at:.2f}s", conn=True)

    # ------------------------------------------------------------ input
    def pump(self):
        fdmap = {d.fd: (c, role, d) for c in self.ctls.values() for role, d in list(c.devs.items())}
        if not fdmap:
            return
        try:
            ready, _, _ = select.select(list(fdmap), [], [], 0)
        except (OSError, ValueError):
            ready = list(fdmap)
        for fd in ready:
            c, role, d = fdmap[fd]
            try:
                for ev in d.read():
                    self.handle(c, role, ev)
            except BlockingIOError:
                pass
            except OSError as e:
                self.detach(c, role, d, e)

    def handle(self, c, role, ev):
        if ev.type == E.EV_KEY:
            if ev.value:
                c.keys.add(ev.code)
            else:
                c.keys.discard(ev.code)
            if ev.code in TOUCH_NOISE:
                return
            name = "Pad click" if role == "touchpad" and ev.code == E.BTN_LEFT else \
                DS4_NAMES.get(ev.code, code_name(E.BTN, ev.code) if ev.code >= 0x100 else code_name(E.KEY, ev.code))
            state = {0: "up", 1: "DOWN", 2: "repeat"}.get(ev.value, ev.value)
            self.log(f"{name:10s} {state}")
        elif ev.type == E.EV_ABS:
            if role == "touchpad":
                if ev.code == E.ABS_MT_SLOT:
                    c.cur_slot = ev.value
                elif ev.code == E.ABS_MT_TRACKING_ID:
                    if ev.value == -1:
                        c.slots.pop(c.cur_slot, None)
                    else:
                        c.slots[c.cur_slot] = {"id": ev.value, "x": None, "y": None}
                elif ev.code == E.ABS_MT_POSITION_X:
                    c.slots.setdefault(c.cur_slot, {"id": -2, "x": None, "y": None})["x"] = ev.value
                elif ev.code == E.ABS_MT_POSITION_Y:
                    c.slots.setdefault(c.cur_slot, {"id": -2, "x": None, "y": None})["y"] = ev.value
            prev = c.abs.get((role, ev.code))
            c.abs[(role, ev.code)] = ev.value
            if role == "main" and ev.code in (E.ABS_HAT0X, E.ABS_HAT0Y) and prev != ev.value:
                self.log(f"D-pad {'X' if ev.code == E.ABS_HAT0X else 'Y'} = {ev.value:+d}")
        elif ev.type == E.EV_SYN and ev.code == E.SYN_REPORT:
            c.reports[role].append(time.monotonic())

    # ------------------------------------------------------------ outputs
    def rumble(self, c, strong, weak, ms=600):
        d = c.devs.get("main")
        if not d or E.EV_FF not in d.capabilities():
            self.log("rumble: no force-feedback device")
            return
        eff = evdev.ff.Effect(E.FF_RUMBLE, -1, 0, evdev.ff.Trigger(0, 0), evdev.ff.Replay(ms, 0),
                              evdev.ff.EffectType(ff_rumble_effect=evdev.ff.Rumble(
                                  strong_magnitude=strong, weak_magnitude=weak)))
        try:
            if c.ff_id is not None:
                try:
                    d.erase_effect(c.ff_id)
                except OSError:
                    pass
            c.ff_id = d.upload_effect(eff)
            d.write(E.EV_FF, c.ff_id, 1)
            self.log(f"rumble sent strong={strong:#06x} weak={weak:#06x}")
        except OSError as e:
            self.log(f"rumble FAILED: {e}")

    def lightbar(self, c, rgb):
        d = c.devs.get("main")
        if not d:
            return
        inp = os.path.basename(os.path.realpath(f"/sys/class/input/{os.path.basename(d.path)}/device"))
        try:
            for ch, v in zip(("red", "green", "blue"), rgb):
                with open(f"/sys/class/leds/{inp}:{ch}/brightness", "w") as f:
                    f.write(str(v))
            self.log(f"lightbar -> {rgb}")
        except OSError as e:
            self.log(f"lightbar FAILED: {e}")

    # ------------------------------------------------------------ drawing
    def text(self, s, pos, col=TXT, font=None, center=False):
        img = (font or self.font).render(str(s), True, col)
        r = img.get_rect(center=pos) if center else img.get_rect(topleft=pos)
        self.screen.blit(img, r)

    def button(self, rect, pressed, label):
        pygame.draw.rect(self.screen, ON if pressed else IDLE, rect, border_radius=8)
        self.text(label, rect.center, BG if pressed else TXT, center=True)

    def draw_controller(self, c, ox, oy):
        s = self.screen
        on = lambda k: k in c.keys
        pygame.draw.rect(s, BODY, (ox + 60, oy + 85, 640, 310), border_radius=70)

        # analog triggers
        for btn, ax, x, lab in ((E.BTN_TL2, E.ABS_Z, 120, "L2"), (E.BTN_TR2, E.ABS_RZ, 560, "R2")):
            r = pygame.Rect(ox + x, oy + 5, 80, 36)
            pygame.draw.rect(s, IDLE, r, border_radius=8)
            frac = c.axis("main", ax, centered=False)
            if frac > 0:
                pygame.draw.rect(s, ON, (r.x, r.y, max(4, int(r.w * frac)), r.h), border_radius=8)
            if on(btn):
                pygame.draw.rect(s, WHITE, r, 3, border_radius=8)
            self.text(f"{lab} {c.abs.get(('main', ax), '-')}", r.center, TXT, center=True)
        self.button(pygame.Rect(ox + 120, oy + 50, 80, 26), on(E.BTN_TL), "L1")
        self.button(pygame.Rect(ox + 560, oy + 50, 80, 26), on(E.BTN_TR), "R1")
        self.button(pygame.Rect(ox + 215, oy + 105, 50, 30), on(E.BTN_SELECT), "Share")
        self.button(pygame.Rect(ox + 495, oy + 105, 60, 30), on(E.BTN_START), "Opt")

        # touchpad
        tp = pygame.Rect(ox + 275, oy + 95, 210, 115)
        pygame.draw.rect(s, (110, 100, 60) if on(E.BTN_LEFT) else IDLE, tp, border_radius=10)
        if on(E.BTN_LEFT):
            pygame.draw.rect(s, ON, tp, 3, border_radius=10)
        aix = c.absinfo.get(("touchpad", E.ABS_MT_POSITION_X))
        aiy = c.absinfo.get(("touchpad", E.ABS_MT_POSITION_Y))
        for slot, t in c.slots.items():
            if t["x"] is None or t["y"] is None or not aix or not aiy:
                continue
            px = tp.x + (t["x"] - aix.min) / max(1, aix.max - aix.min) * tp.w
            py = tp.y + (t["y"] - aiy.min) / max(1, aiy.max - aiy.min) * tp.h
            pygame.draw.circle(s, ON, (int(px), int(py)), 9)
            self.text(f"{slot}:{t['x']},{t['y']}", (tp.x + 4, tp.bottom + 2 + 15 * slot), DIM, self.small)
        if not c.slots:
            self.text("touchpad", tp.center, DIM, self.small, center=True)

        # d-pad
        cx, cy = ox + 165, oy + 195
        hx, hy = c.abs.get(("main", E.ABS_HAT0X), 0), c.abs.get(("main", E.ABS_HAT0Y), 0)
        for dx, dy, pressed in ((0, -1, hy < 0), (0, 1, hy > 0), (-1, 0, hx < 0), (1, 0, hx > 0)):
            pygame.draw.rect(s, ON if pressed else IDLE, (cx + dx * 36 - 17, cy + dy * 36 - 17, 34, 34),
                             border_radius=6)
        pygame.draw.rect(s, IDLE, (cx - 17, cy - 17, 34, 34))

        # face buttons
        fx, fy = ox + 595, oy + 195
        for code, dx, dy, shape in ((E.BTN_NORTH, 0, -42, "tri"), (E.BTN_EAST, 42, 0, "cir"),
                                    (E.BTN_SOUTH, 0, 42, "x"), (E.BTN_WEST, -42, 0, "sq")):
            p = (fx + dx, fy + dy)
            pressed = on(code)
            pygame.draw.circle(s, ON if pressed else IDLE, p, 20)
            sc = BG if pressed else {"tri": (80, 220, 170), "cir": (240, 100, 110),
                                     "x": (130, 160, 255), "sq": (230, 130, 220)}[shape]
            if shape == "tri":
                pygame.draw.polygon(s, sc, [(p[0], p[1] - 10), (p[0] - 10, p[1] + 7), (p[0] + 10, p[1] + 7)], 2)
            elif shape == "cir":
                pygame.draw.circle(s, sc, p, 10, 2)
            elif shape == "x":
                pygame.draw.line(s, sc, (p[0] - 8, p[1] - 8), (p[0] + 8, p[1] + 8), 3)
                pygame.draw.line(s, sc, (p[0] - 8, p[1] + 8), (p[0] + 8, p[1] - 8), 3)
            else:
                pygame.draw.rect(s, sc, (p[0] - 8, p[1] - 8, 16, 16), 2)

        # PS button
        pygame.draw.circle(s, ON if on(E.BTN_MODE) else IDLE, (ox + 380, oy + 255), 17)
        self.text("PS", (ox + 380, oy + 255), BG if on(E.BTN_MODE) else TXT, self.small, center=True)

        # sticks
        for axx, axy, click, sx, lab in ((E.ABS_X, E.ABS_Y, E.BTN_THUMBL, 285, "L"),
                                         (E.ABS_RX, E.ABS_RY, E.BTN_THUMBR, 475, "R")):
            ccx, ccy, R = ox + sx, oy + 315, 50
            pygame.draw.circle(s, (60, 64, 74), (ccx, ccy), R)
            pygame.draw.circle(s, ON if on(click) else IDLE, (ccx, ccy), R, 3)
            pygame.draw.line(s, IDLE, (ccx - R, ccy), (ccx + R, ccy))
            pygame.draw.line(s, IDLE, (ccx, ccy - R), (ccx, ccy + R))
            nx, ny = c.axis("main", axx), c.axis("main", axy)
            pygame.draw.circle(s, ON, (int(ccx + nx * R), int(ccy + ny * R)), 11 if on(click) else 8)
            self.text(f"{lab}: {c.abs.get(('main', axx), '-')},{c.abs.get(('main', axy), '-')}",
                      (ccx, ccy + R + 14), DIM, self.small, center=True)

    def draw_panel(self, c, x, y):
        s = self.screen
        status = ("CONNECTED", GOOD) if c.connected else ("DISCONNECTED", BAD)
        self.text(status[0], (x, y), status[1], self.big)
        up = time.time() - c.connected_at
        self.text(f"for {up:.1f}s  (connection #{c.connections})" if c.connected else "", (x + 200, y + 6), DIM)
        y += 34
        lines = [
            (c.name, TXT),
            (f"bus: {BUS.get(c.bus, c.bus)}   uniq/MAC: {c.uniq or '-'}", TXT),
        ]
        for role in ("main", "touchpad", "motion"):
            d = c.devs.get(role)
            lines.append((f"{role:8s} {d.path if d else '(absent)':18s} {c.rate(role):4d} reports/s",
                          TXT if d else DIM))
        bat = self.battery(c)
        if bat:
            lines.append((f"battery: {bat}", TXT))
        extra = sorted(k for k in c.keys if k not in DS4_NAMES and k not in TOUCH_NOISE and k != E.BTN_LEFT)
        if extra:
            lines.append(("other keys held: " + ", ".join(code_name(E.BTN, k) for k in extra), ON))
        for t, col in lines:
            self.text(t, (x, y), col)
            y += 20

        y += 8
        self.text("motion sensors", (x, y), DIM)
        y += 20
        for code, lab in ((E.ABS_X, "acc X"), (E.ABS_Y, "acc Y"), (E.ABS_Z, "acc Z"),
                          (E.ABS_RX, "gyr X"), (E.ABS_RY, "gyr Y"), (E.ABS_RZ, "gyr Z")):
            v = c.abs.get(("motion", code))
            ai = c.absinfo.get(("motion", code))
            self.text(f"{lab} {v if v is not None else '-':>7}", (x, y), TXT, self.small)
            bar = pygame.Rect(x + 120, y + 2, 300, 12)
            pygame.draw.rect(s, IDLE, bar)
            if v is not None and ai and ai.max > ai.min:
                f = max(-1.0, min(1.0, v / max(abs(ai.max), abs(ai.min)) * (1 if lab.startswith("gyr") else 4)))
                mid = bar.centerx
                w = int(f * bar.w / 2)
                pygame.draw.rect(s, ON, (min(mid, mid + w), bar.y, abs(w) or 1, bar.h))
            pygame.draw.line(s, TXT, (bar.centerx, bar.y - 2), (bar.centerx, bar.bottom + 2))
            y += 18

    def battery(self, c):
        if not c.uniq:
            return ""
        for p in glob.glob(f"/sys/class/power_supply/*{c.uniq}*"):
            try:
                cap = open(os.path.join(p, "capacity")).read().strip()
                st = open(os.path.join(p, "status")).read().strip()
                return f"{cap}% {st}"
            except OSError:
                pass
        return ""

    def draw_logs(self, x, y):
        w = (self.W - 40) // 2
        self.text("button events", (x, y), DIM)
        self.text("connections  (+ node appeared / - node gone)", (x + w + 20, y), DIM)
        for i, (ts, t) in enumerate(self.events):
            self.text(f"{ts} {t}", (x, y + 22 + i * 16), TXT, self.small)
        for i, (ts, t) in enumerate(self.conns):
            col = BAD if ("DISCONN" in t or "NO PERM" in t or t.startswith("-")) else GOOD if t.startswith("+") else TXT
            self.text(f"{ts} {t}"[:118], (x + w + 20, y + 22 + i * 16), col, self.small)

    def draw(self):
        s = self.screen
        s.fill(BG)
        c = self.ctls[self.order[self.sel]] if self.order else None
        if c:
            self.draw_controller(c, 10, 20)
            self.draw_panel(c, 790, 20)
        else:
            self.text("Waiting for a controller...  (plug in USB or pair over Bluetooth)",
                      (40, 180), DIM, self.big)
            for i, (p, n) in enumerate(self.denied.items()):
                self.text(f"no permission: {p} ({n})", (40, 230 + 20 * i), BAD)
        if len(self.order) > 1:
            self.text(f"controller {self.sel + 1}/{len(self.order)} (Tab)", (790, 0), DIM, self.small)
        self.draw_logs(20, 450)
        self.text("1/2 rumble weak/strong   r g b w 0 lightbar   Tab next   c clear   q quit"
                  f"     log: {self.logpath}", (20, self.H - 20), DIM, self.small)
        pygame.display.flip()

    # ------------------------------------------------------------ main loop
    def run(self):
        pygame.init()
        self.W, self.H = 1280, 760
        self.screen = pygame.display.set_mode((self.W, self.H))
        pygame.display.set_caption("ds4view - controller debug")
        mono = "dejavusansmono,liberationmono,monospace"
        self.font = pygame.font.SysFont(mono, 15)
        self.small = pygame.font.SysFont(mono, 13)
        self.big = pygame.font.SysFont(mono, 24, bold=True)
        clock = pygame.time.Clock()
        self.log(f"ds4view started, logging to {self.logpath}", conn=True)
        t0 = time.time()
        while True:
            for ev in pygame.event.get():
                if ev.type == pygame.QUIT:
                    return
                if ev.type == pygame.KEYDOWN:
                    c = self.ctls[self.order[self.sel]] if self.order else None
                    k = ev.key
                    if k in (pygame.K_q, pygame.K_ESCAPE):
                        return
                    if k == pygame.K_TAB and self.order:
                        self.sel = (self.sel + 1) % len(self.order)
                    elif k == pygame.K_c:
                        self.events.clear()
                        self.conns.clear()
                    elif c and k == pygame.K_1:
                        self.rumble(c, 0, 0xFFFF)
                    elif c and k == pygame.K_2:
                        self.rumble(c, 0xFFFF, 0)
                    elif c and k in (pygame.K_r, pygame.K_g, pygame.K_b, pygame.K_w, pygame.K_0):
                        self.lightbar(c, {pygame.K_r: (255, 0, 0), pygame.K_g: (0, 255, 0),
                                          pygame.K_b: (0, 0, 255), pygame.K_w: (255, 255, 255),
                                          pygame.K_0: (0, 0, 0)}[k])
            if time.monotonic() - self.last_scan > 0.5:
                self.last_scan = time.monotonic()
                self.scan()
            self.pump()
            self.draw()
            if self.args.screenshot and time.time() - t0 > self.args.after:
                pygame.image.save(self.screen, self.args.screenshot)
                return
            clock.tick(120)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--match", help="only attach devices whose name contains this (default: Sony / gamepads)")
    ap.add_argument("--logdir", default=os.path.join(here, "..", "logs"))
    ap.add_argument("--screenshot", help="save a PNG after --after seconds and exit (for testing)")
    ap.add_argument("--after", type=float, default=3.0)
    App(ap.parse_args()).run()


if __name__ == "__main__":
    main()
