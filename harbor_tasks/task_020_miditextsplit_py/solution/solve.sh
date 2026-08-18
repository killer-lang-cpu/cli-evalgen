#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to miditextsplit.py..."

cat << 'EOF' > /workspace/miditextsplit.py
# miditextsplit.py
# MIDI -> TXT in ms-based format ("ms1") + left/mid/right split.
#
# Outputs:
#   transcribed_both_ms.txt
#   transcribed_left_ms.txt
#   transcribed_mid_ms.txt
#   transcribed_right_ms.txt
#
# Format example:
#   &format ms1
#   &chord_window_ms 25
#   &split_note 60
#   &right_split_note 67
#   &base_midi_note 36
#   &bake_pedal 1
#   |
#   @0[g=333,i=198,y=566]
#   @9   PEDAL=DOWN
#   @271[f=133]
#
# NOTE: This file intentionally does NOT write step-based tokens.

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple, Optional

import mido

# =========================
# CONFIG
# =========================
INPUT_MIDI = "transcribed.mid"

OUT_BOTH = "transcribed_both.txt"
OUT_LEFT = "transcribed_left.txt"
OUT_MID = "transcribed_mid.txt"
OUT_RIGHT = "transcribed_right.txt"

# Merge notes whose starts are within this window into one chord event
CHORD_WINDOW_MS = 25

# Left Split note: < split is LEFT, >= split goes to MID (C4=60 default, key 't')
SPLIT_NOTE = 60

# Right Split note: < right_split stays MID, >= right_split is RIGHT (G4=67 default, key 'o')
# Base note 36 + index 31 ('o') = 67. If you meant strictly the black key 'O', change this to 68.
RIGHT_SPLIT_NOTE = 67

# Virtual piano mapping rules
BANNED_KEYS = {"@"}               # you said '@' cannot be used
BANNED_REMAP = {"@": '"'}         # replace @ with "

# Set base midi note for your layout.
# If octave feels off, change this (36=C2, 48=C3 are common)
BASE_MIDI_NOTE = 36

# This should match your virtual piano layout.
CHROMATIC_KEYS =[
    "1", "!", "2", "@", "3", "4", "$", "5", "%", "6", "^", "7",
    "8", "*", "9", "(", "0",
    "q", "Q", "w", "W", "e", "E", "r",
    "t", "T", "y", "Y", "u",
    "i", "I", "o", "O", "p", "P",
    "a",
    "s", "S", "d", "D", "f",
    "g", "G", "h", "H", "j", "J", "k",
    "l", "L", "z", "Z", "x",
    "c", "C", "v", "V", "b", "B", "n", "m"
]

# Notes outside range: octave-shift into range instead of dropping
OCTAVE_WRAP_OUT_OF_RANGE = True

# Optional: bake sustain pedal into note ends (recommended for “musicality”)
BAKE_PEDAL_INTO_HOLDS = True
PEDAL_THRESHOLD = 64  # CC64 value >= 64 = pedal down

# --- Glissando / Fast Run Settings ---
# Reduces hold times for fast sweeps so the sustain pedal doesn't 
# turn them into a visual mess, while keeping actual held notes intact.
FIX_GLISSANDOS = True
GLISSANDO_MIN_NOTES = 4          # Minimum consecutive notes to be considered a glissando
GLISSANDO_MAX_GAP_MS = 65        # Max time between note starts to keep the run going
GLISSANDO_MAX_HOLD_MS = 120      # Cap the baked hold time to this amount
GLISSANDO_MAX_PHYS_HOLD_MS = 250 # Ignore if you physically held the key longer than this
# =========================


@dataclass
class NoteEvent:
    start_ms: int
    end_ms: int
    midi_note: int
    velocity: int
    orig_end_ms: int = -1  # Tracks the physical release time before pedal baking

    def __post_init__(self):
        if self.orig_end_ms == -1:
            self.orig_end_ms = self.end_ms


@dataclass
class PedalEvent:
    time_ms: int
    down: bool


