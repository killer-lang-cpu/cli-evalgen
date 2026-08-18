#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to test.py..."

cat << 'EOF' > /workspace/test.py
# autosplitplayer.py
# Plays ms1 TXT files produced by miditextsplit.py (ms1 format).
#
# Supports seamless hand switching:
#   PageUp   -> LEFT
#   PageDown -> RIGHT
#   Home     -> BOTH
#
# Controls:
#   F3  start/stop
#   F2  pause/resume
#   F4  jump to chorus (if --chorus/--chorus-ms provided)
#   Mouse Wheel:
#       Scroll UP   -> speed up
#       Scroll DOWN -> speed down
#       Middle click -> reset speed to the base speed (started speed)
#   ESC exit
#
# CLI (single file):
#   python autosplitplayer.py --file transcribed_both_ms.txt
#
# CLI (recommended switching):
#   python autosplitplayer.py --both transcribed_both_ms.txt --left transcribed_left_ms.txt --right transcribed_right_ms.txt --mode both
#
# Seek:
#   --seek 40.0       (start playing from 40 seconds)
#   --seek-ms 40000
#
# Chorus jump target:
#   --chorus 40.0     (F4 jumps to 40 seconds)
#   --chorus-ms 40000
#
# Window:
#   --window 25.0     (stop after 25 seconds from the START SEEK time)

from __future__ import annotations

import argparse
import bisect
import random
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from pynput.keyboard import Controller, Key, Listener
from pynput.mouse import Listener as MouseListener, Button


# -------------------------
# TUNABLES
# -------------------------
DEFAULT_SPEED = 0.90   # 1.0 normal, <1 slower, >1 faster

# Live speed range + wheel step
SPEED_MIN = 0.50
SPEED_MAX = 2.00
SPEED_STEP = 0.05

# Small delay after pressing F3 to start (helps Roblox focus settle)
START_DELAY_MS = 120

# If behind schedule by more than this, resync instead of catch-up spamming
MAX_LAG_RESYNC_MS = 180

# Holds
HOLD_SCALE = 0.98
MIN_HOLD_MS = 18
MAX_HOLD_MS = 2200

# Humanize (keep small for accuracy)
ENABLE_HUMANIZE = True
START_JITTER_MS = 3
HOLD_JITTER_MS = 5

# Chord roll
ENABLE_CHORD_ROLL = True
CHORD_PRESS_SPREAD_MS = (0, 8)
CHORD_RELEASE_SPREAD_MS = (0, 12)

MAX_CHORD_NOTES = 6

# Soft cut when switching hands (release other-hand notes gently)
DEFAULT_SOFT_CUT_MS = 70

# Hotkeys
START_STOP_KEY = Key.f3
PAUSE_RESUME_KEY = Key.f2
CHORUS_KEY = Key.f4

SWITCH_LEFT_KEY = Key.page_up
SWITCH_RIGHT_KEY = Key.page_down
SWITCH_BOTH_KEY = Key.home
# -------------------------


SHIFT_SYMBOL_MAP = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
    "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "-", "+": "=",
    "{": "[", "}": "]",
    ":": ";", '"': "'",
    "<": ",", ">": ".", "?": "/",
    "~": "`",
}


def is_upper_alpha(ch: str) -> bool:
    return len(ch) == 1 and ch.isalpha() and ch.isupper()


def needs_shift(ch: str) -> bool:
    return is_upper_alpha(ch) or ch in SHIFT_SYMBOL_MAP


def base_key_for_shifted(ch: str) -> Optional[str]:
    if is_upper_alpha(ch):
        return ch.lower()
    return SHIFT_SYMBOL_MAP.get(ch)


def _rand_ms(lo_hi: Tuple[int, int]) -> float:
    lo, hi = lo_hi
    return random.uniform(lo, hi)


def _clamp_int(x: int, lo: int, hi: int) -> int:
    return lo if x < lo else hi if x > hi else x


def _clamp_float(x: float, lo: float, hi: float) -> float:
    return lo if x < lo else hi if x > hi else x


@dataclass
class MsEvent:
    t_ms: int
    keys: List[str]
    holds_ms: List[int]
    is_pedal: bool = False
    pedal_down: bool = False


