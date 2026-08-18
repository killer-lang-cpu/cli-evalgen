#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to autosplitplayer.py..."

cat << 'EOF' > /workspace/autosplitplayer.py
# autosplitplayer.py
# Plays ms1 TXT files produced by miditextsplit.py (ms1 format).
#
# Supports seamless hand switching:
#   PageUp   -> LEFT
#   End      -> MID
#   PageDown -> RIGHT
#   Home     -> BOTH
#
# Controls:
#   F3  start/stop
#   F2  pause/resume
#   F4  jump to chorus (if --chorus/--chorus-ms provided)
#   Numpad 1: skip to 10s
#   Numpad 2: skip to 40s
#   Numpad 3: skip to 60s
#   Numpad 4: skip to 80s
#   Numpad 5: skip to 120s
#   Numpad 6: skip to 150s
#   Numpad 7: skip to 180s
#   Numpad 8: skip to 200s
#   Numpad 9: go backwards by 20s
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
#   python autosplitplayer.py --both transcribed_both_ms.txt --left transcribed_left_ms.txt --mid transcribed_mid_ms.txt --right transcribed_right_ms.txt --mode both
#
# Advanced Performer Mechanics:
#   - Rubato Phrasing (Mathematical tempo pushing/pulling)
#   - Directional Arpeggiation (Bottom-up/Top-down chord rolling based on pitch)
#   - Dynamic Legato Bleed (Notes overlap dynamically based on speed)
#   - Active Sustain Pedal (Spacebar mapped to PEDAL events)

from __future__ import annotations

import argparse
import bisect
import math
import random
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from pynput.keyboard import Controller, Key, Listener, KeyCode
from pynput.mouse import Listener as MouseListener, Button

# --- NEW: Imports required for Fake MIDI Server ---
import threading
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
# ------------------------------------------------

# ==========================================
# 🎛️ TUNABLES & PROFESSIONAL MECHANICS 🎛️
# ==========================================

DEFAULT_SPEED = 0.90   # 1.0 normal, <1 slower, >1 faster

# Live speed range + wheel step
SPEED_MIN = 0.50
SPEED_MAX = 2.00
SPEED_STEP = 0.05

START_DELAY_MS = 350
MAX_LAG_RESYNC_MS = 180

# --- Advanced Expressiveness (Rubato) ---
ENABLE_RUBATO = True
RUBATO_AMPLITUDE_MS = 35.0   # Max milliseconds to push/pull the tempo for phrasing
RUBATO_FREQ_1 = 0.35         # Primary "breathing" phase cycle frequency 
RUBATO_FREQ_2 = 0.12         # Secondary long-form phrasing frequency

# --- Articulation & Legato ---
ENABLE_LEGATO = True
LEGATO_OVERLAP_MS = 15       # How much notes bleed into each other to simulate sticky/heavy fingers
HOLD_SCALE = 0.98
MIN_HOLD_MS = 18
MAX_HOLD_MS = 2500           # Increased max hold for lush ringing chords

# --- Humanization ---
ENABLE_HUMANIZE = True
START_JITTER_MS = 4          # Slightly delayed/advanced attacks
HOLD_JITTER_MS = 8

# --- Chord Arpeggiation / Glissando ---
ENABLE_CHORD_ROLL = True
CHORD_PRESS_SPREAD_MS = (2, 12)    # Spread out the strikes of a chord
CHORD_RELEASE_SPREAD_MS = (4, 20)  # Spread out the lift-off of a chord
ARPEGGIO_DIRECTION = "up"          # "up" (bottom-to-top), "down", or "random"

# --- Hardware / Engine Limits ---
MAX_CHORD_NOTES = 8
MAX_SIMULTANEOUS_KEYS = 15   # Raised to 15 to allow lush, pedal-heavy romantic pieces
DEFAULT_SOFT_CUT_MS = 70

# --- Pedal Simulation ---
ENABLE_SUSTAIN_PEDAL = False
PEDAL_KEY = Key.space        # Most Roblox/Virtual Pianos use Space for the damper pedal

