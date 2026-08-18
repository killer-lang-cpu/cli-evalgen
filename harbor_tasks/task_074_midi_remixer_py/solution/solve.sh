#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to midi_remixer.py..."

cat << 'EOF' > /workspace/midi_remixer.py
# ultimate_virtuoso_composer.py
import sys
import argparse
import math
import random
from pathlib import Path
import pretty_midi

# Force UTF-8 encoding for standard output to prevent Windows console crashes
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

# A Harmonic Minor Scale Notes
A_HARMONIC_MINOR =[0, 2, 3, 5, 7, 8, 11]

# WRITTEN ON ONE SINGLE LINE TO PREVENT ALL FORMATTING ERRORS
CHORD_PROGRESSION = [[45, 48, 52], [41, 45, 48],[48, 52, 55], [43, 47, 50],[45, 48, 52], [41, 45, 48],[40, 44, 47], [40, 44, 47]]

# Bass notes written on one line
BASS_NOTES =[33, 29, 36, 31, 33, 29, 28, 28]

def force_to_scale(pitch):
    """Maps any pitch strictly into the A Harmonic Minor scale for perfect cohesion."""
    octave = pitch // 12
    note = pitch % 12
    
    if note in A_HARMONIC_MINOR:
        return pitch
        
    nearest_note = min(A_HARMONIC_MINOR, key=lambda x: abs(x - note))
    return (octave * 12) + nearest_note

