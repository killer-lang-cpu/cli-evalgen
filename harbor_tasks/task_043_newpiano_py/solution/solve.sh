#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to newpiano.py..."

cat << 'EOF' > /workspace/newpiano.py
import random
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

from pynput.keyboard import Controller, Key, Listener


# =========================
# CONFIG
# =========================
SHEET_FILENAME = "interstellar.txt"  # same folder as this script

BASE_BPM = 48.0
STEPS_PER_BEAT = 4

# abc   -> each char uses NORMAL_CHAR_STEPS steps
# {abc} -> each char uses FAST_CHAR_STEPS steps (smaller = faster)
NORMAL_CHAR_STEPS = 1.0
FAST_CHAR_STEPS = 0.4

# Pauses
SHORT_PAUSE_STEPS = 0.5   # '-' and '|'
LONG_PAUSE_STEPS = 1.6    # '--'
PAUSE_EXTRA_JITTER_MS = 25  # extra "breath" on pauses (0–80 is good)

# --- Timing humanization (event start) ---
# Base jitter for all events
TIMING_JITTER_MS = 10
# Extra jitter for NORMAL (single) notes to feel less robotic
NORMAL_EXTRA_START_JITTER_MS = 6  # adds on top of TIMING_JITTER_MS for non-chords

# --- Blend / legato (finger-legato approximation) ---
# Adds a small overlap into next event *when safe* (no shared physical keys).
LEGATO_OVERHANG_MS_MIN = 8
LEGATO_OVERHANG_MS_MAX = 24

# If a note repeats, we need a tiny release/repress so the app retriggers it
RETRIGGER_GAP_MS = 8

# --- Hold / articulation ---
BASE_GATE = 0.94
GATE_JITTER_NORMAL = 0.07
GATE_JITTER_CHORD = 0.04
CHORD_GATE_BONUS = 0.05  # chords slightly longer than normals (but NOT until next chord)

# Extra hold jitter (ms), stronger for repeated identical events
BASE_HOLD_JITTER_MS = 8
REPEAT_HOLD_JITTER_MS = 12
MAX_HOLD_JITTER_MS = 60

# Extra hold random “feel” (ms)
NORMAL_EXTRA_HOLD_MS_MIN = 0
NORMAL_EXTRA_HOLD_MS_MAX = 14
CHORD_EXTRA_HOLD_MS_MIN = 10
CHORD_EXTRA_HOLD_MS_MAX = 28

# --- Chord roll on press + release ---
CHORD_PRESS_SPREAD_MS_MIN = 6
CHORD_PRESS_SPREAD_MS_MAX = 18
CHORD_RELEASE_SPREAD_MS_MIN = 8
CHORD_RELEASE_SPREAD_MS_MAX = 22
CHORD_PRESS_RANDOM_ORDER = True
CHORD_RELEASE_RANDOM_ORDER = True

# If chord contains both shifted and non-shifted keys, we must split.
MIXED_CHORD_SPLIT_GAP_MS = 6  # ms between shifted group and normal group

# --- NEW: extra release jitter even for NORMAL single notes ---
# Makes visualizer lengths less identical on repeated singles.
SINGLE_RELEASE_JITTER_MS_MIN = 3
SINGLE_RELEASE_JITTER_MS_MAX = 18

# --- Live tempo hold controls ---
ENTER_BPM_BOOST = 10.0   # while holding Enter
CTRL_BPM_SLOW = 5.0      # while holding Ctrl
MIN_BPM = 15.0
MAX_BPM = 240.0

# --- Transport controls ---
# F3 toggles start/stop, F2 toggles pause/resume
START_STOP_KEY = Key.f3
PAUSE_RESUME_KEY = Key.f2

# If Enter/Ctrl conflict with your app, change these:
TEMPO_UP_HOLD_KEY = Key.enter
TEMPO_DOWN_HOLD_KEYS = {Key.ctrl, Key.ctrl_l, Key.ctrl_r}
# =========================


# Shift-symbol mapping (US keyboard layout)
SHIFT_SYMBOL_MAP = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
    "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "-", "+": "=",
    "{": "[", "}": "]",
    ":": ";", '"': "'",
    "<": ",", ">": ".", "?": "/",
    "~": "`",
    # NOTE: '|' is a pause marker in your sheet (not a playable symbol here).
}


