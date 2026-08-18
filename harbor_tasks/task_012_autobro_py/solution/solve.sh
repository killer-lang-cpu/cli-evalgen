#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to autobro.py..."

cat << 'EOF' > /workspace/autobro.py
# autoplay_ms.py
from __future__ import annotations

import random
import time
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

from pynput.keyboard import Controller, Key, Listener

# =========================
# CONFIG
# =========================
SHEET_FILENAME = "coverted.txt"

# Global speed:
# 1.00 = normal, 0.85 = slower, 1.15 = faster
SPEED_MULT = 0.85

# “Live speed hold” (Enter speeds up, Ctrl slows down)
ENTER_SPEED_UP = 1.10
CTRL_SPEED_DOWN = 0.90

# Start jitter helps feel less robotic
START_JITTER_MS = 3

# Chord press roll
CHORD_PRESS_SPREAD_MS_MIN = 4
CHORD_PRESS_SPREAD_MS_MAX = 14
CHORD_PRESS_RANDOM_ORDER = True

# If same physical key repeats, add tiny release/repress gap
RETRIGGER_GAP_MS = 8

# Transport
START_STOP_KEY = Key.f3
PAUSE_RESUME_KEY = Key.f2
TEMPO_UP_HOLD_KEY = Key.enter
TEMPO_DOWN_HOLD_KEYS = {Key.ctrl, Key.ctrl_l, Key.ctrl_r}

# =========================


SHIFT_SYMBOL_MAP = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
    "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "-", "+": "=",
    "{": "[", "}": "]",
    ":": ";", '"': "'",
    "<": ",", ">": ".", "?": "/",
    "~": "`",
}


def log(msg: str) -> None:
    print(f"[autoplay] {msg}", flush=True)


def is_upper_alpha(ch: str) -> bool:
    return len(ch) == 1 and ch.isalpha() and ch.isupper()


def needs_shift(ch: str) -> bool:
    return is_upper_alpha(ch) or ch in SHIFT_SYMBOL_MAP


def base_key_for_shifted(ch: str) -> Optional[str]:
    if is_upper_alpha(ch):
        return ch.lower()
    return SHIFT_SYMBOL_MAP.get(ch)


def physical_key(ch: str) -> str:
    if needs_shift(ch):
        base = base_key_for_shifted(ch)
        return base if base else ch
    return ch


@dataclass
class KeyHold:
    raw: str
    hold_ms: int


@dataclass
class Event:
    time_ms: int
    keys: List[KeyHold]
    cmd: str = ""           # "" or "meta" or "pedal"
    pedal_down: Optional[bool] = None


RE_EVENT = re.compile(r"^@(\d+)\s+(.*)$")
RE_CHORD = re.compile(r"^\[([^\]]+)\]$")
RE_PEDAL = re.compile(r"^PEDAL=(DOWN|UP)$", re.IGNORECASE)


def parse_sheet(path: Path) -> List[Event]:
    text = path.read_text(encoding="utf-8")
    events: List[Event] = []

    for ln in text.splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("&") or ln == "|":
            continue

        m = RE_EVENT.match(ln)
        if not m:
            continue

        t_ms = int(m.group(1))
        rest = m.group(2).strip()

        pm = RE_PEDAL.match(rest)
        if pm:
            events.append(Event(time_ms=t_ms, keys=[], cmd="pedal", pedal_down=(pm.group(1).upper() == "DOWN")))
            continue

        cm = RE_CHORD.match(rest)
        if not cm:
            # unknown line, ignore
            continue

        inner = cm.group(1).strip()
        if not inner:
            continue

        # inner like: q=180,w=520,e=410
        parts = inner.split(",")
        keys: List[KeyHold] = []
        for p in parts:
            p = p.strip()
            if not p:
                continue
            if "=" not in p:
                continue
            k, v = p.split("=", 1)
            k = k.strip()
            v = v.strip()
            if len(k) != 1:
                continue
            try:
                hold = int(float(v))
            except ValueError:
                continue
            keys.append(KeyHold(raw=k, hold_ms=max(1, hold)))

        if keys:
            events.append(Event(time_ms=t_ms, keys=keys))

    events.sort(key=lambda e: e.time_ms)
    return events