def extract_musical_dna(midi_path, target_length=64):
    """Deep scan of a MIDI file to extract its core melodic sequence."""
    print(f"[System] Extracting melodic DNA from: {Path(midi_path).name}...")
    default_dna =[69, 71, 72, 71, 69, 64, 65, 64]
    
    try:
        pm = pretty_midi.PrettyMIDI(midi_path)
    except Exception as e:
        print(f"[Warning] Could not read {midi_path}. Using fallback DNA.")
        return default_dna * (target_length // 8)

    all_notes =[]
    for inst in pm.instruments:
        if not inst.is_drum:
            all_notes.extend(inst.notes)
            
    if not all_notes:
        return default_dna * (target_length // 8)
        
    all_notes.sort(key=lambda x: x.start)
    
    dna_sequence =[]
    current_time = -1
    window_size = 0.5 
    
    window_notes =[]
    for note in all_notes:
        if note.start > current_time + window_size:
            if window_notes:
                highest_note = max(window_notes, key=lambda x: x.pitch)
                mapped_pitch = force_to_scale(highest_note.pitch)
                dna_sequence.append(mapped_pitch)
            window_notes = [note]
            current_time = note.start
        else:
            window_notes.append(note)
            
    # Filter extremes
    dna_sequence =[p for p in dna_sequence if 48 <= p <= 84]
    
    if not dna_sequence:
        return default_dna * (target_length // 8)
    
    while len(dna_sequence) < target_length:
        dna_sequence.extend(dna_sequence)
        
    return dna_sequence[:target_length]

def humanize(velocity):
    """Adds slight variation to velocity to simulate a real human pianist."""
    variation = random.randint(-5, 5)
    return max(1, min(127, velocity + variation))

def generate_left_hand(chord, bass, start_time, duration, style, bpm):
    """Generates massive, complex left-hand patterns."""
    notes =[]
    beat = 60.0 / bpm
    
    if style == "intro" or style == "outro":
        notes.append(pretty_midi.Note(velocity=humanize(45), pitch=bass, start=start_time, end=start_time + duration))
        notes.append(pretty_midi.Note(velocity=humanize(40), pitch=chord[0], start=start_time + beat, end=start_time + duration))
        
    elif style == "build_up":
        step = beat / 2.0
        for i in range(8):
            t = start_time + (i * step)
            pitch = bass if i % 2 == 0 else bass + 12
            notes.append(pretty_midi.Note(velocity=humanize(55 + (i*2)), pitch=pitch, start=t, end=t + step * 1.5))
            
    elif style == "development":
        step = beat / 3.0
        pattern = [bass, chord[0], chord[1], chord[2], chord[1], chord[0]] * 2
        for i, p in enumerate(pattern[:12]):
            t = start_time + (i * step)
            notes.append(pretty_midi.Note(velocity=humanize(60), pitch=p, start=t, end=t + step * 2.0))
            
    elif style == "climax" or style == "finale":
        notes.append(pretty_midi.Note(velocity=humanize(110), pitch=max(0, bass - 12), start=start_time, end=start_time + duration))
        notes.append(pretty_midi.Note(velocity=humanize(100), pitch=bass, start=start_time, end=start_time + duration))
        
        step = beat / 4.0
        arp = [chord[0], chord[1], chord[2], chord[0]+12, chord[1]+12, chord[2]+12, chord[1]+12, chord[0]+12]
        full_arp = arp + arp
        for i, p in enumerate(full_arp):
            t = start_time + (i * step)
            vel = int(75 + math.sin(i * math.pi / 8) * 25)
            notes.append(pretty_midi.Note(velocity=humanize(vel), pitch=p, start=t, end=t + step * 1.5))

    return notes

def generate_right_hand(theme, bar, start_time, bar_duration, style, bpm):
    """Generates the main melody with virtuoso flourishes and octave doublings."""
    notes =[]
    
    if style == "intro" or style == "outro":
        notes_per_bar = 2
        step = bar_duration / notes_per_bar
        for i in range(notes_per_bar):
            pitch = theme[(bar * notes_per_bar + i) % len(theme)]
            t = start_time + (i * step)
            notes.append(pretty_midi.Note(velocity=humanize(65), pitch=pitch, start=t, end=t + step * 1.8))
            
    elif style == "build_up" or style == "development":
        notes_per_bar = 4
        step = bar_duration / notes_per_bar
        for i in range(notes_per_bar):
            pitch = theme[(bar * notes_per_bar + i) % len(theme)]
            t = start_time + (i * step)
            if i == 0 and style == "development":
                grace_pitch = force_to_scale(pitch - 2)
                notes.append(pretty_midi.Note(velocity=humanize(50), pitch=grace_pitch, start=t-0.05, end=t))
            notes.append(pretty_midi.Note(velocity=humanize(80), pitch=pitch, start=t, end=t + step * 1.2))
            
    elif style == "climax":
        notes_per_bar = 8
        step = bar_duration / notes_per_bar
        for i in range(notes_per_bar):
            pitch = theme[(bar * notes_per_bar + i) % len(theme)]
            t = start_time + (i * step)
            notes.append(pretty_midi.Note(velocity=humanize(115), pitch=pitch, start=t, end=t + step))
            if pitch + 12 <= 127:
                notes.append(pretty_midi.Note(velocity=humanize(120), pitch=pitch + 12, start=t, end=t + step))
            if i % 4 == 0 and pitch - 7 >= 0:
                notes.append(pretty_midi.Note(velocity=humanize(90), pitch=force_to_scale(pitch - 7), start=t, end=t + step))
                
    elif style == "finale":
        notes_per_bar = 16
        step = bar_duration / notes_per_bar
        for i in range(notes_per_bar):
            base_pitch = theme[(bar * 4 + (i % 4)) % len(theme)]
            drop = (i % 4) * 2
            pitch = force_to_scale(base_pitch + 12 - drop)
            notes.append(pretty_midi.Note(velocity=humanize(100), pitch=pitch, start=start_time + (i*step), end=start_time + (i*step) + step))

    return notes

def compose_masterpiece(midi1, midi2, midi3, out_path):
    print("\n[System] INITIATING ULTIMATE VIRTUOSO GENERATOR")
    
    theme1 = extract_musical_dna(midi1, target_length=64)
    theme2 = extract_musical_dna(midi2, target_length=64)
    theme3 = extract_musical_dna(midi3, target_length=64)
    
    master_bpm = 110
    beat_len = 60.0 / master_bpm
    bar_len = beat_len * 4
    
    new_piece = pretty_midi.PrettyMIDI(initial_tempo=master_bpm)
    piano = pretty_midi.Instrument(program=0)
    
    current_time = 0.0
    
    sections =[
        ("The Intro", theme1, "intro", 8),
        ("The Build-Up", theme1, "build_up", 16),
        ("The Development", theme2, "development", 16),
        ("The Pre-Climax", theme2, "build_up", 8),
        ("The Climax", theme3, "climax", 24),
        ("The Grand Finale", theme3, "finale", 16),
        ("The Outro", theme1, "outro", 8)
    ]
    
    print("\n[System] Writing the sheet music...")
    
    for section_name, theme, style, num_bars in sections:
        print(f" -> Generating {section_name} ({num_bars} bars)...")
        
        for bar in range(num_bars):
            chord_idx = bar % 8 
            current_chord = CHORD_PROGRESSION[chord_idx]
            current_bass = BASS_NOTES[chord_idx]
            
            lh_notes = generate_left_hand(current_chord, current_bass, current_time, bar_len, style, master_bpm)
            piano.notes.extend(lh_notes)
            
            rh_notes = generate_right_hand(theme, bar, current_time, bar_len, style, master_bpm)
            piano.notes.extend(rh_notes)
            
            piano.control_changes.append(pretty_midi.ControlChange(64, 127, current_time))
            piano.control_changes.append(pretty_midi.ControlChange(64, 0, current_time + bar_len - 0.05))
            
            current_time += bar_len

    final_chord = CHORD_PROGRESSION[0]
    final_bass = BASS_NOTES[0]
    piano.notes.append(pretty_midi.Note(velocity=60, pitch=max(0, final_bass-12), start=current_time, end=current_time+6.0))
    piano.notes.append(pretty_midi.Note(velocity=50, pitch=final_bass, start=current_time, end=current_time+6.0))
    piano.notes.append(pretty_midi.Note(velocity=45, pitch=final_chord[0], start=current_time, end=current_time+6.0))
    piano.notes.append(pretty_midi.Note(velocity=55, pitch=theme1[0], start=current_time, end=current_time+6.0))
    piano.control_changes.append(pretty_midi.ControlChange(64, 127, current_time))
    piano.control_changes.append(pretty_midi.ControlChange(64, 0, current_time + 6.0))

    new_piece.instruments.append(piano)
    new_piece.write(str(out_path))
    print(f"\n[Success] Flawless Virtuoso Masterpiece saved to: {out_path}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Ultimate Algorithmic Virtuoso Piano Composer")
    parser.add_argument("midi1", help="Path to Song 1 (Intro/Build)")
    parser.add_argument("midi2", help="Path to Song 2 (Development)")
    parser.add_argument("midi3", help="Path to Song 3 (Climax/Finale)")
    parser.add_argument("out", help="Output file path (e.g., epic_masterpiece.mid)")
    args = parser.parse_args()
    
    compose_masterpiece(args.midi1, args.midi2, args.midi3, args.out)
EOF

echo "[Harbor Oracle] Patch applied successfully."