def parse_ms1(text: str) -> List[MsEvent]:
    events: List[MsEvent] = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("&") or line == "|":
            continue
        if not line.startswith("@"):
            continue

        try:
            sp = line.find(" ")
            if sp == -1:
                continue
            t_ms = int(line[1:sp].strip())
            rest = line[sp + 1:].strip()
        except Exception:
            continue

        if rest.startswith("PEDAL="):
            down = rest.upper().endswith("DOWN")
            events.append(MsEvent(t_ms=t_ms, keys=[], holds_ms=[], is_pedal=True, pedal_down=down))
            continue

        if rest.startswith("[") and rest.endswith("]"):
            inside = rest[1:-1].strip()
            if not inside:
                continue
            parts = [p.strip() for p in inside.split(",") if p.strip()]

            keys: List[str] = []
            holds: List[int] = []

            for p in parts:
                if "=" not in p:
                    continue
                k, v = p.split("=", 1)
                k = k.strip()
                if not k:
                    continue
                try:
                    h = int(float(v.strip()))
                except Exception:
                    h = 1
                keys.append(k)
                holds.append(max(1, h))

            if keys:
                if MAX_CHORD_NOTES and len(keys) > MAX_CHORD_NOTES:
                    keys = keys[:MAX_CHORD_NOTES]
                    holds = holds[:MAX_CHORD_NOTES]
                events.append(MsEvent(t_ms=t_ms, keys=keys, holds_ms=holds))

    events.sort(key=lambda e: e.t_ms)
    return events


def event_times(events: List[MsEvent]) -> List[int]:
    return [e.t_ms for e in events]