def log(msg: str) -> None:
    print(f"[mid_to_txt_ms_split] {msg}", flush=True)


def build_note_to_key_map() -> Dict[int, str]:
    keys: List[str] =[]
    for k in CHROMATIC_KEYS:
        if k in BANNED_KEYS:
            keys.append(BANNED_REMAP.get(k, k))
        else:
            keys.append(k)

    note_to_key: Dict[int, str] = {}
    for i, k in enumerate(keys):
        note_to_key[BASE_MIDI_NOTE + i] = k
    return note_to_key


def wrap_note_into_range(note: int, lo: int, hi: int) -> int:
    while note < lo:
        note += 12
    while note > hi:
        note -= 12
    return note


def parse_midi_notes_and_pedal(midi_path: Path) -> Tuple[List[NoteEvent], List[PedalEvent]]:
    mid = mido.MidiFile(str(midi_path))
    ticks_per_beat = mid.ticks_per_beat
    merged = mido.merge_tracks(mid.tracks)

    tempo_us_per_beat = 500000  # default 120bpm
    abs_s = 0.0

    active: Dict[int, List[Tuple[float, int]]] = {}
    notes: List[NoteEvent] =[]
    pedal: List[PedalEvent] =[]

    for msg in merged:
        abs_s += mido.tick2second(msg.time, ticks_per_beat, tempo_us_per_beat)

        if msg.type == "set_tempo":
            tempo_us_per_beat = msg.tempo
            continue

        if msg.type == "control_change" and msg.control == 64:
            pedal.append(PedalEvent(
                time_ms=int(round(abs_s * 1000.0)),
                down=(msg.value >= PEDAL_THRESHOLD),
            ))
            continue

        if msg.type == "note_on" and msg.velocity > 0:
            active.setdefault(msg.note,[]).append((abs_s, msg.velocity))
            continue

        if msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
            stack = active.get(msg.note)
            if stack:
                start_s, vel = stack.pop(0)
                if abs_s > start_s:
                    notes.append(NoteEvent(
                        start_ms=int(round(start_s * 1000.0)),
                        end_ms=int(round(abs_s * 1000.0)),
                        midi_note=msg.note,
                        velocity=vel,
                    ))

    end_ms = int(round(abs_s * 1000.0))
    for pitch, stack in active.items():
        for start_s, vel in stack:
            s_ms = int(round(start_s * 1000.0))
            if end_ms > s_ms:
                notes.append(NoteEvent(s_ms, end_ms, pitch, vel))

    notes.sort(key=lambda x: (x.start_ms, x.midi_note))
    pedal.sort(key=lambda x: x.time_ms)
    return notes, pedal


def bake_pedal(notes: List[NoteEvent], pedal: List[PedalEvent]) -> None:
    if not pedal or not notes:
        return

    intervals: List[Tuple[int, int]] = []
    down_t: Optional[int] = None
    for ev in pedal:
        if ev.down and down_t is None:
            down_t = ev.time_ms
        elif (not ev.down) and down_t is not None:
            intervals.append((down_t, ev.time_ms))
            down_t = None

    if down_t is not None:
        last_end = max(n.end_ms for n in notes)
        intervals.append((down_t, last_end))

    # extend notes whose end occurs during pedal-down
    for n in notes:
        for a, b in intervals:
            if a <= n.end_ms <= b and n.start_ms <= b:
                if b > n.end_ms:
                    n.end_ms = b
                break


