#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to audioconv.py..."

cat << 'EOF' > /workspace/audioconv.py
# audioconv.py  (MIDI-only, app-friendly)
from pathlib import Path
import argparse
import requests
from tqdm import tqdm

import librosa
import torch
from piano_transcription_inference import PianoTranscription, sample_rate


# =========================
# MODEL CHECKPOINT DOWNLOAD
# =========================
CKPT_DIR = Path.home() / "piano_transcription_inference_data"
CKPT_PATH = CKPT_DIR / "CRNN_note_F1=0.9677_pedal_F1=0.9186.pth"

CKPT_URL = (
    "https://huggingface.co/Genius-Society/piano_trans/resolve/main/"
    "CRNN_note_F1%3D0.9677_pedal_F1%3D0.9186.pth"
)


def log(msg: str) -> None:
    print(f"[audioconv] {msg}", flush=True)


def ensure_checkpoint() -> None:
    CKPT_DIR.mkdir(parents=True, exist_ok=True)
    if CKPT_PATH.exists():
        log(f"Checkpoint OK: {CKPT_PATH}")
        return

    log("Checkpoint missing.")
    log(f"Downloading (~172MB) to: {CKPT_PATH}")
    r = requests.get(CKPT_URL, stream=True, timeout=60)
    r.raise_for_status()

    total = int(r.headers.get("content-length", 0))
    with open(CKPT_PATH, "wb") as f, tqdm(total=total, unit="B", unit_scale=True) as pbar:
        for chunk in r.iter_content(chunk_size=1024 * 1024):
            if chunk:
                f.write(chunk)
                pbar.update(len(chunk))

    log("Checkpoint download complete.")


def transcribe_audio_to_midi(audio_path: Path, midi_path: Path) -> None:
    ensure_checkpoint()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    log(f"Using device: {device}")

    log(f"Loading audio: {audio_path}")
    audio, _ = librosa.load(str(audio_path), sr=sample_rate, mono=True)

    log("Running transcription (audio -> MIDI)...")
    transcriptor = PianoTranscription(device=device, checkpoint_path=str(CKPT_PATH))

    if device == "cuda":
        t0 = torch.cuda.Event(enable_timing=True)
        t1 = torch.cuda.Event(enable_timing=True)
        t0.record()
        transcriptor.transcribe(audio, str(midi_path))
        t1.record()
        torch.cuda.synchronize()
        log(f"Transcription done in {t0.elapsed_time(t1)/1000.0:.1f}s")
    else:
        transcriptor.transcribe(audio, str(midi_path))
        log("Transcription done.")

    log(f"Wrote MIDI: {midi_path}")


def main():
    parser = argparse.ArgumentParser(description="Solo piano MP3/WAV -> MIDI (transcribed.mid)")
    parser.add_argument("--in", dest="inp", default="input.mp3", help="Input audio filename (default: input.mp3)")
    parser.add_argument("--out", dest="out", default="transcribed.mid", help="Output midi filename (default: transcribed.mid)")
    args = parser.parse_args()

    # IMPORTANT: Use current working directory so app.py can run this inside each song folder
    here = Path.cwd()
    audio_path = (here / args.inp).resolve()
    midi_path = (here / args.out).resolve()

    if not audio_path.exists():
        raise FileNotFoundError(f"Missing input audio: {audio_path}")

    log(f"CWD: {here}")
    log(f"Input: {audio_path.name}")
    log(f"Output: {midi_path.name}")

    transcribe_audio_to_midi(audio_path, midi_path)
    log("All done (audio -> midi only).")


if __name__ == "__main__":
    main()
EOF

echo "[Harbor Oracle] Patch applied successfully."
