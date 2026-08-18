#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to converter.py..."

cat << 'EOF' > /workspace/converter.py
from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Set, Tuple
import mido

# =========================
# FIXED I/O (as requested)
# =========================
INPUT_MIDI = "input.mid"
OUTPUT_TXT = "coverted.txt"

# =========================
# EXPORT SETTINGS
# =========================
DEFAULT_STEPS_PER_BEAT = 4
DEFAULT_BASE_MIDI = 48
DEFAULT_TRANSPOSE = 0

OUTPUT_BARLINES = True
OUTPUT_TEMPO = True
OUTPUT_PEDAL = True

# Safety: limit insane gaps (optional). If you want no cap, set to None.
MAX_REST_STEPS_PER_TOKEN: Optional[int] = 4096


def quantize_tick_to_step(tick: int, ticks_per_beat: int, steps_per_beat: int) -> int:
    step_ticks = ticks_per_beat / float(steps_per_beat)
    return int(round(tick / step_ticks))


# =========================
# VIRTUAL PIANO KEY LAYOUT
# =========================
WHITE_LABELS = "1 2 3 4 5 6 7 8 9 0 q w e r t y u i o p a s d f g h j k l z x c v b n m".split()
BLACK_LABELS = "! @ $ % ^ * ( Q W E T Y I O P S D G H J L Z C V B".split()


def build_vpiano_mapping(base_midi: int) -> Dict[int, str]:
    white_order = ["C", "D", "E", "F", "G", "A", "B"]
    black_after = {"C": True, "D": True, "E": False, "F": True, "G": True, "A": True, "B": False}

    mapping: Dict[int, str] = {}
    midi = base_midi
    wi = 0
    bi = 0

    while wi < len(WHITE_LABELS):
        for step in white_order:
            if wi >= len(WHITE_LABELS):
                break
            mapping[midi] = WHITE_LABELS[wi]
            wi += 1
            midi += 1

            if black_after[step] and wi < len(WHITE_LABELS):
                if bi >= len(BLACK_LABELS):
                    break
                mapping[midi] = BLACK_LABELS[bi]
                bi += 1
                midi += 1

    return mapping


# =========================
# MIDI EXTRACTION
# =========================
@dataclass
class NoteSpan:
    start_tick: int
    end_tick: int
    midi_note: int

@dataclass
class TempoChange:
    tick: int
    bpm: float

@dataclass
class TimeSigChange:
    tick: int
    numerator: int
    denominator: int

@dataclass
class KeySigChange:
    tick: int
    key: str

@dataclass
class PedalChange:
    tick: int
    down: bool


def extract_midi_data(mid: mido.MidiFile) -> Tuple[
    List[NoteSpan],
    List[TempoChange],
    List[TimeSigChange],
    List[KeySigChange],
    List[PedalChange],
]:
    merged = mido.merge_tracks(mid.tracks)
    abs_tick = 0

    active: Dict[int, List[int]] = {}
    notes: List[NoteSpan] = []
    tempos: List[TempoChange] = []
    timesigs: List[TimeSigChange] = []
    keysigs: List[KeySigChange] = []
    pedals: List[PedalChange] = []

    for msg in merged:
        abs_tick += msg.time

        if msg.type == "set_tempo":
            bpm = 60_000_000.0 / float(msg.tempo)
            tempos.append(TempoChange(tick=abs_tick, bpm=bpm))

        elif msg.type == "time_signature":
            timesigs.append(TimeSigChange(tick=abs_tick, numerator=msg.numerator, denominator=msg.denominator))

        elif msg.type == "key_signature":
            keysigs.append(KeySigChange(tick=abs_tick, key=msg.key))

        elif msg.type == "control_change" and msg.control == 64:
            pedals.append(PedalChange(tick=abs_tick, down=(msg.value >= 64)))

        elif msg.type == "note_on" and msg.velocity > 0:
            active.setdefault(msg.note, []).append(abs_tick)

        elif msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
            if msg.note in active and active[msg.note]:
                start = active[msg.note].pop(0)
                notes.append(NoteSpan(start_tick=start, end_tick=abs_tick, midi_note=msg.note))

    notes.sort(key=lambda x: (x.start_tick, x.midi_note))
    tempos.sort(key=lambda x: x.tick)
    timesigs.sort(key=lambda x: x.tick)
    keysigs.sort(key=lambda x: x.tick)
    pedals.sort(key=lambda x: x.tick)

    return notes, tempos, timesigs, keysigs, pedals