# --- Hotkeys ---
START_STOP_KEY = Key.f3
PAUSE_RESUME_KEY = Key.f2
CHORUS_KEY = Key.f4

SWITCH_LEFT_KEY = Key.page_up
SWITCH_MID_KEY = Key.end
SWITCH_RIGHT_KEY = Key.page_down
SWITCH_BOTH_KEY = Key.home
# ==========================================

# --- NEW: Fake MIDI Configuration ---
FAKE_MIDI_PORT = 8080 # This port matches standard Bridge Apps.

class FakeMidiState:
    connected = True
    device_name = "Yamaha Motif XF8"
    active_notes = [] 
    pedal_down = False

class FakeMidiHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args): pass 

    def do_GET(self):
        # 1. Tell Roblox the server is here
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*') 
        
        # --- THE MAGIC FIX: PREVENT ROBLOX FROM CACHING ---
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        self.send_header('Pragma', 'no-cache')
        self.end_headers()
        
        # 2. UNIVERSAL PAYLOAD: Satisfies Midi2Roblox, RBMidi, and custom game parsers
        payload = {
            "connected": FakeMidiState.connected,
            "Connected": FakeMidiState.connected,
            "deviceName": FakeMidiState.device_name,
            "Device": FakeMidiState.device_name,
            "notes": FakeMidiState.active_notes,         # Standard Midi2Roblox
            "Notes": FakeMidiState.active_notes,         # Capitalized variation
            "keys": FakeMidiState.active_notes,          # Alt bridge standard
            "Keys": FakeMidiState.active_notes,
            "pedal": 127 if FakeMidiState.pedal_down else 0, # Some expect CC 0-127
            "sustain": FakeMidiState.pedal_down
        }
        self.wfile.write(json.dumps(payload).encode('utf-8'))

def run_fake_midi_server():
    server = HTTPServer(('localhost', FAKE_MIDI_PORT), FakeMidiHandler)
    server.serve_forever()
# ------------------------------------

SHIFT_SYMBOL_MAP = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
    "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "-", "+": "=",
    "{": "[", "}": "]",
    ":": ";", '"': "'",
    "<": ",", ">": ".", "?": "/",
    "~": "`",
}

# Standard Virtual Piano Layout Mapping (Lowest to Highest Pitch)
# This allows the script to understand pitch and roll chords professionally (bottom-up).
VP_ORDER = "1!2@34$5%6^78*9(0qQwWeErtTyYuUiIoOpPasSdDfgGhHjJklLzZxcCvVbBnm"
VP_PITCH_MAP = {ch: i for i, ch in enumerate(VP_ORDER)}

# --- NEW: Map QWERTY chars back to Real MIDI Data (Base note is C2 = 36) ---
VP_TO_MIDI_NOTE = {ch: 36 + i for i, ch in enumerate(VP_ORDER)}
# -------------------------------------------------------------------------

def get_pitch_rank(key_raw: str) -> int:
    """Returns a numeric pitch value for directional chord rolling."""
    return VP_PITCH_MAP.get(key_raw, 999)

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