@dataclass
class Event:
    keys: List[str]                 # raw keys (chars) to press (chord or single)
    is_chord: bool = False
    duration_steps: float = 1.0
    is_rest: bool = False


# -------------------------
# Key translation helpers
# -------------------------
def is_upper_alpha(ch: str) -> bool:
    return len(ch) == 1 and ch.isalpha() and ch.isupper()


def needs_shift(ch: str) -> bool:
    return is_upper_alpha(ch) or ch in SHIFT_SYMBOL_MAP


def base_key_for_shifted(ch: str) -> Optional[str]:
    """Convert 'J' -> 'j', '!' -> '1', etc."""
    if is_upper_alpha(ch):
        return ch.lower()
    return SHIFT_SYMBOL_MAP.get(ch)


def physical_keys_for_event(ev: Event) -> Set[str]:
    """
    Set of physical base keys used by the event.
    Important for overlap logic: 'J' and 'j' both map to physical 'j'.
    """
    out: Set[str] = set()
    for raw in ev.keys:
        if needs_shift(raw):
            base = base_key_for_shifted(raw)
            out.add(base if base else raw)
        else:
            out.add(raw)
    return out


# -------------------------
# Parser
# -------------------------
def parse_sheet(text: str) -> List[Event]:
    """
    Supported:
      [abc] chord (pressed together)
      abc   sequential
      {abc} faster sequential
      - short pause, -- long pause, | short pause
    """
    s = text.strip().strip('"').strip("'")
    events: List[Event] = []
    i = 0
    n = len(s)

    while i < n:
        ch = s[i]

        if ch.isspace():
            i += 1
            continue

        if ch == "-":
            run = 1
            j = i + 1
            while j < n and s[j] == "-":
                run += 1
                j += 1
            events.append(
                Event(keys=[], is_rest=True,
                      duration_steps=SHORT_PAUSE_STEPS if run == 1 else LONG_PAUSE_STEPS)
            )
            i = j
            continue

        if ch == "|":
            events.append(Event(keys=[], is_rest=True, duration_steps=SHORT_PAUSE_STEPS))
            i += 1
            continue

        if ch == "[":
            j = i + 1
            inner: List[str] = []
            while j < n and s[j] != "]":
                if not s[j].isspace():
                    inner.append(s[j])
                j += 1
            if j < n and s[j] == "]":
                if inner:
                    events.append(Event(keys=inner, is_chord=True, duration_steps=NORMAL_CHAR_STEPS))
                i = j + 1
                continue
            # no closing bracket -> treat as literal
            events.append(Event(keys=["["], is_chord=False, duration_steps=NORMAL_CHAR_STEPS))
            i += 1
            continue

        if ch == "{":
            j = i + 1
            inner: List[str] = []
            while j < n and s[j] != "}":
                if not s[j].isspace():
                    inner.append(s[j])
                j += 1
            if j < n and s[j] == "}":
                for c in inner:
                    events.append(Event(keys=[c], is_chord=False, duration_steps=FAST_CHAR_STEPS))
                i = j + 1
                continue
            events.append(Event(keys=["{"], is_chord=False, duration_steps=NORMAL_CHAR_STEPS))
            i += 1
            continue

        # normal char -> sequential
        events.append(Event(keys=[ch], is_chord=False, duration_steps=NORMAL_CHAR_STEPS))
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
    end_t = time.perf_counter() + max(0.0, seconds)
    return _sleep_until_interruptible(state, end_t)


# -------------------------
# Chord roll helpers
# -------------------------
def _roll_actions(keys: List[str], total_spread_s: float, random_order: bool) -> List[Tuple[str, float]]:
    if not keys:
        return []
    if total_spread_s <= 0 or len(keys) == 1:
        return [(keys[0], 0.0)]
    order = keys[:]
    if random_order:
        random.shuffle(order)
    offsets = sorted(random.random() * total_spread_s for _ in order)
    return list(zip(order, offsets))


def _press_roll(kb: Controller, state: Dict[str, bool], keys: List[str], total_spread_s: float, random_order: bool) -> bool:
    actions = _roll_actions(keys, total_spread_s, random_order)
    if not actions:
        return True
    base_t = time.perf_counter()
    for k, off in actions:
        if not _sleep_until_interruptible(state, base_t + off):
            return False
        kb.press(k)
    return True