def steps_per_bar_from_timesig(numerator: int, denominator: int, steps_per_beat: int) -> int:
    factor = 4.0 / float(denominator)
    return max(1, int(round(numerator * factor * steps_per_beat)))


def group_notes_to_steps(
    notes: List[NoteSpan],
    mapping: Dict[int, str],
    *,
    ticks_per_beat: int,
    steps_per_beat: int,
    transpose: int,
) -> Tuple[Dict[int, Dict[str, int]], int]:
    step_to_key_to_dur: Dict[int, Dict[str, int]] = {}
    max_step = 0

    for n in notes:
        midi_note = n.midi_note + transpose
        key = mapping.get(midi_note)
        if not key:
            continue

        s0 = quantize_tick_to_step(n.start_tick, ticks_per_beat, steps_per_beat)
        s1 = quantize_tick_to_step(n.end_tick, ticks_per_beat, steps_per_beat)
        dur = max(1, s1 - s0)

        d = step_to_key_to_dur.setdefault(s0, {})
        d[key] = max(d.get(key, 0), dur)

        max_step = max(max_step, s0, s1)

    return step_to_key_to_dur, max_step


def build_directive_map(
    tempos: List[TempoChange],
    timesigs: List[TimeSigChange],
    keysigs: List[KeySigChange],
    pedals: List[PedalChange],
    *,
    ticks_per_beat: int,
    steps_per_beat: int,
) -> Dict[int, List[str]]:
    step_map: Dict[int, List[str]] = {}

    def add(step: int, line: str):
        step_map.setdefault(step, []).append(line)

    if OUTPUT_TEMPO:
        for t in tempos:
            s = quantize_tick_to_step(t.tick, ticks_per_beat, steps_per_beat)
            bpm_txt = f"{t.bpm:.2f}".rstrip("0").rstrip(".")
            add(s, f"&bpm {bpm_txt}")

    for ts in timesigs:
        s = quantize_tick_to_step(ts.tick, ticks_per_beat, steps_per_beat)
        add(s, f"&ts {ts.numerator}/{ts.denominator}")

    for ks in keysigs:
        s = quantize_tick_to_step(ks.tick, ticks_per_beat, steps_per_beat)
        add(s, f"&key {ks.key}")

    if OUTPUT_PEDAL:
        for p in pedals:
            s = quantize_tick_to_step(p.tick, ticks_per_beat, steps_per_beat)
            add(s, "&pedal down" if p.down else "&pedal up")

    return step_map


def emit_rest(lines: List[str], nsteps: int):
    if nsteps <= 0:
        return
    if MAX_REST_STEPS_PER_TOKEN is None:
        lines.append(f"-:{nsteps}")
        return
    # split huge rests into chunks so files don't get insane and players stay responsive
    while nsteps > 0:
        chunk = min(nsteps, MAX_REST_STEPS_PER_TOKEN)
        lines.append(f"-:{chunk}")
        nsteps -= chunk


