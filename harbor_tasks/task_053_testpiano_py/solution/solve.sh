#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to testpiano.py..."

cat << 'EOF' > /workspace/testpiano.py
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

# Must match converter
STEPS_PER_BEAT = 4

# Used only until &bpm appears
BASE_BPM = 60.0

# Global speed knob (0.75 slower, 1.0 normal, 1.2 faster)
SPEED_MULT = 1.00

# Humanization
START_JITTER_MS = 6

# Chord press roll
CHORD_PRESS_SPREAD_MS_MIN = 4
CHORD_PRESS_SPREAD_MS_MAX = 14
CHORD_PRESS_RANDOM_ORDER = True

# Retrigger handling
RETRIGGER_GAP_MS = 8

# Transport
START_STOP_KEY = Key.f3
PAUSE_RESUME_KEY = Key.f2
TEMPO_UP_HOLD_KEY = Key.enter
TEMPO_DOWN_HOLD_KEYS = {Key.ctrl, Key.ctrl_l, Key.ctrl_r}

ENTER_BPM_BOOST = 10.0
CTRL_BPM_SLOW = 5.0
MIN_BPM = 15.0
MAX_BPM = 240.0

# Cap crazy chords
MAX_CHORD_NOTES = 7
# =========================


# Shift-symbol mapping (US layout)
SHIFT_SYMBOL_MAP = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
    "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "-", "+": "=",
    "{": "[", "}": "]",
    ":": ";", '"': "'",
    "<": ",", ">": ".", "?": "/",
    "~": "`",
}


@dataclass
class KeyHit:
    raw: str        # original key symbol from sheet (may be shifted)
    hold_steps: int


@dataclass
class Event:
    keys: List[KeyHit]
    delta_steps: int
    is_rest: bool = False
    cmd: str = ""          # "bpm" or "meta"
    bpm: float = 0.0
    meta_text: str = ""


# -------------------------
# Key translation
# -------------------------
def is_upper_alpha(ch: str) -> bool:
    return len(ch) == 1 and ch.isalpha() and ch.isupper()


def needs_shift(ch: str) -> bool:
    return is_upper_alpha(ch) or ch in SHIFT_SYMBOL_MAP


def base_key_for_shifted(ch: str) -> Optional[str]:
    if is_upper_alpha(ch):
        return ch.lower()
    return SHIFT_SYMBOL_MAP.get(ch)


def physical_key(ch: str) -> str:
    """Map raw key to physical base key (J->j, !->1, etc.)"""
    if needs_shift(ch):
        base = base_key_for_shifted(ch)
        return base if base else ch
    return ch


# -------------------------
# Parser for converter format
# -------------------------
# Examples:
# &bpm 108.11
# -:16
# [9ei]:2^6
# [io]:1^2
TOKEN_BPM = re.compile(r"^&bpm\s+([0-9.]+)$", re.IGNORECASE)
TOKEN_REST = re.compile(r"^-:([0-9]+)$")
TOKEN_NOTE = re.compile(r"^\[([^\]]+)\]:(\d+)\^(\d+)$")  # chord with hold
# Allow single note like [u]:1^2 (still in brackets)
# (your converter always brackets, so we keep it simple)