def get_rubato_offset(song_t_ms: float) -> float:
    """
    Calculates a mathematical push/pull on the tempo using intertwined sine waves.
    This creates a 'breathing' effect similar to a professional pianist's phrasing.
    """
    if not ENABLE_RUBATO:
        return 0.0
    t_sec = song_t_ms / 1000.0
    # Combine two waves: one for immediate phrasing, one for overall macro-tempo drift
    wave1 = math.sin(t_sec * RUBATO_FREQ_1) * 0.6
    wave2 = math.sin(t_sec * RUBATO_FREQ_2) * 0.4
    return (wave1 + wave2) * (RUBATO_AMPLITUDE_MS / 1000.0)

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
                    # Sort by pitch before truncating so we don't lose the critical bass/melody notes
                    paired = sorted(zip(keys, holds), key=lambda pair: get_pitch_rank(pair[0]))
                    # Optional: We could keep the outermost notes (bass and melody) and drop middle ones
                    keys = [p[0] for p in paired][:MAX_CHORD_NOTES]
                    holds = [p[1] for p in paired][:MAX_CHORD_NOTES]

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
    ap.add_argument("--mid", type=str, default="", help="ms1 txt for MID")
    ap.add_argument("--right", type=str, default="", help="ms1 txt for RIGHT")
    ap.add_argument("--mode", type=str, default="both", choices=["both", "left", "mid", "right"], help="start mode")

    ap.add_argument("--speed", type=float, default=DEFAULT_SPEED, help="1.0 normal, <1 slower, >1 faster")

    # Start seek (begin playback from here)
    ap.add_argument("--seek", type=float, default=0.0, help="start seek time in seconds")
    ap.add_argument("--seek-ms", type=int, default=0, help="start seek time in ms (overrides --seek)")

    # Chorus jump target (F4)
    ap.add_argument("--chorus", type=float, default=0.0, help="F4 chorus jump time in seconds")
    ap.add_argument("--chorus-ms", type=int, default=0, help="F4 chorus jump time in ms (overrides --chorus)")

    ap.add_argument("--window", type=float, default=0.0, help="play only this many seconds from START seek (0 = full)")
    ap.add_argument("--soft-cut-ms", type=int, default=DEFAULT_SOFT_CUT_MS, help="soft cut time on mode switch")

    # --- NEW: CLI flag to enable Fake MIDI ---
    ap.add_argument("--fake-midi", action='store_true', help="Starts local HTTP server to fake a MIDI bridge")

    args = ap.parse_args()
    cwd = Path(".").resolve()

    # --- NEW: Start background server if requested ---
    if args.fake_midi:
        server_thread = threading.Thread(target=run_fake_midi_server, daemon=True)
        server_thread.start()
        print(f"[!] FAKE MIDI SERVER RUNNING ON PORT {FAKE_MIDI_PORT} [!]")

    def load_file(name: str) -> Optional[List[MsEvent]]:
        if not name:
            return None
        p = (cwd / name).expanduser().resolve()
        if not p.exists():
            raise FileNotFoundError(f"Missing txt file: {p}")
        text = p.read_text(encoding="utf-8", errors="ignore")
        ev = parse_ms1(text)
        return ev

    both_events = load_file(args.both) if args.both else None
    left_events = load_file(args.left) if args.left else None
    mid_events = load_file(args.mid) if args.mid else None
    right_events = load_file(args.right) if args.right else None

    if both_events is None and left_events is None and mid_events is None and right_events is None:
        if not args.file:
            raise SystemExit("ERROR: Provide --file or at least one of --both/--left/--mid/--right")
        both_events = load_file(args.file)

    available: Dict[str, List[MsEvent]] = {}
    if both_events is not None: available["both"] = both_events
    if left_events is not None: available["left"] = left_events
    if mid_events is not None:  available["mid"] = mid_events
    if right_events is not None: available["right"] = right_events

    max_song_ms = 0.0
    for m_evs in available.values():
        if m_evs:
            max_song_ms = max(max_song_ms, float(m_evs[-1].t_ms))

    # Choose start mode with fallback
    mode = args.mode if args.mode in available else next(iter(available.keys()))

    # Live speed (mutable) + base speed (wheel click resets)
    speed = _clamp_float(float(args.speed), SPEED_MIN, SPEED_MAX)
    base_speed = speed

    # Compute start seek
    start_seek_ms = int(args.seek * 1000.0)
    if args.seek_ms and args.seek_ms > 0:
        start_seek_ms = int(args.seek_ms)

    # Compute chorus jump (F4)
    chorus_ms = int(args.chorus * 1000.0)
    if args.chorus_ms and args.chorus_ms > 0:
        chorus_ms = int(args.chorus_ms)

    window_ms = int(args.window * 1000.0) if args.window and args.window > 0 else 0
    soft_cut_ms = max(0, int(args.soft_cut_ms))

    kb = Controller()

    # Tracking Structures
    held_until: Dict[str, float] = {}
    held_by_mode: Dict[str, str] = {}
    active_keys_fifo: List[str] = []
    
    # --- NEW --- Track raw characters for accurate MIDI note release
    held_raw: Dict[str, str] = {} 
    
    # State tracking for the pedal
    is_pedal_down = False

    indices: Dict[str, int] = {m: 0 for m in available}
    times_map: Dict[str, List[int]] = {m: event_times(ev) for m, ev in available.items()}

    state: Dict[str, object] = {
        "exit": False,
        "playing": False,
        "paused": False,
        "stop": False,
        "mode": mode,
        "mode_changed": False,
        "seek_request_ms": None,   # live seek
    }

    # Wall clock reference
    start_wall_s = 0.0
    base_song_ms = 0.0  

    def now_song_ms() -> float:
        # current song time (ms) = base + elapsed*speed
        return base_song_ms + (time.perf_counter() - start_wall_s) * 1000.0 * speed
        
    # --- UPDATED: safe_release now removes MIDI notes from server ---
    def safe_release(key_phys: str, raw_char: str = None):
        try:
            kb.release(key_phys)
        except Exception:
            pass
        if key_phys in active_keys_fifo:
            active_keys_fifo.remove(key_phys)
            
        if args.fake_midi and raw_char:
            midi_note = VP_TO_MIDI_NOTE.get(raw_char)
            if midi_note in FakeMidiState.active_notes:
                FakeMidiState.active_notes.remove(midi_note)

    # --- UPDATED: safe_press now adds MIDI notes to server ---
    def safe_press(key_phys: str, raw_char: str = None):
        # Enforce FIFO limit for max simultaneous keys to prevent hardware ghosting
        if len(active_keys_fifo) >= MAX_SIMULTANEOUS_KEYS:
            oldest = active_keys_fifo[0]
            oldest_raw = held_raw.get(oldest) 
            safe_release(oldest, oldest_raw) 
            held_until.pop(oldest, None)
            held_by_mode.pop(oldest, None)
            held_raw.pop(oldest, None)

        try:
            kb.press(key_phys)
        except Exception:
            pass
            
        if key_phys in active_keys_fifo:
            active_keys_fifo.remove(key_phys)
        active_keys_fifo.append(key_phys)
        
        if args.fake_midi and raw_char:
            midi_note = VP_TO_MIDI_NOTE.get(raw_char)
            if midi_note and midi_note not in FakeMidiState.active_notes:
                FakeMidiState.active_notes.append(midi_note)

    # --- UPDATED: release_due grabs raw char for MIDI release ---
    def release_due(now_t: float):
        due = [k for k, t in held_until.items() if t <= now_t]
        for k in due:
            raw_c = held_raw.get(k)
            safe_release(k, raw_c)
            held_until.pop(k, None)
            held_by_mode.pop(k, None)
            held_raw.pop(k, None)

    # --- UPDATED: release_all_now clears MIDI notes and pedal ---
    def release_all_now():
        nonlocal is_pedal_down
        for k in list(held_until.keys()):
            raw_c = held_raw.get(k)
            safe_release(k, raw_c)
        held_until.clear()
        held_by_mode.clear()
        held_raw.clear()
        
        for k in list(active_keys_fifo):
            safe_release(k)
            
        if is_pedal_down and ENABLE_SUSTAIN_PEDAL:
            kb.release(PEDAL_KEY)
            is_pedal_down = False
            if args.fake_midi: 
                FakeMidiState.pedal_down = False

    def sleep_until_wall(t_target_s: float) -> bool:
        while True:
            if state["exit"] or state["stop"] or state["paused"]:
                return False
            now = time.perf_counter()
            release_due(now)
            rem = t_target_s - now
            if rem <= 0:
                return True
            time.sleep(min(rem, 0.005)) # tighter sleep for better professional resolution

    def press_roll(key_pairs: List[Tuple[str, str]], total_spread_ms: float) -> bool:
        """
        Executes a professional chord roll/arpeggiato based on pitch direction.
        key_pairs is a list of tuples: (raw_key, phys_key).
        """
        if not key_pairs:
            return True
        if total_spread_ms <= 0 or len(key_pairs) == 1:
            safe_press(key_pairs[0][1], key_pairs[0][0]) # --- UPDATED
            return True

        # Sort structurally for realistic glissando/arpeggio instead of random shuffling
        if ARPEGGIO_DIRECTION == "up":
            ordered = sorted(key_pairs, key=lambda pair: get_pitch_rank(pair[0]))
        elif ARPEGGIO_DIRECTION == "down":
            ordered = sorted(key_pairs, key=lambda pair: get_pitch_rank(pair[0]), reverse=True)
        else:
            ordered = key_pairs[:]
            random.shuffle(ordered)

        base_t = time.perf_counter()
        
        # Calculate sequential offsets mimicking finger travel time
        step = (total_spread_ms / 1000.0) / len(ordered)
        offsets = [i * step for i in range(len(ordered))]
        
        # Add slight micro-timing humanization to the roll so it isn't completely robotic
        if ENABLE_HUMANIZE:
            offsets = [max(0.0, off + random.uniform(-0.002, 0.003)) for off in offsets]
            offsets.sort() # Ensure we don't accidentally invert note order due to jitter

        for (raw, phys), off in zip(ordered, offsets):
            if not sleep_until_wall(base_t + off):
                return False
            safe_press(phys, raw) # --- UPDATED
            
        return True

    # --- UPDATED: now tracks raw_key ---
    def schedule_release(phys_key: str, raw_key: str, when_s: float, mode_tag: str):
        prev = held_until.get(phys_key)
        if prev is None or when_s > prev:
            held_until[phys_key] = when_s
            held_by_mode[phys_key] = mode_tag
            held_raw[phys_key] = raw_key

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
        print(f"\n[Hand Switched] Mode -> {new_mode.upper()}")

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
        print(f"\n[Seek] Jumped to {target_ms / 1000.0:.2f}s")

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
        print(f"[Speed] {speed:.2f}x")

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
                if state["paused"]:
                    print("\n[Paused]")
                else:
                    print("\n[Resumed]")
            return

        # F4 chorus jump
        if key == CHORUS_KEY:
            if chorus_ms > 0 and state["playing"] and not state["stop"]:
                state["seek_request_ms"] = int(chorus_ms)
            return

        # Numpad Seek
        if state["playing"] and not state["stop"]:
            if hasattr(key, 'vk'):
                # Numpad virtual keys range from 96 to 105 in Windows
                numpad_targets = {
                    97: 10000,   # Numpad 1: 10 seconds
                    98: 40000,   # Numpad 2: 40 seconds
                    99: 60000,   # Numpad 3: 60 seconds
                    100: 80000,  # Numpad 4: 80 seconds
                    101: 120000, # Numpad 5: 120 seconds
                    102: 150000, # Numpad 6: 150 seconds
                    103: 180000, # Numpad 7: 180 seconds
                    104: 200000  # Numpad 8: 200 seconds
                }

                if key.vk in numpad_targets:
                    state["seek_request_ms"] = numpad_targets[key.vk]
                    return

                # Numpad 9 -> rewind 20 seconds
                if key.vk == 105: 
                    current = now_song_ms()
                    state["seek_request_ms"] = max(0, int(current - 20000))
                    return

        # Mode Switches
        if key == SWITCH_LEFT_KEY:
            set_mode("left")
            return
        if key == SWITCH_MID_KEY:
            set_mode("mid")
            return
        if key == SWITCH_RIGHT_KEY:
            set_mode("right")
            return
        if key == SWITCH_BOTH_KEY:
            set_mode("both")
            return

    def on_scroll(x, y, dx, dy):
        if not state["playing"] or state["stop"] or state["paused"]:
            return
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

    print("\n=== AutoPiano MS1 Player (Pro Edition) ===")
    print(f"Available Tracks: {', '.join(sorted(available.keys()))}")
    print(f"Start Mode: {mode.upper()}")
    print(f"Speed: {speed:.2f}x (Wheel up/down adjusts, middle resets)")
    if start_seek_ms > 0:
        print(f"Start seek: {start_seek_ms/1000.0:.2f}s")
    if chorus_ms > 0:
        print(f"Chorus jump (F4): {chorus_ms/1000.0:.2f}s")
    if window_ms > 0:
        print(f"Window: {window_ms/1000.0:.2f}s (from start seek)")
        
    print("\n--- Controls ---")
    print("F3 : Start/Stop")
    print("F2 : Pause/Resume")
    print("F4 : Jump to CHORUS")
    print("Numpad 1-8: Jump to 10s, 40s, 60s, 80s, 120s, 150s, 180s, 200s")
    print("Numpad 9  : Go backwards by 20s")
    print("PageUp    : Play LEFT hand")
    print("End       : Play MID track")
    print("PageDown  : Play RIGHT hand")
    print("Home      : Play BOTH hands")
    print("ESC       : Exit\n")
    print("Waiting for F3 to begin...\n")

    try:
        while not state["exit"]:
            while not state["playing"] and not state["exit"]:
                time.sleep(0.05)
            if state["exit"]:
                break

            state["stop"] = False
            state["paused"] = False
            state["mode_changed"] = True

            print(f"--- Starting in {START_DELAY_MS/1000:.1f}s | Mode: {state['mode'].upper()} ---")
            time.sleep(max(0.0, START_DELAY_MS / 1000.0))

            # start clocks
            start_wall_s = time.perf_counter()
            base_song_ms = float(start_seek_ms)

            # set indices to match seek
            for m in available:
                indices[m] = bisect.bisect_left(times_map[m], int(start_seek_ms))

            window_end_ms = (start_seek_ms + window_ms) if window_ms > 0 else 0

            print("Playing... (F2 pause, F3 stop, Numpad seek, PageUp/End/PageDown/Home switch)")

            while not state["exit"] and not state["stop"]:
                if state["paused"]:
                    while state["paused"] and not state["exit"] and not state["stop"]:
                        time.sleep(0.03)
                    # resume without catch-up spam
                    cur_ms = now_song_ms()
                    start_wall_s = time.perf_counter()
                    base_song_ms = float(cur_ms)
                    state["mode_changed"] = True
                    continue

                req = state.get("seek_request_ms")
                if req is not None:
                    state["seek_request_ms"] = None
                    do_seek(int(req))
                    continue

                if window_end_ms and now_song_ms() >= window_end_ms:
                    break

                cur_mode = str(state["mode"])
                evs = available[cur_mode]
                idx = indices[cur_mode]

                if state["mode_changed"]:
                    cur_ms = now_song_ms()
                    indices[cur_mode] = bisect.bisect_left(times_map[cur_mode], int(cur_ms))
                    idx = indices[cur_mode]
                    state["mode_changed"] = False

                if idx >= len(evs):
                    if now_song_ms() > max_song_ms + 500.0:
                        break
                    time.sleep(0.01)
                    continue

                ev = evs[idx]

                # Professional Mechanism: Applying Mathematical Rubato to timing
                rubato_shift_s = get_rubato_offset(ev.t_ms)

                # target wall time for event
                target_wall = start_wall_s + ((ev.t_ms - base_song_ms) / (1000.0 * speed)) + rubato_shift_s

                now = time.perf_counter()

                # resync if lagging hard (prevents "burst spam")
                lag_ms = (now - target_wall) * 1000.0
                if lag_ms > MAX_LAG_RESYNC_MS:
                    start_wall_s = now - ((ev.t_ms - base_song_ms) / (1000.0 * speed))
                    target_wall = now + rubato_shift_s

                if ENABLE_HUMANIZE and not ev.is_pedal:
                    target_wall += random.uniform(-START_JITTER_MS, START_JITTER_MS) / 1000.0
                    if target_wall < now - 0.002:
                        target_wall = now - 0.002

                if not sleep_until_wall(target_wall):
                    continue

                if ev.is_pedal:
                    if ENABLE_SUSTAIN_PEDAL:
                        if ev.pedal_down and not is_pedal_down:
                            kb.press(PEDAL_KEY)
                            is_pedal_down = True
                            if args.fake_midi: FakeMidiState.pedal_down = True # --- UPDATED
                        elif not ev.pedal_down and is_pedal_down:
                            kb.release(PEDAL_KEY)
                            is_pedal_down = False
                            if args.fake_midi: FakeMidiState.pedal_down = False # --- UPDATED
                            
                    indices[cur_mode] += 1
                    continue

                # map raw->phys
                shifted_pairs: List[Tuple[str, str]] = []
                normal_pairs: List[Tuple[str, str]] = []

                for raw in ev.keys:
                    if needs_shift(raw):
                        base = base_key_for_shifted(raw)
                        phys = base if base else raw
                        shifted_pairs.append((raw, phys))
                    else:
                        normal_pairs.append((raw, raw))

                # retrigger if still held
                for raw, phys in shifted_pairs + normal_pairs:
                    if phys in held_until:
                        safe_release(phys, raw) # --- UPDATED
                        held_until.pop(phys, None)
                        held_by_mode.pop(phys, None)
                        held_raw.pop(phys, None) # --- UPDATED
                        time.sleep(0.002)

                press_spread = _rand_ms(CHORD_PRESS_SPREAD_MS) if (ENABLE_CHORD_ROLL and len(ev.keys) >= 2) else 0.0

                # Play notes using grouped pairs to maintain the shift hold logic but internal structure rolling
                if shifted_pairs and not normal_pairs:
                    kb.press(Key.shift)
                    ok = press_roll(shifted_pairs, press_spread)
                    kb.release(Key.shift)
                    if not ok:
                        indices[cur_mode] += 1
                        continue
                elif normal_pairs and not shifted_pairs:
                    ok = press_roll(normal_pairs, press_spread)
                    if not ok:
                        indices[cur_mode] += 1
                        continue
                else:
                    # Mixed chord logic: safely separates shifted/non-shifted while keeping partial rolls intact
                    kb.press(Key.shift)
                    ok = press_roll(shifted_pairs, press_spread * 0.6)
                    kb.release(Key.shift)
                    if not ok:
                        indices[cur_mode] += 1
                        continue
                    time.sleep(0.003)
                    ok2 = press_roll(normal_pairs, press_spread * 0.4)
                    if not ok2:
                        indices[cur_mode] += 1
                        continue

                # schedule releases
                rel_spread = _rand_ms(CHORD_RELEASE_SPREAD_MS) if (ENABLE_CHORD_ROLL and len(ev.keys) >= 2) else 0.0
                base_now = time.perf_counter()

                for i_key, (raw, phys) in enumerate(shifted_pairs + normal_pairs):
                    hold_ms = ev.holds_ms[i_key] if i_key < len(ev.holds_ms) else 40

                    # Dynamic Articulation (Legato bleed)
                    if ENABLE_LEGATO:
                        hold_ms += LEGATO_OVERLAP_MS

                    hold_ms = int(hold_ms * HOLD_SCALE)
                    hold_ms = _clamp_int(hold_ms, MIN_HOLD_MS, MAX_HOLD_MS)

                    if ENABLE_HUMANIZE:
                        hold_ms += int(random.uniform(-HOLD_JITTER_MS, HOLD_JITTER_MS))
                        hold_ms = max(MIN_HOLD_MS, hold_ms)

                    off_s = 0.0
                    if rel_spread > 0:
                        off_s = (random.random() - 0.5) * (rel_spread / 1000.0)

                    schedule_release(phys, raw, base_now + (hold_ms / 1000.0) + off_s, mode_tag=cur_mode) # --- UPDATED

                indices[cur_mode] += 1

            release_all_now()
            state["playing"] = False
            state["paused"] = False
            state["stop"] = False

            if not state["exit"]:
                print("\nStopped/Finished. Waiting for F3 to replay...\n")

    finally:
        try:
            listener.stop()
            mouse_listener.stop()
        except Exception:
            pass
        release_all_now()

if __name__ == "__main__":
    main()
EOF

echo "[Harbor Oracle] Patch applied successfully."