# -------------------------
# Player with "held key scheduling" for overlap blending
# -------------------------
def play_once(events: List[Event], state: Dict[str, bool]) -> None:
    kb = Controller()

    def effective_bpm() -> float:
        bpm = BASE_BPM
        if state["tempo_up"]:
            bpm += ENTER_BPM_BOOST
        if state["tempo_down"]:
            bpm -= CTRL_BPM_SLOW
        return _clamp(bpm, MIN_BPM, MAX_BPM)

    # physical key -> scheduled release time
    held_until: Dict[str, float] = {}

    def release_all_now():
        for k in list(held_until.keys()):
            try:
                kb.release(k)
            except Exception:
                pass
        held_until.clear()

    def release_due(up_to: float):
        due = [k for k, rt in held_until.items() if rt <= up_to]
        if not due:
            return
        due.sort(key=lambda k: held_until.get(k, 0.0))
        for k in due:
            try:
                kb.release(k)
            except Exception:
                pass
            held_until.pop(k, None)

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
    prev_sig: Optional[Tuple[Tuple[str, ...], bool, float, bool]] = None
    repeat_run = 0

    try:
        for idx, ev in enumerate(events):
            if state["exit"] or state["stop"]:
                break

            # Pause handling: release held notes so nothing gets stuck
            if state["paused"]:
                release_all_now()
                while state["paused"] and not state["exit"] and not state["stop"]:
                    time.sleep(0.03)
                # reset timing anchor to avoid "catch up" after pause
                t_cursor = time.perf_counter()
                continue

            bpm_now = effective_bpm()
            step_sec = (60.0 / bpm_now) / max(1, int(STEPS_PER_BEAT))
            slot = step_sec * max(0.01, float(ev.duration_steps))

            # More start jitter for normal notes than chords
            start_jitter = TIMING_JITTER_MS + (0 if ev.is_chord else NORMAL_EXTRA_START_JITTER_MS)
            press_time = t_cursor + random.uniform(-start_jitter, start_jitter) / 1000.0

            if not advance_to(press_time):
                continue

            # rest
            if ev.is_rest:
                extra = (random.randint(0, PAUSE_EXTRA_JITTER_MS) / 1000.0) if PAUSE_EXTRA_JITTER_MS else 0.0
                t_cursor += slot
                _sleep_interruptible(state, extra)
                continue

            sig = (tuple(ev.keys), ev.is_chord, float(ev.duration_steps), ev.is_rest)
            if sig == prev_sig:
                repeat_run += 1
            else:
                repeat_run = 0
                prev_sig = sig

            # legato overlap if next event doesn't share physical keys
            next_ev = events[idx + 1] if idx + 1 < len(events) else None
            allow_legato = False
            if next_ev is not None and (not next_ev.is_rest):
                if physical_keys_for_event(ev).isdisjoint(physical_keys_for_event(next_ev)):
                    allow_legato = True
            legato_overhang = _ms(LEGATO_OVERHANG_MS_MIN, LEGATO_OVERHANG_MS_MAX) if allow_legato else 0.0

            is_big_chord = ev.is_chord and len(ev.keys) >= 2
            press_spread = _ms(CHORD_PRESS_SPREAD_MS_MIN, CHORD_PRESS_SPREAD_MS_MAX) if is_big_chord else 0.0
            chord_release_spread = _ms(CHORD_RELEASE_SPREAD_MS_MIN, CHORD_RELEASE_SPREAD_MS_MAX) if is_big_chord else 0.0

            # Translate into base keys split by shift
            shifted_base: List[str] = []
            normal_keys: List[str] = []
            for raw in ev.keys:
                if needs_shift(raw):
                    base = base_key_for_shifted(raw)
                    if base:
                        shifted_base.append(base)
                    else:
                        normal_keys.append(raw)
                else:
                    normal_keys.append(raw)

            # Retrigger repeated physical keys
            for k in shifted_base + normal_keys:
                if k in held_until:
                    try:
                        kb.release(k)
                    except Exception:
                        pass
                    held_until.pop(k, None)
                    _sleep_interruptible(state, RETRIGGER_GAP_MS / 1000.0)

            pressed_now: List[str] = []

            # PRESS shifted-only / normal-only / mixed
            if shifted_base and not normal_keys:
                kb.press(Key.shift)
                ok = _press_roll(kb, state, shifted_base, press_spread, CHORD_PRESS_RANDOM_ORDER)
                kb.release(Key.shift)
                if not ok:
                    continue
                pressed_now.extend(shifted_base)

            elif normal_keys and not shifted_base:
                ok = _press_roll(kb, state, normal_keys, press_spread, CHORD_PRESS_RANDOM_ORDER)
                if not ok:
                    continue
                pressed_now.extend(normal_keys)

            else:
                # mixed chord: shifted group then normal group
                kb.press(Key.shift)
                ok = _press_roll(kb, state, shifted_base, press_spread * 0.60, CHORD_PRESS_RANDOM_ORDER)
                kb.release(Key.shift)
                if not ok:
                    continue
                pressed_now.extend(shifted_base)

                _sleep_interruptible(state, MIXED_CHORD_SPLIT_GAP_MS / 1000.0)

                ok = _press_roll(kb, state, normal_keys, press_spread * 0.40, CHORD_PRESS_RANDOM_ORDER)
                if not ok:
                    continue
                pressed_now.extend(normal_keys)

            # HOLD (gate + jitter + legato + extra hold)
            if ev.is_chord:
                gate = BASE_GATE + CHORD_GATE_BONUS + random.uniform(-GATE_JITTER_CHORD, +GATE_JITTER_CHORD)
                extra_hold = _ms(CHORD_EXTRA_HOLD_MS_MIN, CHORD_EXTRA_HOLD_MS_MAX)
            else:
                gate = BASE_GATE + random.uniform(-GATE_JITTER_NORMAL, +GATE_JITTER_NORMAL)
                extra_hold = _ms(NORMAL_EXTRA_HOLD_MS_MIN, NORMAL_EXTRA_HOLD_MS_MAX)

            gate = _clamp(gate, 0.20, 0.995)

            hold_time = slot * gate

            jitter_ms = min(BASE_HOLD_JITTER_MS + repeat_run * REPEAT_HOLD_JITTER_MS, MAX_HOLD_JITTER_MS)
            hold_time += random.uniform(-jitter_ms, +jitter_ms) / 1000.0

            hold_time += extra_hold
            hold_time += legato_overhang
            hold_time = max(0.01, hold_time)

            base_release = press_time + hold_time

            # RELEASE scheduling (per-key differences)
            # - chords: use chord_release_spread
            # - single notes: use SINGLE_RELEASE_JITTER range so repeated notes aren't same length
            if len(pressed_now) == 1:
                single_spread = _ms(SINGLE_RELEASE_JITTER_MS_MIN, SINGLE_RELEASE_JITTER_MS_MAX)
                off = random.uniform(-single_spread / 2.0, +single_spread / 2.0)
                held_until[pressed_now[0]] = max(press_time + 0.01, base_release + off)
            else:
                # chord
                spread = chord_release_spread
                order = pressed_now[:]
                if CHORD_RELEASE_RANDOM_ORDER:
                    random.shuffle(order)
                for k in order:
                    off = random.uniform(-spread / 2.0, +spread / 2.0) if spread > 0 else 0.0
                    held_until[k] = max(press_time + 0.01, base_release + off)

            t_cursor += slot

        # Cleanup
        release_all_now()

    except Exception:
        release_all_now()
        raise


def main():
    script_dir = Path(__file__).resolve().parent
    sheet_path = script_dir / SHEET_FILENAME
    if not sheet_path.exists():
        raise FileNotFoundError(f"Missing sheet file: {sheet_path}")

    text = sheet_path.read_text(encoding="utf-8")
    events = parse_sheet(text)
    if not events:
        raise ValueError("No events parsed from sheet. Check formatting.")

    # Global state controlled by hotkeys
    state = {
        "exit": False,
        "playing": False,
        "paused": False,
        "stop": False,        # stop current playback (F3 while playing)
        "tempo_up": False,    # hold Enter
        "tempo_down": False,  # hold Ctrl
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

    print("\n=== AutoPiano Ready ===")
    print("F3 : Start / Stop")
    print("F2 : Pause / Resume")
    print("Hold ENTER : +10 BPM (while held)")
    print("Hold CTRL  : -5 BPM (while held)")
    print("ESC : Exit\n")
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