def fix_glissando_holds(notes: List[NoteEvent]) -> int:
    """
    Detects glissandos and caps their hold times to prevent overlapping visual mess,
    while leaving properly held chords/notes alone.
    """
    if not FIX_GLISSANDOS or not notes:
        return 0
        
    capped_count = 0
    # Temporarily sort strictly by start_ms to evaluate the temporal run
    notes.sort(key=lambda x: x.start_ms)
    
    run_start = 0
    for i in range(1, len(notes) + 1):
        # Calculate gap between note starts. Force a break on the very last iteration.
        gap = notes[i].start_ms - notes[i-1].start_ms if i < len(notes) else float('inf')
        
        # If gap is too large, the run breaks
        if gap > GLISSANDO_MAX_GAP_MS:
            run_length = i - run_start
            
            # Did this run qualify as a glissando?
            if run_length >= GLISSANDO_MIN_NOTES:
                for j in range(run_start, i):
                    n = notes[j]
                    # Calculate how long the user physically held the key before pedal
                    physical_hold = n.orig_end_ms - n.start_ms
                    
                    # Only cap it if the user didn't physically intend to hold it for a long time
                    if physical_hold <= GLISSANDO_MAX_PHYS_HOLD_MS:
                        capped_end = n.start_ms + GLISSANDO_MAX_HOLD_MS
                        if n.end_ms > capped_end:
                            n.end_ms = capped_end
                            capped_count += 1
            
            # Start the next run evaluation
            run_start = i
            
    # Return notes back to default sorting
    notes.sort(key=lambda x: (x.start_ms, x.midi_note))
    return capped_count


def split_notes(notes: List[NoteEvent]) -> Tuple[List[NoteEvent], List[NoteEvent], List[NoteEvent]]:
    left: List[NoteEvent] =[]
    mid: List[NoteEvent] = []
    right: List[NoteEvent] =[]
    for n in notes:
        if n.midi_note < SPLIT_NOTE:
            left.append(n)
        elif n.midi_note < RIGHT_SPLIT_NOTE:
            mid.append(n)
        else:
            right.append(n)
    return left, mid, right


def cluster_into_events(
    notes: List[NoteEvent],
    note_to_key: Dict[int, str],
) -> Tuple[List[Tuple[int, Dict[str, int]]], Dict[str, int]]:
    """
    Returns:
      events: list of (event_time_ms, {key: hold_ms})
      stats: dict with wrapped/dropped/mapped counts
    """
    if not notes:
        return[], {"mapped": 0, "wrapped": 0, "dropped": 0}

    lo_note = min(note_to_key.keys())
    hi_note = max(note_to_key.keys())

    mapped: List[Tuple[int, int, str]] =[]  # (start_ms, end_ms, key)
    wrapped = 0
    dropped = 0

    for n in notes:
        nn = n.midi_note
        if nn not in note_to_key:
            if OCTAVE_WRAP_OUT_OF_RANGE:
                nn2 = wrap_note_into_range(nn, lo_note, hi_note)
                if nn2 in note_to_key:
                    nn = nn2
                    wrapped += 1
                else:
                    dropped += 1
                    continue
            else:
                dropped += 1
                continue

        key = note_to_key[nn]
        mapped.append((n.start_ms, n.end_ms, key))

    mapped.sort(key=lambda x: (x[0], x[2]))

    events: List[Tuple[int, Dict[str, int]]] =[]
    i = 0
    while i < len(mapped):
        t0 = mapped[i][0]
        chord: Dict[str, int] = {}

        j = i
        while j < len(mapped) and (mapped[j][0] - t0) <= CHORD_WINDOW_MS:
            st, en, k = mapped[j]
            hold = max(1, en - st)
            chord[k] = max(chord.get(k, 0), hold)
            j += 1

        events.append((t0, chord))
        i = j

    # normalize so first event is @0
    if events:
        first = events[0][0]
        if first > 0:
            events = [(t - first, d) for (t, d) in events]

    return events, {"mapped": len(mapped), "wrapped": wrapped, "dropped": dropped}


