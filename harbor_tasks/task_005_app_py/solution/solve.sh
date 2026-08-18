#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to app.py..."

cat << 'EOF' > /workspace/app.py
# app.py
import json
import re
import shutil
import sys
from pathlib import Path
from datetime import datetime

from PySide6 import QtCore, QtGui, QtWidgets
from pynput.keyboard import Listener, Key


APP_DIR = Path(__file__).resolve().parent

AUDIOCONV = APP_DIR / "audioconv.py"
SPLITTER = APP_DIR / "miditextsplit.py"
PLAYER = APP_DIR / "autosplitplayer.py"
MIRROR = APP_DIR / "mirror.py"

LIB_DIR = APP_DIR / "library"
SONGS_DIR = LIB_DIR / "songs"
DB_PATH = LIB_DIR / "library.json"


# -------------------------
# helpers
# -------------------------
def safe_name(name: str) -> str:
    name = name.strip()
    name = re.sub(r"[^\w\s\-()]+", "", name, flags=re.UNICODE)
    name = re.sub(r"\s+", " ", name).strip()
    return name[:80] if name else "Song"


def ensure_library():
    SONGS_DIR.mkdir(parents=True, exist_ok=True)
    if not DB_PATH.exists():
        DB_PATH.write_text(json.dumps({"songs":[]}, indent=2), encoding="utf-8")


def load_db():
    ensure_library()
    return json.loads(DB_PATH.read_text(encoding="utf-8"))


def save_db(db):
    DB_PATH.write_text(json.dumps(db, indent=2), encoding="utf-8")


def now_iso():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def song_dir_for(stem: str) -> Path:
    base = safe_name(stem)
    d = SONGS_DIR / base
    if not d.exists():
        return d
    i = 2
    while True:
        cand = SONGS_DIR / f"{base} ({i})"
        if not cand.exists():
            return cand
        i += 1


# -------------------------
# UI widgets
# -------------------------
class DropArea(QtWidgets.QFrame):
    # SIGNAL CHANGED TO LIST
    filesDropped = QtCore.Signal(list)

    def __init__(self):
        super().__init__()
        self.setAcceptDrops(True)
        self.setFrameStyle(QtWidgets.QFrame.StyledPanel | QtWidgets.QFrame.Raised)
        self.setMinimumHeight(120)

        layout = QtWidgets.QVBoxLayout(self)
        self.label = QtWidgets.QLabel("Drag & drop MP3(s) here\n(creates song folder → transcribes → splits → saves)")
        self.label.setAlignment(QtCore.Qt.AlignCenter)
        font = self.label.font()
        font.setPointSize(11)
        self.label.setFont(font)
        layout.addWidget(self.label)

    def dragEnterEvent(self, e: QtGui.QDragEnterEvent):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e: QtGui.QDropEvent):
        # GATHER ALL MP3s
        mp3_list =[]
        for url in e.mimeData().urls():
            p = Path(url.toLocalFile())
            if p.suffix.lower() == ".mp3":
                mp3_list.append(p)
        
        # EMIT LIST
        if mp3_list:
            self.filesDropped.emit(mp3_list)