def parse_sheet(text: str) -> List[Event]:
    tokens: List[str] = []
    for ln in text.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        tokens.extend(ln.split())

    events: List[Event] = []

    i = 0
    while i < len(tokens):
        tok = tokens[i]

        if tok == "|":
            i += 1
            continue

        # &bpm X (can be on one line or wrapped)
        if tok.lower() == "&bpm":
            if i + 1 < len(tokens):
                try:
                    bpm = float(tokens[i + 1])
                    events.append(Event(keys=[], delta_steps=0, cmd="bpm", bpm=bpm))
                except ValueError:
                    events.append(Event(keys=[], delta_steps=0, cmd="meta", meta_text=f"&bpm {tokens[i+1]}"))
                i += 2
                continue
            else:
                events.append(Event(keys=[], delta_steps=0, cmd="meta", meta_text="&bpm"))
                i += 1
                continue

        m = TOKEN_BPM.match(tok)
        if m:
            events.append(Event(keys=[], delta_steps=0, cmd="bpm", bpm=float(m.group(1))))
            i += 1
            continue

        # rest
        m = TOKEN_REST.match(tok)
        if m:
            events.append(Event(keys=[], delta_steps=int(m.group(1)), is_rest=True))
            i += 1
            continue

        # chord/note
        m = TOKEN_NOTE.match(tok)
        if m:
            inner = m.group(1)
            delta = int(m.group(2))
            hold = int(m.group(3))

            chars = [c for c in inner if not c.isspace()]
            if MAX_CHORD_NOTES and len(chars) > MAX_CHORD_NOTES:
                chars = chars[:MAX_CHORD_NOTES]

            hits = [KeyHit(raw=c, hold_steps=hold) for c in chars]
            events.append(Event(keys=hits, delta_steps=delta, is_rest=False))
            i += 1
            continue

        # unknown directive/meta
        if tok.startswith("&"):
            events.append(Event(keys=[], delta_steps=0, cmd="meta", meta_text=tok))
            i += 1
            continue

        i += 1

    return events


# -------------------------
# Timing helpers
# -------------------------
def _clamp(x: float, lo: float, hi: float) -> float:
    return lo if x < lo else hi if x > hi else x


def _ms(lo: int, hi: int) -> float:
    return random.uniform(lo, hi) / 1000.0


def _sleep_until_interruptible(state: Dict[str, bool], target_t: float) -> bool:
    while True:
        if state["exit"] or state["stop"] or state["paused"]:
            return False
        now = time.perf_counter()
        rem = target_t - now
        if rem <= 0:
            return True
        time.sleep(min(rem, 0.02))


def _sleep_interruptible(state: Dict[str, bool], seconds: float) -> bool:
    return _sleep_until_interruptible(state, time.perf_counter() + max(0.0, seconds))