def _sleep_until_interruptible(state: Dict[str, bool], target_t: float) -> bool:
    while True:
        if state["exit"] or state["stop"] or state["paused"]:
            return False
        now = time.perf_counter()
        rem = target_t - now
        if rem <= 0:
            return True
        time.sleep(min(rem, 0.01))


def _sleep_interruptible(state: Dict[str, bool], seconds: float) -> bool:
    return _sleep_until_interruptible(state, time.perf_counter() + max(0.0, seconds))


def play_once(events: List[Event], state: Dict[str, bool]) -> None:
    kb = Controller()

    # physical_key -> release_time
    held_until: Dict[str, float] = {}

    def current_speed_mult() -> float:
        s = SPEED_MULT
        if state["tempo_up"]:
            s *= ENTER_SPEED_UP
        if state["tempo_down"]:
            s *= CTRL_SPEED_DOWN
        return max(0.05, s)

    def release_due(up_to: float):
        due = [k for k, t in held_until.items() if t <= up_to]
        for k in due:
            try:
                kb.release(k)
            except Exception:
                pass
            held_until.pop(k, None)

    def release_all_now():
        for k in list(held_until.keys()):
            try:
                kb.release(k)
            except Exception:
                pass
        held_until.clear()

    def advance_to(t_target: float) -> bool:
        while True:
            if state["exit"] or state["stop"] or state["paused"]:
                return False
            next_rel = min(held_until.values(), default=None)
            if next_rel is not None and next_rel < t_target:
                if not _sleep_until_interruptible(state, next_rel):
                    return False
                release_due(next_rel + 1e-6)
                continue
            if not _sleep_until_interruptible(state, t_target):
                return False
            release_due(t_target + 1e-6)
            return True

    if not events:
        return

    t0_ms = events[0].time_ms
    base = time.perf_counter()

    log(f"Playback start. First event at {t0_ms}ms. Events={len(events)}")

    i = 0
    try:
        while i < len(events):
            if state["exit"] or state["stop"]:
                break

            if state["paused"]:
                release_all_now()
                pause_start = time.perf_counter()
                while state["paused"] and not state["exit"] and not state["stop"]:
                    time.sleep(0.03)
                # shift base forward by pause duration so timing stays aligned
                base += (time.perf_counter() - pause_start)
                continue

            ev = events[i]
            speed = current_speed_mult()

            rel_ms = (ev.time_ms - t0_ms) / speed
            target = base + (rel_ms / 1000.0)

            # small jitter
            jitter = random.uniform(-START_JITTER_MS, START_JITTER_MS) / 1000.0
            target += jitter

            if not advance_to(target):
                continue

            # ignore pedal lines (we baked pedal into holds in converter)
            if ev.cmd == "pedal":
                i += 1
                continue

            # Build per-physical-key hold time
            # If chord has multiple entries for same physical key, keep max hold
            hold_by_phys: Dict[str, float] = {}
            shifted_base: List[str] = []
            normal_keys: List[str] = []

            for kh in ev.keys:
                pk = physical_key(kh.raw)
                hold_by_phys[pk] = max(hold_by_phys.get(pk, 0.0), kh.hold_ms / 1000.0)

                if needs_shift(kh.raw):
                    base_k = base_key_for_shifted(kh.raw)
                    if base_k:
                        shifted_base.append(base_k)
                    else:
                        normal_keys.append(kh.raw)
                else:
                    normal_keys.append(kh.raw)

            # Retrigger if key still held
            for pk in list(hold_by_phys.keys()):
                if pk in held_until:
                    try:
                        kb.release(pk)
                    except Exception:
                        pass
                    held_until.pop(pk, None)
                    _sleep_interruptible(state, RETRIGGER_GAP_MS / 1000.0)

            # Press with optional roll
            spread = 0.0
            if len(hold_by_phys) >= 2:
                spread = random.uniform(CHORD_PRESS_SPREAD_MS_MIN, CHORD_PRESS_SPREAD_MS_MAX) / 1000.0

            def press_roll(keys: List[str], spread_s: float):
                if not keys:
                    return
                order = keys[:]
                if CHORD_PRESS_RANDOM_ORDER and len(order) > 1:
                    random.shuffle(order)
                base_t = time.perf_counter()
                for k in order:
                    if spread_s > 0:
                        _sleep_until_interruptible(state, base_t + random.random() * spread_s)
                    kb.press(k)

            pressed_phys: Set[str] = set()

            if shifted_base and not normal_keys:
                kb.press(Key.shift)
                press_roll(shifted_base, spread)
                kb.release(Key.shift)
                pressed_phys |= set(shifted_base)

            elif normal_keys and not shifted_base:
                press_roll(normal_keys, spread)
                pressed_phys |= {physical_key(x) for x in normal_keys}

            else:
                kb.press(Key.shift)
                press_roll(shifted_base, spread * 0.6)
                kb.release(Key.shift)
                pressed_phys |= set(shifted_base)

                _sleep_interruptible(state, 0.006)

                press_roll(normal_keys, spread * 0.4)
                pressed_phys |= {physical_key(x) for x in normal_keys}

            now = time.perf_counter()
            for pk in pressed_phys:
                held_until[pk] = max(now + 0.01, now + hold_by_phys.get(pk, 0.05))

            i += 1

        release_all_now()

    except Exception:
        release_all_now()
        raise