def export_txt_sparse(
    step_to_key_to_dur: Dict[int, Dict[str, int]],
    directive_map: Dict[int, List[str]],
    *,
    steps_per_beat: int,
    initial_timesig: Tuple[int, int],
) -> str:
    """
    Sparse export: only walk through steps that contain notes or directives,
    compress everything else as rests. This avoids hanging on huge empty ranges.
    """
    lines: List[str] = []

    ts_num, ts_den = initial_timesig
    bar_steps = steps_per_bar_from_timesig(ts_num, ts_den, steps_per_beat)

    # steps where something happens
    interesting_steps = set(step_to_key_to_dur.keys()) | set(directive_map.keys())
    if not interesting_steps:
        return ""

    sorted_steps = sorted(interesting_steps)
    cur = sorted_steps[0]

    # If there are directives before the first note step, we still handle them at their step.
    # Start at step 0 for clean output.
    if cur > 0:
        emit_rest(lines, cur)

    last_step = 0
    max_step = max(sorted_steps)

    s = 0
    while s <= max_step:
        # barlines (optional) — emitted when we cross a bar boundary
        if OUTPUT_BARLINES and bar_steps > 0 and s != 0 and (s % bar_steps == 0):
            lines.append("|")

        # directives at this step
        if s in directive_map:
            for d in directive_map[s]:
                lines.append(d)

        # notes at this step
        keys_map = step_to_key_to_dur.get(s)
        if keys_map:
            keys_sorted = sorted(keys_map.keys())
            dur = min(keys_map[k] for k in keys_sorted)  # single duration per event
            chord = "".join(keys_sorted)
            lines.append(f"[{chord}]:{dur}")
            s += 1
            continue

        # find next interesting step or next barline boundary (to keep bars readable)
        next_interesting = None
        # next step in interesting_steps greater than s
        # use sorted_steps pointer style for speed
        # (simple linear scan is okay for typical sizes, but we keep it efficient)
        # We'll binary search:
        import bisect
        idx = bisect.bisect_right(sorted_steps, s)
        if idx < len(sorted_steps):
            next_interesting = sorted_steps[idx]
        else:
            next_interesting = max_step + 1

        next_bar = None
        if OUTPUT_BARLINES and bar_steps > 0:
            next_bar = ((s // bar_steps) + 1) * bar_steps
        else:
            next_bar = max_step + 1

        next_stop = min(next_interesting, next_bar, max_step + 1)
        rest_len = max(1, next_stop - s)
        emit_rest(lines, rest_len)
        s += rest_len

    return "\n".join(lines).strip() + "\n"


def main() -> None:
    mid = mido.MidiFile(INPUT_MIDI)

    mapping = build_vpiano_mapping(DEFAULT_BASE_MIDI)
    notes, tempos, timesigs, keysigs, pedals = extract_midi_data(mid)

    if timesigs:
        init_ts = (timesigs[0].numerator, timesigs[0].denominator)
    else:
        init_ts = (4, 4)

    step_to_key_to_dur, _ = group_notes_to_steps(
        notes,
        mapping,
        ticks_per_beat=mid.ticks_per_beat,
        steps_per_beat=DEFAULT_STEPS_PER_BEAT,
        transpose=DEFAULT_TRANSPOSE,
    )

    directive_map = build_directive_map(
        tempos=tempos,
        timesigs=timesigs,
        keysigs=keysigs,
        pedals=pedals,
        ticks_per_beat=mid.ticks_per_beat,
        steps_per_beat=DEFAULT_STEPS_PER_BEAT,
    )

    txt = export_txt_sparse(
        step_to_key_to_dur=step_to_key_to_dur,
        directive_map=directive_map,
        steps_per_beat=DEFAULT_STEPS_PER_BEAT,
        initial_timesig=init_ts,
    )

    with open(OUTPUT_TXT, "w", encoding="utf-8") as f:
        f.write(txt)

    print(f"✅ Wrote {OUTPUT_TXT} from {INPUT_MIDI}")
    print(f"Used: steps_per_beat={DEFAULT_STEPS_PER_BEAT}, base_midi={DEFAULT_BASE_MIDI}, transpose={DEFAULT_TRANSPOSE}")
    print("If pitch is wrong: change DEFAULT_BASE_MIDI to 60 or transpose +/-12.")


if __name__ == "__main__":
    main()

EOF

echo "[Harbor Oracle] Patch applied successfully."