def main():
    ap = argparse.ArgumentParser()

    ap.add_argument("--file", type=str, default="", help="single ms1 txt file (fallback if --both not provided)")
    ap.add_argument("--both", type=str, default="", help="ms1 txt for BOTH")
    ap.add_argument("--left", type=str, default="", help="ms1 txt for LEFT")
    ap.add_argument("--right", type=str, default="", help="ms1 txt for RIGHT")
    ap.add_argument("--mode", type=str, default="both", choices=["both", "left", "right"], help="start mode")

    ap.add_argument("--speed", type=float, default=DEFAULT_SPEED, help="1.0 normal, <1 slower, >1 faster")

    # Start seek (begin playback from here)
    ap.add_argument("--seek", type=float, default=0.0, help="start seek time in seconds")
    ap.add_argument("--seek-ms", type=int, default=0, help="start seek time in ms (overrides --seek)")

    # Chorus jump target (F4)
    ap.add_argument("--chorus", type=float, default=0.0, help="F4 chorus jump time in seconds")
    ap.add_argument("--chorus-ms", type=int, default=0, help="F4 chorus jump time in ms (overrides --chorus)")

    ap.add_argument("--window", type=float, default=0.0, help="play only this many seconds from START seek (0 = full)")
    ap.add_argument("--soft-cut-ms", type=int, default=DEFAULT_SOFT_CUT_MS, help="soft cut time on mode switch")

    args = ap.parse_args()

    cwd = Path(".").resolve()

    def load_file(name: str) -> Optional[List[MsEvent]]:
        if not name:
            return None
        p = (cwd / name).expanduser().resolve()
        if not p.exists():
            raise FileNotFoundError(f"Missing txt file: {p}")
        text = p.read_text(encoding="utf-8", errors="ignore")
        ev = parse_ms1(text)
        if not ev:
            raise ValueError(f"No ms1 events parsed from: {p.name}")
        return ev

    both_events = load_file(args.both) if args.both else None
    left_events = load_file(args.left) if args.left else None
    right_events = load_file(args.right) if args.right else None

    if both_events is None and left_events is None and right_events is None:
        if not args.file:
            raise SystemExit("ERROR: Provide --file or at least one of --both/--left/--right")
        both_events = load_file(args.file)

    available: Dict[str, List[MsEvent]] = {}
    if both_events:
        available["both"] = both_events
    if left_events:
        available["left"] = left_events
    if right_events:
        available["right"] = right_events

    # choose start mode with fallback
    mode = args.mode if args.mode in available else next(iter(available.keys()))

    # live speed (mutable) + base speed (wheel click resets)
    speed = _clamp_float(float(args.speed), SPEED_MIN, SPEED_MAX)
    base_speed = speed

    # compute start seek
    start_seek_ms = int(args.seek * 1000.0)
    if args.seek_ms and args.seek_ms > 0:
        start_seek_ms = int(args.seek_ms)

    # compute chorus jump (F4)
    chorus_ms = int(args.chorus * 1000.0)
    if args.chorus_ms and args.chorus_ms > 0:
        chorus_ms = int(args.chorus_ms)

    window_ms = int(args.window * 1000.0) if args.window and args.window > 0 else 0
    soft_cut_ms = max(0, int(args.soft_cut_ms))

    kb = Controller()

    # held keys
    held_until: Dict[str, float] = {}
    held_by_mode: Dict[str, str] = {}

    # indices per mode
    indices: Dict[str, int] = {m: 0 for m in available}
    times_map: Dict[str, List[int]] = {m: event_times(ev) for m, ev in available.items()}

    state: Dict[str, object] = {
        "exit": False,
        "playing": False,
        "paused": False,
        "stop": False,
        "mode": mode,
        "mode_changed": False,
        "seek_request_ms": None,   # live seek (F4)
    }

    # wall clock reference
    start_wall_s = 0.0
    base_song_ms = 0.0  # allows starting at seek without rewriting all event times

    def now_song_ms() -> float:
        # current song time (ms) = base + elapsed*speed
        return base_song_ms + (time.perf_counter() - start_wall_s) * 1000.0 * speed

    def release_due(now_t: float):
        due = [k for k, t in held_until.items() if t <= now_t]
        for k in due:
            try:
                kb.release(k)
            except Exception:
                pass
            held_until.pop(k, None)
            held_by_mode.pop(k, None)

    def release_all_now():
        for k in list(held_until.keys()):
            try:
                kb.release(k)
            except Exception:
                pass
        held_until.clear()
        held_by_mode.clear()

    def sleep_until_wall(t_target_s: float) -> bool:
        while True:
            if state["exit"] or state["stop"] or state["paused"]:
                return False
            now = time.perf_counter()
            release_due(now)
            rem = t_target_s - now
            if rem <= 0:
                return True
            time.sleep(min(rem, 0.01))

    def press_roll(keys_physical: List[str], total_spread_ms: float) -> bool:
        if not keys_physical:
            return True
        if total_spread_ms <= 0 or len(keys_physical) == 1:
            kb.press(keys_physical[0])
            return True

        order = keys_physical[:]
        random.shuffle(order)
        base_t = time.perf_counter()
        offsets = sorted(random.random() * (total_spread_ms / 1000.0) for _ in order)

        for k, off in zip(order, offsets):
            if not sleep_until_wall(base_t + off):
                return False
            kb.press(k)
        return True

    def schedule_release(phys_key: str, when_s: float, mode_tag: str):
        prev = held_until.get(phys_key)
        if prev is None or when_s > prev:
            held_until[phys_key] = when_s
            held_by_mode[phys_key] = mode_tag

    def soft_cut_to_mode(new_mode: str):
        if soft_cut_ms <= 0:
            return
        now = time.perf_counter()
        cut_deadline = now + (soft_cut_ms / 1000.0)
        for phys_key, src_mode in list(held_by_mode.items()):
            if src_mode != new_mode:
                if held_until.get(phys_key, 0) > cut_deadline:
                    held_until[phys_key] = cut_deadline

    def set_mode(new_mode: str):
        if new_mode not in available:
            return
        if state["mode"] == new_mode:
            return
        state["mode"] = new_mode
        state["mode_changed"] = True
        soft_cut_to_mode(new_mode)

        cur_ms = now_song_ms()
        indices[new_mode] = bisect.bisect_left(times_map[new_mode], int(cur_ms))

    def do_seek(target_ms: int):
        nonlocal start_wall_s, base_song_ms
        target_ms = max(0, int(target_ms))

        # release keys so Roblox doesn't get "stuck lines"
        release_all_now()

        # set base so song time == target_ms right now
        base_song_ms = float(target_ms)
        start_wall_s = time.perf_counter()

        # move indices for each mode to match
        for m in available:
            indices[m] = bisect.bisect_left(times_map[m], int(target_ms))

        state["mode_changed"] = True

    def set_speed(new_speed: float):
        """
        Change speed smoothly without "catch-up spam":
        preserve current song position, then rebuild the wall/base reference and indices.
        """
        nonlocal speed, start_wall_s, base_song_ms
        new_speed = _clamp_float(float(new_speed), SPEED_MIN, SPEED_MAX)

        if abs(new_speed - speed) < 1e-9:
            return

        # compute current song time using old speed
        cur_ms = now_song_ms()

        # update references so song time stays continuous after speed change
        speed = new_speed
        start_wall_s = time.perf_counter()
        base_song_ms = float(cur_ms)

        # resync indices for all modes
        for m in available:
            indices[m] = bisect.bisect_left(times_map[m], int(cur_ms))

        state["mode_changed"] = True
        print(f"[speed] {speed:.2f}x")

    def on_press(key):
        if key == Key.esc:
            state["exit"] = True
            state["stop"] = True
            state["paused"] = False
            return False

        if key == START_STOP_KEY:  # F3
            if not state["playing"]:
                state["playing"] = True
                state["stop"] = False
                state["paused"] = False
            else:
                state["stop"] = True
                state["paused"] = False
            return

        if key == PAUSE_RESUME_KEY:  # F2
            if state["playing"] and not state["stop"]:
                state["paused"] = not state["paused"]
            return

        # F4 chorus jump
        if key == CHORUS_KEY:
            if chorus_ms > 0 and state["playing"] and not state["stop"]:
                state["seek_request_ms"] = int(chorus_ms)
            return

        if key == SWITCH_LEFT_KEY:
            set_mode("left")
            return
        if key == SWITCH_RIGHT_KEY:
            set_mode("right")
            return
        if key == SWITCH_BOTH_KEY:
            set_mode("both")
            return

    def on_scroll(x, y, dx, dy):
        # only adjust while actively playing
        if not state["playing"] or state["stop"] or state["paused"]:
            return

        # dy > 0 is usually scroll UP; dy < 0 scroll DOWN
        if dy > 0:
            set_speed(speed + SPEED_STEP)    # up = faster
        elif dy < 0:
            set_speed(speed - SPEED_STEP)    # down = slower

    def on_click(x, y, button, pressed):
        if not pressed:
            return
        if button == Button.middle:
            if state["playing"] and not state["stop"]:
                set_speed(base_speed)

    listener = Listener(on_press=on_press)
    listener.start()

    mouse_listener = MouseListener(on_scroll=on_scroll, on_click=on_click)
    mouse_listener.start()

    print("\n=== AutoPiano MS1 Player ===")
    print(f"Available: {', '.join(sorted(available.keys()))}")
    print(f"Start mode: {mode}")
    print(f"Speed: {speed:.2f}x (wheel up/down adjusts, middle resets)")
    if start_seek_ms > 0:
        print(f"Start seek: {start_seek_ms/1000.0:.2f}s")
    if chorus_ms > 0:
        print(f"Chorus jump (F4): {chorus_ms/1000.0:.2f}s")
    if window_ms > 0:
        print(f"Window: {window_ms/1000.0:.2f}s (from start seek)")
    print("F3 : Start/Stop")
    print("F2 : Pause/Resume")
    print("F4 : Jump to CHORUS")
    print("PageUp   : LEFT")
    print("PageDown : RIGHT")
    print("Home     : BOTH")
    print("MouseWheel: up=faster, down=slower, middle=reset")
    print("ESC: Exit\n")
    print("Waiting for F3...\n")

    try:
        while not state["exit"]:
            while not state["playing"] and not state["exit"]:
                time.sleep(0.05)
            if state["exit"]:
                break

            state["stop"] = False
            state["paused"] = False
            state["mode_changed"] = True

            # Let focus settle
            time.sleep(max(0.0, START_DELAY_MS / 1000.0))

            # start clocks
            start_wall_s = time.perf_counter()
            base_song_ms = float(start_seek_ms)

            # set indices to match seek
            for m in available:
                indices[m] = bisect.bisect_left(times_map[m], int(start_seek_ms))

            # window end time if enabled
            window_end_ms = (start_seek_ms + window_ms) if window_ms > 0 else 0

            print("Playing... (F2 pause, F3 stop, F4 chorus, PageUp/PageDown/Home switch, wheel speed)")

            while not state["exit"] and not state["stop"]:
                # handle pause
                if state["paused"]:
                    while state["paused"] and not state["exit"] and not state["stop"]:
                        time.sleep(0.03)
                    # resume without catch-up spam: reset wall start so song time stays continuous
                    cur_ms = now_song_ms()
                    start_wall_s = time.perf_counter()
                    base_song_ms = float(cur_ms)
                    state["mode_changed"] = True
                    continue

                # handle F4 seek request
                req = state.get("seek_request_ms")
                if req is not None:
                    state["seek_request_ms"] = None
                    do_seek(int(req))
                    continue

                # stop if window expired
                if window_end_ms and now_song_ms() >= window_end_ms:
                    break

                cur_mode = str(state["mode"])
                evs = available[cur_mode]
                idx = indices[cur_mode]

                # sync index on mode change
                if state["mode_changed"]:
                    cur_ms = now_song_ms()
                    indices[cur_mode] = bisect.bisect_left(times_map[cur_mode], int(cur_ms))
                    idx = indices[cur_mode]
                    state["mode_changed"] = False

                if idx >= len(evs):
                    break

                ev = evs[idx]

                # target wall time for event
                target_wall = start_wall_s + ((ev.t_ms - base_song_ms) / (1000.0 * speed))

                now = time.perf_counter()

                # resync if lagging hard (prevents "burst spam")
                lag_ms = (now - target_wall) * 1000.0
                if lag_ms > MAX_LAG_RESYNC_MS:
                    start_wall_s = now - ((ev.t_ms - base_song_ms) / (1000.0 * speed))
                    target_wall = now

                if ENABLE_HUMANIZE and not ev.is_pedal:
                    target_wall += random.uniform(-START_JITTER_MS, START_JITTER_MS) / 1000.0
                    if target_wall < now - 0.002:
                        target_wall = now - 0.002

                if not sleep_until_wall(target_wall):
                    continue

                if ev.is_pedal:
                    indices[cur_mode] += 1
                    continue

                # map raw->phys
                raw_to_phys: List[Tuple[str, str]] = []
                shifted: List[str] = []
                normal: List[str] = []

                for raw in ev.keys:
                    if needs_shift(raw):
                        base = base_key_for_shifted(raw)
                        phys = base if base else raw
                        shifted.append(phys)
                        raw_to_phys.append((raw, phys))
                    else:
                        normal.append(raw)
                        raw_to_phys.append((raw, raw))

                # retrigger if still held
                for _, phys in raw_to_phys:
                    if phys in held_until:
                        try:
                            kb.release(phys)
                        except Exception:
                            pass
                        held_until.pop(phys, None)
                        held_by_mode.pop(phys, None)
                        time.sleep(0.002)

                press_spread = _rand_ms(CHORD_PRESS_SPREAD_MS) if (ENABLE_CHORD_ROLL and len(raw_to_phys) >= 2) else 0.0

                if shifted and not normal:
                    kb.press(Key.shift)
                    ok = press_roll(shifted, press_spread)
                    kb.release(Key.shift)
                    if not ok:
                        indices[cur_mode] += 1
                        continue
                elif normal and not shifted:
                    ok = press_roll(normal, press_spread)
                    if not ok:
                        indices[cur_mode] += 1
                        continue
                else:
                    kb.press(Key.shift)
                    ok = press_roll(shifted, press_spread * 0.6)
                    kb.release(Key.shift)
                    if not ok:
                        indices[cur_mode] += 1
                        continue
                    time.sleep(0.003)
                    ok2 = press_roll(normal, press_spread * 0.4)
                    if not ok2:
                        indices[cur_mode] += 1
                        continue

                # schedule releases
                rel_spread = _rand_ms(CHORD_RELEASE_SPREAD_MS) if (ENABLE_CHORD_ROLL and len(raw_to_phys) >= 2) else 0.0
                base_now = time.perf_counter()

                for i_key, (_, phys) in enumerate(raw_to_phys):
                    hold_ms = ev.holds_ms[i_key] if i_key < len(ev.holds_ms) else 40

                    hold_ms = int(hold_ms * HOLD_SCALE)
                    hold_ms = _clamp_int(hold_ms, MIN_HOLD_MS, MAX_HOLD_MS)

                    if ENABLE_HUMANIZE:
                        hold_ms += int(random.uniform(-HOLD_JITTER_MS, HOLD_JITTER_MS))
                        hold_ms = max(MIN_HOLD_MS, hold_ms)

                    off_s = 0.0
                    if rel_spread > 0:
                        off_s = (random.random() - 0.5) * (rel_spread / 1000.0)

                    schedule_release(phys, base_now + (hold_ms / 1000.0) + off_s, mode_tag=cur_mode)

                indices[cur_mode] += 1

            release_all_now()
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
        try:
            mouse_listener.stop()
        except Exception:
            pass
        release_all_now()


if __name__ == "__main__":
    main()

EOF

echo "[Harbor Oracle] Patch applied successfully."