def write_txt(
    out_path: Path,
    events: List[Tuple[int, Dict[str, int]]],
    pedal: List[PedalEvent],
    tag: str,
) -> None:
    lines: List[str] =[]
    lines.append("&format ms1")
    lines.append(f"&tag {tag}")
    lines.append(f"&chord_window_ms {CHORD_WINDOW_MS}")
    lines.append(f"&split_note {SPLIT_NOTE}")
    lines.append(f"&right_split_note {RIGHT_SPLIT_NOTE}") # Added so you can verify right split in header
    lines.append(f"&base_midi_note {BASE_MIDI_NOTE}")
    lines.append(f"&bake_pedal {int(BAKE_PEDAL_INTO_HOLDS)}")
    lines.append("|")

    pedal_iter = iter(sorted(pedal, key=lambda x: x.time_ms))
    next_p = next(pedal_iter, None)

    for t_ms, chord in events:
        while next_p is not None and next_p.time_ms <= t_ms:
            tagp = "PEDAL=DOWN" if next_p.down else "PEDAL=UP"
            lines.append(f"@{next_p.time_ms} {tagp}")
            next_p = next(pedal_iter, None)

        parts = [f"{k}={int(chord[k])}" for k in sorted(chord.keys())]
        lines.append(f"@{t_ms} [{','.join(parts)}]")

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    here = Path.cwd()
    midi_path = here / INPUT_MIDI

    if not midi_path.exists():
        raise FileNotFoundError(f"Missing MIDI: {midi_path}")

    log(f"Reading MIDI: {midi_path.name}")
    notes, pedal = parse_midi_notes_and_pedal(midi_path)
    log(f"Extracted notes: {len(notes)}")
    log(f"Extracted pedal events: {len(pedal)}")
    log(f"Split thresholds: Left < {SPLIT_NOTE} | {SPLIT_NOTE} <= Mid < {RIGHT_SPLIT_NOTE} | Right >= {RIGHT_SPLIT_NOTE}")

    if BAKE_PEDAL_INTO_HOLDS and notes and pedal:
        log("Baking sustain pedal into note holds...")
        bake_pedal(notes, pedal)

    # Apply the glissando fix to cleanup baked pedal over-extensions
    if FIX_GLISSANDOS:
        capped = fix_glissando_holds(notes)
        log(f"Glissando fix applied: shortened {capped} over-extended notes.")

    note_to_key = build_note_to_key_map()

    # Retrieve the 3-way split
    left_notes, mid_notes, right_notes = split_notes(notes)
    log(f"Left notes: {len(left_notes)}   Mid notes: {len(mid_notes)}   Right notes: {len(right_notes)}")

    log("Clustering BOTH...")
    both_events, both_stats = cluster_into_events(notes, note_to_key)
    log(f"BOTH mapped={both_stats['mapped']} wrapped={both_stats['wrapped']} dropped={both_stats['dropped']} events={len(both_events)}")

    log("Clustering LEFT...")
    left_events, left_stats = cluster_into_events(left_notes, note_to_key)
    log(f"LEFT mapped={left_stats['mapped']} wrapped={left_stats['wrapped']} dropped={left_stats['dropped']} events={len(left_events)}")

    log("Clustering MID...")
    mid_events, mid_stats = cluster_into_events(mid_notes, note_to_key)
    log(f"MID mapped={mid_stats['mapped']} wrapped={mid_stats['wrapped']} dropped={mid_stats['dropped']} events={len(mid_events)}")

    log("Clustering RIGHT...")
    right_events, right_stats = cluster_into_events(right_notes, note_to_key)
    log(f"RIGHT mapped={right_stats['mapped']} wrapped={right_stats['wrapped']} dropped={right_stats['dropped']} events={len(right_events)}")

    out_both = here / OUT_BOTH
    out_left = here / OUT_LEFT
    out_mid = here / OUT_MID
    out_right = here / OUT_RIGHT

    log(f"Writing: {out_both.name}")
    write_txt(out_both, both_events, pedal, tag="both")

    log(f"Writing: {out_left.name}")
    write_txt(out_left, left_events, pedal, tag="left")

    log(f"Writing: {out_mid.name}")
    write_txt(out_mid, mid_events, pedal, tag="mid")

    log(f"Writing: {out_right.name}")
    write_txt(out_right, right_events, pedal, tag="right")

    log("Done.")
    log(f"Wrote: {out_both}")
    log(f"Wrote: {out_left}")
    log(f"Wrote: {out_mid}")
    log(f"Wrote: {out_right}")


if __name__ == "__main__":
    main()
EOF

echo "[Harbor Oracle] Patch applied successfully."