# -------------------------
# Player (HOLD-AWARE)
# -------------------------
def play_once(events: List[Event], state: Dict[str, bool]) -> None:
    kb = Controller()
    score_bpm = BASE_BPM

    # physical_key -> release_time
    held_until: Dict[str, float] = {}

    def effective_bpm() -> float:
        bpm = score_bpm
        if state["tempo_up"]:
            bpm += ENTER_BPM_BOOST
        if state["tempo_down"]:
            bpm -= CTRL_BPM_SLOW
        return _clamp(bpm, MIN_BPM, MAX_BPM)

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

    t_cursor = time.perf_counter()

    try:
        for ev in events:
            if state["exit"] or state["stop"]:
                break

            # directives
            if ev.cmd == "bpm":
                if ev.bpm > 0:
                    score_bpm = ev.bpm
                continue
            if ev.cmd:
                continue

            # pause
            if state["paused"]:
                release_all_now()
                while state["paused"] and not state["exit"] and not state["stop"]:
                    time.sleep(0.03)
                t_cursor = time.perf_counter()
                continue

            bpm_now = effective_bpm()
            step_sec = (60.0 / bpm_now) / float(STEPS_PER_BEAT)
            step_sec = step_sec / max(0.05, float(SPEED_MULT))

            delta_s = max(0.0, ev.delta_steps) * step_sec

            # rest
            if ev.is_rest:
                t_cursor += delta_s
                continue

            press_time = t_cursor + random.uniform(-START_JITTER_MS, START_JITTER_MS) / 1000.0
            if not advance_to(press_time):
                continue

            # Split into shifted/nonshifted physical keys
            shifted: List[str] = []
            normal: List[str] = []
            holds: Dict[str, float] = {}  # physical -> hold seconds

            for hit in ev.keys:
                pk = physical_key(hit.raw)
                hold_s = max(0.01, float(hit.hold_steps) * step_sec)

                holds[pk] = max(holds.get(pk, 0.0), hold_s)

                if needs_shift(hit.raw):
                    base = base_key_for_shifted(hit.raw)
                    if base:
                        shifted.append(base)
                    else:
                        normal.append(hit.raw)
                else:
                    normal.append(hit.raw)

            # Retrigger physical repeats
            for pk in list(holds.keys()):
                if pk in held_until:
                    try:
                        kb.release(pk)
                    except Exception:
                        pass
                    held_until.pop(pk, None)
                    _sleep_interruptible(state, RETRIGGER_GAP_MS / 1000.0)

            # Press chord with optional roll
            spread = _ms(CHORD_PRESS_SPREAD_MS_MIN, CHORD_PRESS_SPREAD_MS_MAX) if len(holds) >= 2 else 0.0

            pressed_phys: List[str] = []

            # Helper: roll press
            def press_roll(keys: List[str], spread_s: float):
                if not keys:
                    return
                order = keys[:]
                if CHORD_PRESS_RANDOM_ORDER and len(order) > 1:
                    random.shuffle(order)
                base_t = time.perf_counter()
                for k in order:
                    if spread_s > 0:
                        if not _sleep_until_interruptible(state, base_t + random.random() * spread_s):
                            return
                    kb.press(k)

            if shifted and not normal:
                kb.press(Key.shift)
                press_roll(shifted, spread)
                kb.release(Key.shift)
                pressed_phys.extend(shifted)

            elif normal and not shifted:
                press_roll(normal, spread)
                pressed_phys.extend([physical_key(x) for x in normal])

            else:
                kb.press(Key.shift)
                press_roll(shifted, spread * 0.6)
                kb.release(Key.shift)
                pressed_phys.extend(shifted)

                _sleep_interruptible(state, 0.006)

                press_roll(normal, spread * 0.4)
                pressed_phys.extend([physical_key(x) for x in normal])

            # Schedule releases per key using HOLD (not gate)
            now = time.perf_counter()
            for pk in set(pressed_phys):
                held_until[pk] = max(now + 0.01, now + holds.get(pk, 0.05))

            t_cursor += delta_s

        release_all_now()

    except Exception:
        release_all_now()
        raise


def main():
    script_dir = Path(__file__).resolve().parent
    sheet_path = script_dir / SHEET_FILENAME
    if not sheet_path.exists():
        raise FileNotFoundError(f"Missing sheet file: {sheet_path}")

    events = parse_sheet(sheet_path.read_text(encoding="utf-8"))
    if not events:
        raise ValueError("No events parsed from sheet.")

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
            return
        if key in TEMPO_DOWN_HOLD_KEYS:
            state["tempo_down"] = False
            return

    listener = Listener(on_press=on_press, on_release=on_release)
    listener.start()

    print("\n=== AutoPiano (HOLD-AWARE) ===")
    print(f"Sheet: {SHEET_FILENAME}")
    print(f"STEPS_PER_BEAT={STEPS_PER_BEAT}  SPEED_MULT={SPEED_MULT}")
    print("F3 : Start / Stop")
    print("F2 : Pause / Resume")
    print("Hold ENTER : +10 BPM (while held)")
    print("Hold CTRL  : -5 BPM (while held)")
    print("ESC : Exit\n")
    print("Plays: [keys]:D^H  and  -:N   (H controls hold length!)\n")
    print("Waiting for F3...\n")

    try:
        while not state["exit"]:
            while not state["playing"] and not state["exit"]:
                time.sleep(0.05)

            if state["exit"]:
                break

            state["stop"] = False
            state["paused"] = False
            print("Playing... (F2 pause/resume, F3 stop, ESC exit)")
            play_once(events, state)

            state["playing"] = False
            state["paused"] = False
            state["stop"] = False

            if not state["exit"]:
                print("\nStopped/Finished. Waiting for F3...\n")

    finally:
        try:
            listener.stop()
        except Exception:
            pass


if __name__ == "__main__":
    main()

EOF

echo "[Harbor Oracle] Patch applied successfully."
