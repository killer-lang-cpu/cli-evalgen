#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to midi.py..."

cat << 'EOF' > /workspace/midi.py
# mid_to_txt_ms.py
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple, Optional

import mido

# =========================
# CONFIG
# =========================
INPUT_MIDI = "transcribed.mid"     # your “perfect” midi
OUT_TXT = "coverted.txt"

# Merge notes whose starts are within this window into one chord event
CHORD_WINDOW_MS = 25

# Virtual piano mapping rules
BANNED_KEYS = {"@"}               # you said '@' cannot be used
BANNED_REMAP = {"@": '"'}         # replace @ with "

# Set base midi note for your layout.
# If octave feels off, change this (36=C2, 48=C3 are common)
BASE_MIDI_NOTE = 36

# This should match your virtual piano layout.
CHROMATIC_KEYS = [
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

# =========================


@dataclass
class NoteEvent:
    start_ms: int
    end_ms: int
    midi_note: int
    velocity: int


@dataclass
class PedalEvent:
    time_ms: int
    down: bool


def log(msg: str) -> None:
    print(f"[mid2txt] {msg}", flush=True)


def build_note_to_key_map() -> Dict[int, str]:
    keys: List[str] = []
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
    # octave shift into [lo, hi]
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
    notes: List[NoteEvent] = []
    pedal: List[PedalEvent] = []

    for msg in merged:
        abs_s += mido.tick2second(msg.time, ticks_per_beat, tempo_us_per_beat)

        if msg.type == "set_tempo":
            tempo_us_per_beat = msg.tempo
            continue

        if msg.type == "control_change" and msg.control == 64:
            pedal.append(PedalEvent(time_ms=int(round(abs_s * 1000.0)),
                                    down=(msg.value >= PEDAL_THRESHOLD)))
            continue

        if msg.type == "note_on" and msg.velocity > 0:
            active.setdefault(msg.note, []).append((abs_s, msg.velocity))
            continue

        if msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
            stack = active.get(msg.note)
            if stack:
                start_s, vel = stack.pop(0)
                if abs_s > start_s:
                    notes.append(
                        NoteEvent(
                            start_ms=int(round(start_s * 1000.0)),
                            end_ms=int(round(abs_s * 1000.0)),
                            midi_note=msg.note,
                            velocity=vel,
                        )
                    )

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
    """
    If pedal is down at a note-off, extend the note to the next pedal-up.
    This is a simplified sustain model but helps musicality a lot.
    """
    if not pedal:
        return

    # Build pedal-down intervals
    intervals: List[Tuple[int, int]] = []
    down_t: Optional[int] = None
    for ev in pedal:
        if ev.down and down_t is None:
            down_t = ev.time_ms
        elif (not ev.down) and down_t is not None:
            intervals.append((down_t, ev.time_ms))
            down_t = None

    # if pedal never released, treat as till last note end
    if down_t is not None:
        last_end = max(n.end_ms for n in notes) if notes else down_t
        intervals.append((down_t, last_end))

    # extend notes
    for n in notes:
        for a, b in intervals:
            # pedal held overlaps note end
            if a <= n.end_ms <= b and n.start_ms <= b:
                if b > n.end_ms:
                    n.end_ms = b
                break


def cluster_into_events(
    notes: List[NoteEvent],
    note_to_key: Dict[int, str],
) -> List[Tuple[int, Dict[str, int]]]:
    """
    Returns list of (event_time_ms, {key: hold_ms})
    Notes that start close together (<= CHORD_WINDOW_MS) become one event.
    """
    if not notes:
        return []

    lo_note = min(note_to_key.keys())
    hi_note = max(note_to_key.keys())

    mapped: List[Tuple[int, int, str]] = []  # (start_ms, end_ms, key)
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
    log(f"Mapped notes: {len(mapped)} (wrapped={wrapped}, dropped={dropped})")

    events: List[Tuple[int, Dict[str, int]]] = []

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

    # Normalize so first event starts at 0ms (no leading silence)
    first = events[0][0]
    if first > 0:
        events = [(t - first, d) for (t, d) in events]

    return events


def write_txt(out_path: Path, events: List[Tuple[int, Dict[str, int]]], pedal: List[PedalEvent]) -> None:
    lines: List[str] = []
    lines.append("&format ms1")
    lines.append(f"&chord_window_ms {CHORD_WINDOW_MS}")
    lines.append(f"&base_midi_note {BASE_MIDI_NOTE}")
    lines.append(f"&bake_pedal {int(BAKE_PEDAL_INTO_HOLDS)}")
    lines.append("|")

    # (optional) also write pedal markers for debugging
    pedal_iter = iter(sorted(pedal, key=lambda x: x.time_ms))
    next_p = next(pedal_iter, None)

    for t_ms, chord in events:
        # emit pedal markers that happen before this event (debug only)
        while next_p is not None and next_p.time_ms <= t_ms:
            tag = "PEDAL=DOWN" if next_p.down else "PEDAL=UP"
            lines.append(f"@{next_p.time_ms} {tag}")
            next_p = next(pedal_iter, None)

        # chord line
        # Format: @1234 [q=180,w=520,e=410]
        parts = []
        for k in sorted(chord.keys()):
            parts.append(f"{k}={int(chord[k])}")
        lines.append(f"@{t_ms} [{','.join(parts)}]")

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    here = Path(__file__).resolve().parent
    midi_path = here / INPUT_MIDI
    out_txt = here / OUT_TXT

    if not midi_path.exists():
        raise FileNotFoundError(f"Missing MIDI: {midi_path}")

    log(f"Reading MIDI: {midi_path.name}")
    notes, pedal = parse_midi_notes_and_pedal(midi_path)
    log(f"Extracted notes: {len(notes)}")
    log(f"Extracted pedal events: {len(pedal)}")

    if BAKE_PEDAL_INTO_HOLDS and notes and pedal:
        log("Baking sustain pedal into note holds...")
        bake_pedal(notes, pedal)

    note_to_key = build_note_to_key_map()
    log("Clustering notes into chord events...")
    events = cluster_into_events(notes, note_to_key)
    log(f"Events written: {len(events)}")

    log(f"Writing TXT: {out_txt.name}")
    write_txt(out_txt, events, pedal)

    log("Done.")
    log(f"Wrote: {out_txt}")


if __name__ == "__main__":
    main()

EOF

echo "[Harbor Oracle] Patch applied successfully."