class MainWindow(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        ensure_library()
        self.db = load_db()

        self.setWindowTitle("AutoPiano Library (Drop MP3 → Transcribe → Split → Play)")
        self.resize(1050, 650)

        self.proc_audio = QtCore.QProcess(self)
        self.proc_split = QtCore.QProcess(self)
        self.proc_play = QtCore.QProcess(self)
        self.proc_mirror = QtCore.QProcess(self)

        self.pending_song_dir = None
        
        # NEW: Queue system list
        self.processing_queue =[]

        # GLOBAL HOTKEY LISTENER (F5 / F6)
        self.hotkey_listener = Listener(on_press=self.on_global_key)
        self.hotkey_listener.start()

        central = QtWidgets.QWidget()
        self.setCentralWidget(central)
        root = QtWidgets.QHBoxLayout(central)

        # left
        left = QtWidgets.QVBoxLayout()
        root.addLayout(left, 2)

        header = QtWidgets.QHBoxLayout()
        left.addLayout(header)
        header.addWidget(QtWidgets.QLabel("Saved Songs"))

        self.btnOpenLibrary = QtWidgets.QPushButton("Open Library Folder")
        self.btnOpenLibrary.clicked.connect(self.open_library_folder)
        header.addWidget(self.btnOpenLibrary)

        self.songList = QtWidgets.QListWidget()
        self.songList.itemSelectionChanged.connect(self.update_buttons)
        left.addWidget(self.songList)

        # right
        right = QtWidgets.QVBoxLayout()
        root.addLayout(right, 3)

        self.drop = DropArea()
        # CONNECT TO QUEUE HANDLER INSTEAD OF DIRECT IMPORT
        self.drop.filesDropped.connect(self.queue_files)
        right.addWidget(self.drop)

        row1 = QtWidgets.QHBoxLayout()
        right.addLayout(row1)

        self.chkTop = QtWidgets.QCheckBox("Always on top")
        self.chkTop.stateChanged.connect(self.toggle_always_on_top)
        row1.addWidget(self.chkTop)

        # --- NEW: Fake MIDI UI Toggle ---
        self.chkFakeMidi = QtWidgets.QCheckBox("Fake MIDI Tag")
        self.chkFakeMidi.setChecked(True)
        self.chkFakeMidi.setToolTip("Broadcasts actual MIDI data to Roblox locally so you can play with QWERTY turned off!")
        row1.addWidget(self.chkFakeMidi)
        # --------------------------------

        self.btnImport = QtWidgets.QPushButton("Import MP3…")
        self.btnImport.clicked.connect(self.pick_mp3)
        row1.addWidget(self.btnImport)

        row2 = QtWidgets.QHBoxLayout()
        right.addLayout(row2)

        self.mode = QtWidgets.QComboBox()
        self.mode.addItems(["both", "left", "mid", "right"])
        row2.addWidget(QtWidgets.QLabel("Start mode:"))
        row2.addWidget(self.mode)

        self.speed = QtWidgets.QDoubleSpinBox()
        self.speed.setRange(0.30, 2.00)
        self.speed.setSingleStep(0.05)
        self.speed.setValue(0.90)
        self.speed.setDecimals(2)
        row2.addWidget(QtWidgets.QLabel("Speed:"))
        row2.addWidget(self.speed)

        self.chorus = QtWidgets.QDoubleSpinBox()
        self.chorus.setRange(0.0, 36000.0)
        self.chorus.setSingleStep(1.0)
        self.chorus.setValue(0.0)
        self.chorus.setDecimals(2)
        row2.addWidget(QtWidgets.QLabel("Chorus (sec):"))
        row2.addWidget(self.chorus)

        self.btnPlay = QtWidgets.QPushButton("Play Selected")
        self.btnPlay.clicked.connect(self.play_selected)
        row2.addWidget(self.btnPlay)

        self.btnStop = QtWidgets.QPushButton("Stop")
        self.btnStop.clicked.connect(self.stop_playback)
        row2.addWidget(self.btnStop)

        # MIRROR BUTTONS
        mirror_row = QtWidgets.QHBoxLayout()
        right.addLayout(mirror_row)

        self.btnMirrorStart = QtWidgets.QPushButton("Mirror Record (F5)")
        self.btnMirrorStart.clicked.connect(self.toggle_mirror)
        mirror_row.addWidget(self.btnMirrorStart)

        self.btnMirrorPlay = QtWidgets.QPushButton("Mirror Play (F6)")
        self.btnMirrorPlay.clicked.connect(self.play_mirror)
        mirror_row.addWidget(self.btnMirrorPlay)

        self.btnOpenSongFolder = QtWidgets.QPushButton("Open Song Folder")
        self.btnOpenSongFolder.clicked.connect(self.open_song_folder)
        right.addWidget(self.btnOpenSongFolder)

        self.statusLabel = QtWidgets.QLabel("Ready.")
        right.addWidget(self.statusLabel)

        self.progress = QtWidgets.QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.hide()
        right.addWidget(self.progress)

        right.addWidget(QtWidgets.QLabel("Logs"))
        self.logBox = QtWidgets.QPlainTextEdit()
        self.logBox.setReadOnly(True)
        right.addWidget(self.logBox)

        self.refresh_library()

        for p in (self.proc_audio, self.proc_split, self.proc_play, self.proc_mirror):
            p.setProcessChannelMode(QtCore.QProcess.MergedChannels)

        self.proc_audio.readyReadStandardOutput.connect(lambda: self._drain(self.proc_audio))
        self.proc_split.readyReadStandardOutput.connect(lambda: self._drain(self.proc_split))
        self.proc_play.readyReadStandardOutput.connect(lambda: self._drain(self.proc_play))
        self.proc_mirror.readyReadStandardOutput.connect(lambda: self._drain(self.proc_mirror))

        self.proc_audio.finished.connect(self.on_audio_finished)
        self.proc_split.finished.connect(self.on_split_finished)
        self.proc_play.finished.connect(lambda *_: self.update_buttons())

        self.update_buttons()

    # ---------- QUEUE SYSTEM (NEW) ----------
    def queue_files(self, file_list):
        self.processing_queue.extend(file_list)
        self.log(f"[app] Added {len(file_list)} file(s) to queue. Total waiting: {len(self.processing_queue)}")
        self.process_next_in_queue()

    def process_next_in_queue(self):
        # If already processing something, just return and wait.
        if self.proc_audio.state() != QtCore.QProcess.NotRunning or self.proc_split.state() != QtCore.QProcess.NotRunning:
            return

        # If queue is empty, we are done!
        if not self.processing_queue:
            self.busy(False, "Ready. Queue empty.")
            return

        # Take the first file off the list and start it
        next_file = self.processing_queue.pop(0)
        self.import_and_run(next_file)

    # GLOBAL KEY HANDLER
    def on_global_key(self, key):
        try:
            if key == Key.f5:
                QtCore.QMetaObject.invokeMethod(self, "toggle_mirror", QtCore.Qt.QueuedConnection)
            if key == Key.f6:
                QtCore.QMetaObject.invokeMethod(self, "play_mirror", QtCore.Qt.QueuedConnection)
        except:
            pass

    # MIRROR RECORD TOGGLE
    @QtCore.Slot()
    def toggle_mirror(self):
        if self.proc_mirror.state() == QtCore.QProcess.NotRunning:
            if not MIRROR.exists():
                self.log("[app] mirror.py not found.")
                return
            self.log("[app] Starting mirror recording...")
            self.proc_mirror.start(sys.executable,[str(MIRROR)])
        else:
            self.log("[app] Stopping mirror recording...")
            self.proc_mirror.terminate()
            self.proc_mirror.waitForFinished(10000)
            self.log("[app] Mirror processing finished.")

    # MIRROR PLAY TOGGLE
    @QtCore.Slot()
    def play_mirror(self):
        mirror_file = APP_DIR / "mirror_ms.txt"
        if not mirror_file.exists():
            self.log("[app] mirror_ms.txt not found. Record first.")
            return

        if self.proc_play.state() != QtCore.QProcess.NotRunning:
            self.log("[app] Stopping mirror playback...")
            self.proc_play.kill()
            self.proc_play.waitForFinished(2000)
            return

        self.log("[app] Playing mirror output...")
        args =[
            str(PLAYER),
            "--both", str(mirror_file),
            "--left", str(mirror_file),
            "--mid", str(mirror_file),
            "--right", str(mirror_file),
            "--mode", "both",
            "--speed", "1.0"
        ]
        
        # --- NEW: Pass the fake-midi arg if checked ---
        if self.chkFakeMidi.isChecked():
            args.append("--fake-midi")
        # ----------------------------------------------
            
        self.proc_play.setWorkingDirectory(str(APP_DIR))
        self.proc_play.start(sys.executable, args)

        if not self.proc_play.waitForStarted(3000):
            self.log("[app] ERROR: Failed to start mirror player.")


    # ---------- UI helpers ----------
    def log(self, msg: str):
        self.logBox.appendPlainText(msg)

    def set_status(self, msg: str):
        self.statusLabel.setText(msg)

    def busy(self, on: bool, msg: str = ""):
        if on:
            self.progress.show()
            self.set_status(msg or "Working…")
        else:
            self.progress.hide()
            self.set_status(msg or "Ready.")
        self.update_buttons()

    def refresh_library(self):
        self.songList.clear()
        # Sorted alphanumerically by name (lowercase to ensure 'a' comes after 'B')
        songs = sorted(self.db["songs"], key=lambda s: s.get("name", "").lower())
        for s in songs:
            item = QtWidgets.QListWidgetItem(s["name"])
            item.setData(QtCore.Qt.UserRole, s["name"])
            self.songList.addItem(item)

    def get_selected_song(self):
        it = self.songList.currentItem()
        if not it:
            return None
        name = it.data(QtCore.Qt.UserRole)
        for s in self.db["songs"]:
            if s["name"] == name:
                return s
        return None

    def update_buttons(self):
        selected = self.get_selected_song()
        playing = self.proc_play.state() != QtCore.QProcess.NotRunning
        busy = (self.proc_audio.state() != QtCore.QProcess.NotRunning) or (self.proc_split.state() != QtCore.QProcess.NotRunning)

        self.btnPlay.setEnabled(bool(selected) and not busy and not playing)
        self.btnStop.setEnabled(playing)
        self.mode.setEnabled(bool(selected) and not busy and not playing)
        self.speed.setEnabled(bool(selected) and not busy and not playing)
        self.chorus.setEnabled(bool(selected) and not busy and not playing)
        
        # --- NEW ---
        self.chkFakeMidi.setEnabled(not playing) # Disable toggle while playing
        # -----------

    def toggle_always_on_top(self):
        on = self.chkTop.isChecked()
        self.setWindowFlag(QtCore.Qt.WindowStaysOnTopHint, on)
        self.show()

    def open_library_folder(self):
        QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(str(SONGS_DIR)))

    def open_song_folder(self):
        s = self.get_selected_song()
        if not s:
            return
        d = Path(s["dir"])
        if d.exists():
            QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(str(d)))

    def pick_mp3(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(
            self, "Select MP3", str(Path.home()), "MP3 Files (*.mp3)"
        )
        if path:
            self.queue_files([Path(path)])  # Route through queue!

    # ---------- pipeline: drop mp3 -> audioconv -> split ----------
    def import_and_run(self, mp3_path: Path):
        if not mp3_path.exists():
            self.process_next_in_queue()
            return

        if not AUDIOCONV.exists() or not SPLITTER.exists() or not PLAYER.exists():
            self.log("ERROR: Missing one of: audioconv.py, miditextsplit.py, autosplitplayer.py in the app folder.")
            self.process_next_in_queue()
            return

        song_dir = song_dir_for(mp3_path.stem)
        song_dir.mkdir(parents=True, exist_ok=True)
        self.pending_song_dir = song_dir

        dest_mp3 = song_dir / "input.mp3"
        shutil.copy2(mp3_path, dest_mp3)

        meta = {"name": song_dir.name, "source_mp3": str(mp3_path), "imported_at": now_iso()}
        (song_dir / "meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")

        self.log(f"[app] Imported: {mp3_path.name} → {dest_mp3}")
        
        q_len = len(self.processing_queue)
        q_msg = f" (+{q_len} waiting)" if q_len > 0 else ""
        self.busy(True, f"Step 1/2: Transcribing MP3 → MIDI…{q_msg}")

        self.run_process(self.proc_audio,[sys.executable, str(AUDIOCONV)], cwd=song_dir)

    def run_process(self, proc: QtCore.QProcess, args: list[str], cwd: Path):
        proc.setWorkingDirectory(str(cwd))
        proc.start(args[0], args[1:])
        if not proc.waitForStarted(3000):
            self.log(f"[app] ERROR: Failed to start: {' '.join(args)}")
            self.busy(False, "Failed to start process.")
            self.process_next_in_queue()

    def _drain(self, proc: QtCore.QProcess):
        data = proc.readAllStandardOutput().data().decode("utf-8", errors="replace")
        if data.strip():
            for line in data.splitlines():
                self.log(line)

    def on_audio_finished(self, exitCode: int, exitStatus: QtCore.QProcess.ExitStatus):
        if not self.pending_song_dir:
            self.busy(False, "Ready.")
            self.process_next_in_queue()
            return

        song_dir = self.pending_song_dir
        midi_path = song_dir / "transcribed.mid"

        if exitStatus != QtCore.QProcess.NormalExit or exitCode != 0:
            self.busy(False, "Transcription failed.")
            self.log(f"[app] audioconv.py failed (exitCode={exitCode}).")
            self.process_next_in_queue() # Move to next file on fail
            return

        if not midi_path.exists():
            self.busy(False, "Transcription finished but no transcribed.mid found.")
            self.log("[app] ERROR: transcribed.mid not created.")
            self.process_next_in_queue() # Move to next file on fail
            return

        q_len = len(self.processing_queue)
        q_msg = f" (+{q_len} waiting)" if q_len > 0 else ""

        self.log("[app] Step 1 done. Running split (MIDI → L/Mid/R/Both TXT)…")
        self.busy(True, f"Step 2/2: Splitting MIDI…{q_msg}")
        self.run_process(self.proc_split, [sys.executable, str(SPLITTER)], cwd=song_dir)

    def on_split_finished(self, exitCode: int, exitStatus: QtCore.QProcess.ExitStatus):
        song_dir = self.pending_song_dir
        self.pending_song_dir = None

        if exitStatus != QtCore.QProcess.NormalExit or exitCode != 0:
            self.busy(False, "Split failed.")
            self.log(f"[app] miditextsplit.py failed (exitCode={exitCode}).")
            self.process_next_in_queue() # Move to next file on fail
            return

        candidates = {
            "left":["transcribed_left_ms.txt", "transcribed_left.txt"],
            "mid":["transcribed_mid_ms.txt", "transcribed_mid.txt"],
            "right":["transcribed_right_ms.txt", "transcribed_right.txt"],
            "both":["transcribed_both_ms.txt", "transcribed_both.txt"],
        }

        found = {"left": "", "mid": "", "right": "", "both": ""}
        for mode, names in candidates.items():
            for name in names:
                p = song_dir / name
                if p.exists():
                    found[mode] = name
                    break

        entry = {
            "name": song_dir.name,
            "dir": str(song_dir),
            "mp3": "input.mp3",
            "midi": "transcribed.mid",
            "split_left": found["left"],
            "split_mid": found["mid"],
            "split_right": found["right"],
            "split_both": found["both"],
            "added_at": now_iso(),
        }

        self.db["songs"] =[s for s in self.db["songs"] if s["name"] != entry["name"]]
        self.db["songs"].append(entry)
        self.db["songs"].sort(key=lambda x: x["name"].lower())
        save_db(self.db)

        self.refresh_library()

        if not (entry["split_both"] and entry["split_left"] and entry["split_mid"] and entry["split_right"]):
            self.busy(False, f"Saved (missing some splits): {entry['name']}")
            self.log("[app] WARNING: Split finished but missing one or more output files (both/left/mid/right).")
        else:
            self.busy(False, f"Ready. Saved: {entry['name']}")
            self.log(f"[app] Saved to library: {entry['name']}")

        # CRITICAL: Trigger the next file in the queue!
        self.process_next_in_queue()

    # ---------- playback ----------
    def play_selected(self):
        s = self.get_selected_song()
        if not s:
            self.log("[app] Select a song first.")
            return
        if self.proc_play.state() != QtCore.QProcess.NotRunning:
            self.log("[app] Player already running.")
            return

        song_dir = Path(s["dir"])
        start_mode = self.mode.currentText()
        speed = float(self.speed.value())
        chorus_sec = float(self.chorus.value())

        both_rel = s.get("split_both", "")
        left_rel = s.get("split_left", "")
        mid_rel = s.get("split_mid", "")
        right_rel = s.get("split_right", "")

        if not (both_rel and left_rel and mid_rel and right_rel):
            self.log("[app] ERROR: Need split_both, split_left, split_mid, split_right for seamless switching. Re-run split.")
            return

        both_p = song_dir / both_rel
        left_p = song_dir / left_rel
        mid_p = song_dir / mid_rel
        right_p = song_dir / right_rel

        if not (both_p.exists() and left_p.exists() and mid_p.exists() and right_p.exists()):
            self.log("[app] ERROR: One or more split files are missing on disk. Re-run split.")
            return

        self.log(f"[app] Playing: {s['name']}  start_mode={start_mode}  speed={speed:.2f}")
        self.log("[app] Hotkeys: PageUp=LEFT  End=MID  PageDown=RIGHT  Home=BOTH  F4=CHORUS")
        self.log("[app] Numpad 1-8: Seek (10s, 40s, 60s, 80s, 120s, 150s, 180s, 200s) | Numpad 9: Rewind 20s")
        
        if chorus_sec > 0:
            self.log(f"[app] Chorus jump set to: {chorus_sec:.2f}s")
        else:
            self.log("[app] Chorus jump disabled (set Chorus (sec) > 0 to enable F4 jump).")

        self.set_status("Player running…")
        self.update_buttons()

        args =[
            str(PLAYER),
            "--both", both_rel,
            "--left", left_rel,
            "--mid", mid_rel,
            "--right", right_rel,
            "--mode", start_mode,
            "--speed", f"{speed:.2f}",
        ]

        # pass chorus jump to player (F4 will jump there)
        if chorus_sec > 0:
            args +=["--chorus", f"{chorus_sec:.2f}"]
            
        # --- NEW: Pass Fake MIDI arg ---
        if self.chkFakeMidi.isChecked():
            args.append("--fake-midi")
            self.log("[app] Fake MIDI Web Server started! You can safely disable QWERTY in Piano Rooms.")
        # -------------------------------

        self.proc_play.setWorkingDirectory(str(song_dir))
        self.proc_play.start(sys.executable, args)

    def stop_playback(self):
        if self.proc_play.state() == QtCore.QProcess.NotRunning:
            return
        self.proc_play.kill()
        self.proc_play.waitForFinished(2000)
        self.log("[app] Player stopped.")
        self.set_status("Ready.")
        self.update_buttons()

if __name__ == "__main__":
    app = QtWidgets.QApplication([])
    w = MainWindow()
    w.show()
    app.exec()
EOF

echo "[Harbor Oracle] Patch applied successfully."