def main():
    here = Path(__file__).resolve().parent
    sheet = here / SHEET_FILENAME
    if not sheet.exists():
        raise FileNotFoundError(f"Missing sheet: {sheet}")

    events = parse_sheet(sheet)
    if not events:
        raise ValueError("No events parsed. Check coverted.txt format.")

    state = {
        "exit": False,
        "playing": False,
        "paused": False,
        "stop": False,
        "tempo_up": False,
        "tempo_down": False,
    }

    def on_press(key):
        if key == Key.esc:
            state["exit"] = True
            state["stop"] = True
            state["paused"] = False
            return False

        if key == START_STOP_KEY:
            if not state["playing"]:
                state["playing"] = True
                state["stop"] = False
                state["paused"] = False
            else:
                state["stop"] = True
                state["paused"] = False
            return

        if key == PAUSE_RESUME_KEY:
            if state["playing"] and not state["stop"]:
                state["paused"] = not state["paused"]
            return

        if key == TEMPO_UP_HOLD_KEY:
            state["tempo_up"] = True
            return

        if key in TEMPO_DOWN_HOLD_KEYS:
            state["tempo_down"] = True
            return

    def on_release(key):
        if key == TEMPO_UP_HOLD_KEY:
            state["tempo_up"] = False
        if key in TEMPO_DOWN_HOLD_KEYS:
            state["tempo_down"] = False

    listener = Listener(on_press=on_press, on_release=on_release)
    listener.start()

    log("=== AutoPiano MS ===")
    log(f"Sheet: {SHEET_FILENAME}")
    log(f"SPEED_MULT={SPEED_MULT}  (hold Enter speeds up, hold Ctrl slows down)")
    log("F3 start/stop | F2 pause | ESC exit")
    log("Waiting for F3...\n")

    try:
        while not state["exit"]:
            while not state["playing"] and not state["exit"]:
                time.sleep(0.05)

            if state["exit"]:
                break

            state["stop"] = False
            state["paused"] = False

            log("Playing...")
            play_once(events, state)

            state["playing"] = False
            state["paused"] = False
            state["stop"] = False

            if not state["exit"]:
                log("Stopped/Finished. Waiting for F3...\n")

    finally:
        try:
            listener.stop()
        except Exception:
            pass


if __name__ == "__main__":
    main()

EOF

echo "[Harbor Oracle] Patch applied successfully."
