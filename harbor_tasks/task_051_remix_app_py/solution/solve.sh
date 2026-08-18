#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to remix_app.py..."

cat << 'EOF' > /workspace/remix_app.py
# remix_app.py
import json
import re
import shutil
import sys
from pathlib import Path
from datetime import datetime

from PySide6 import QtCore, QtGui, QtWidgets

# Re-use paths from your main app structure
APP_DIR = Path(__file__).resolve().parent
AUDIOCONV = APP_DIR / "audioconv.py"
SPLITTER = APP_DIR / "miditextsplit.py"
REMIXER = APP_DIR / "midi_remixer.py"

LIB_DIR = APP_DIR / "library"
SONGS_DIR = LIB_DIR / "songs"
DB_PATH = LIB_DIR / "library.json"

def safe_name(name: str) -> str:
    name = re.sub(r"[^\w\s\-()]+", "", name, flags=re.UNICODE)
    name = re.sub(r"\s+", " ", name).strip()
    return name[:20] if name else "Song" # Shrink to 20 chars max per song

def now_iso():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")

class SingleDropArea(QtWidgets.QFrame):
    fileDropped = QtCore.Signal(Path)

    def __init__(self, title):
        super().__init__()
        self.setAcceptDrops(True)
        self.setFrameStyle(QtWidgets.QFrame.StyledPanel | QtWidgets.QFrame.Raised)
        self.setMinimumHeight(150)
        
        self.file_path = None

        layout = QtWidgets.QVBoxLayout(self)
        self.title_label = QtWidgets.QLabel(f"<b>{title}</b>")
        self.title_label.setAlignment(QtCore.Qt.AlignCenter)
        
        self.status_label = QtWidgets.QLabel("Drag 1 MP3 Here")
        self.status_label.setAlignment(QtCore.Qt.AlignCenter)
        self.status_label.setStyleSheet("color: gray;")
        
        layout.addWidget(self.title_label)
        layout.addWidget(self.status_label)

    def dragEnterEvent(self, e: QtGui.QDragEnterEvent):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e: QtGui.QDropEvent):
        for url in e.mimeData().urls():
            p = Path(url.toLocalFile())
            if p.suffix.lower() == ".mp3":
                self.file_path = p
                self.status_label.setText(f"Loaded:\n{p.name}")
                self.status_label.setStyleSheet("color: #4CAF50; font-weight: bold;")
                self.fileDropped.emit(p)
                break # Only accept the first one

class RemixWindow(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("AutoPiano - Intelligent Remixer")
        self.resize(900, 500)

        self.proc = QtCore.QProcess(self)
        self.proc.setProcessChannelMode(QtCore.QProcess.MergedChannels)
        self.proc.readyReadStandardOutput.connect(self._drain_log)
        self.proc.finished.connect(self._on_process_finished)

        self.workflow_state = 0
        self.temp_dir = APP_DIR / "temp_remix_build"
        self.final_song_dir = None
        self.remix_title = ""

        # UI Setup
        central = QtWidgets.QWidget()
        self.setCentralWidget(central)
        root = QtWidgets.QVBoxLayout(central)
        
        header = QtWidgets.QLabel("Create a Masterpiece Remix (Requires 3 MP3s)")
        font = header.font()
        font.setPointSize(14)
        font.setBold(True)
        header.setFont(font)
        header.setAlignment(QtCore.Qt.AlignCenter)
        root.addWidget(header)

        # Drop Zones
        zones_layout = QtWidgets.QHBoxLayout()
        self.drop1 = SingleDropArea("Song 1 (Sets Target Key)")
        self.drop2 = SingleDropArea("Song 2")
        self.drop3 = SingleDropArea("Song 3")
        
        zones_layout.addWidget(self.drop1)
        zones_layout.addWidget(self.drop2)
        zones_layout.addWidget(self.drop3)
        root.addLayout(zones_layout)

        # Controls
        controls = QtWidgets.QHBoxLayout()
        self.btnGenerate = QtWidgets.QPushButton("🌟 Generate Masterpiece Remix 🌟")
        self.btnGenerate.setMinimumHeight(40)
        self.btnGenerate.clicked.connect(self.start_remix_workflow)
        controls.addWidget(self.btnGenerate)
        root.addLayout(controls)

        self.statusLabel = QtWidgets.QLabel("Ready.")
        self.statusLabel.setAlignment(QtCore.Qt.AlignCenter)
        root.addWidget(self.statusLabel)

        self.progress = QtWidgets.QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.hide()
        root.addWidget(self.progress)

        root.addWidget(QtWidgets.QLabel("Console Log:"))
        self.logBox = QtWidgets.QPlainTextEdit()
        self.logBox.setReadOnly(True)
        root.addWidget(self.logBox)

    def log(self, msg):
        self.logBox.appendPlainText(msg.strip())
        
    def _drain_log(self):
        data = self.proc.readAllStandardOutput().data().decode("utf-8", errors="replace")
        if data.strip():
            for line in data.splitlines():
                self.log(line)

    def update_status(self, text, busy=False):
        self.statusLabel.setText(text)
        if busy:
            self.progress.show()
            self.btnGenerate.setEnabled(False)
        else:
            self.progress.hide()
            self.btnGenerate.setEnabled(True)

    def start_remix_workflow(self):
        p1 = self.drop1.file_path
        p2 = self.drop2.file_path
        p3 = self.drop3.file_path

        if not (p1 and p2 and p3):
            QtWidgets.QMessageBox.warning(self, "Missing Files", "Please drop an MP3 into all 3 zones!")
            return
            
        # Format the final name: "REMIX: A + B + C"
        n1 = safe_name(p1.stem)
        n2 = safe_name(p2.stem)
        n3 = safe_name(p3.stem)
        self.remix_title = f"REMIX - {n1} + {n2} + {n3}"
        
        self.log("=== STARTING REMIX WORKFLOW ===")
        self.log(f"Final Title will be: {self.remix_title}")
        
        # Setup Temp Dir
        if self.temp_dir.exists():
            shutil.rmtree(self.temp_dir)
        self.temp_dir.mkdir()
        
        shutil.copy2(p1, self.temp_dir / "song1.mp3")
        shutil.copy2(p2, self.temp_dir / "song2.mp3")
        shutil.copy2(p3, self.temp_dir / "song3.mp3")

        # Kick off the state machine
        self.workflow_state = 1
        self.run_current_state()

    def run_current_state(self):
        if self.workflow_state == 1:
            self.update_status("Step 1/5: Transcribing Song 1 to MIDI...", busy=True)
            self.proc.setWorkingDirectory(str(self.temp_dir))
            self.proc.start(sys.executable, [str(AUDIOCONV), "--in", "song1.mp3", "--out", "song1.mid"])

        elif self.workflow_state == 2:
            self.update_status("Step 2/5: Transcribing Song 2 to MIDI...", busy=True)
            self.proc.start(sys.executable, [str(AUDIOCONV), "--in", "song2.mp3", "--out", "song2.mid"])

        elif self.workflow_state == 3:
            self.update_status("Step 3/5: Transcribing Song 3 to MIDI...", busy=True)
            self.proc.start(sys.executable, [str(AUDIOCONV), "--in", "song3.mp3", "--out", "song3.mid"])

        elif self.workflow_state == 4:
            self.update_status("Step 4/5: Synthesizing Intelligent Remix (Harmonic Alignment & Glissandos)...", busy=True)
            self.proc.setWorkingDirectory(str(APP_DIR)) # Run from root
            self.proc.start(sys.executable, [
                str(REMIXER),
                str(self.temp_dir / "song1.mid"),
                str(self.temp_dir / "song2.mid"),
                str(self.temp_dir / "song3.mid"),
                str(self.temp_dir / "final_remix.mid")
            ])

        elif self.workflow_state == 5:
            self.update_status("Step 5/5: Splitting Master Remix into L/Mid/R Text Files...", busy=True)
            
            # First, move to final library folder
            self.final_song_dir = SONGS_DIR / self.remix_title
            
            # Handle duplicates
            counter = 2
            while self.final_song_dir.exists():
                self.final_song_dir = SONGS_DIR / f"{self.remix_title} ({counter})"
                counter += 1
                
            self.final_song_dir.mkdir(parents=True, exist_ok=True)
            
            # Copy the final MIDI there
            final_midi = self.final_song_dir / "transcribed.mid"
            shutil.copy2(self.temp_dir / "final_remix.mid", final_midi)
            
            # Run Splitter inside the final dir
            self.proc.setWorkingDirectory(str(self.final_song_dir))
            self.proc.start(sys.executable, [str(SPLITTER)])

        elif self.workflow_state == 6:
            self.update_status("Finalizing and updating library database...", busy=True)
            self.update_library_json()
            
            # Cleanup
            if self.temp_dir.exists():
                shutil.rmtree(self.temp_dir)
                
            self.update_status(f"🎉 Success! '{self.final_song_dir.name}' has been added to your Library.")
            QtWidgets.QMessageBox.information(self, "Remix Complete", 
                "Your masterpiece is ready! You can now open the main app to play it.")
            self.workflow_state = 0

    def _on_process_finished(self, exitCode, exitStatus):
        if exitCode != 0:
            self.update_status("❌ Error occurred during processing. See log.")
            self.log(f"PROCESS FAILED at state {self.workflow_state}. Exit code: {exitCode}")
            self.workflow_state = 0
            return
            
        self.workflow_state += 1
        self.run_current_state()

    def update_library_json(self):
        # 1. Create the meta.json that was missing
        meta = {
            "name": self.final_song_dir.name,
            "source_mp3": "Remix Synthesis",
            "imported_at": now_iso(),
            "is_remix": True
        }
        (self.final_song_dir / "meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")

        # 2. Update the library.json
        if not DB_PATH.exists():
            db = {"songs": []}
        else:
            db = json.loads(DB_PATH.read_text(encoding="utf-8"))
            
        # IMPORTANT: These filenames must match your miditextsplit.py EXACTLY
        # Your miditextsplit.py uses "transcribed_both.txt" (not _ms.txt)
        entry = {
            "name": self.final_song_dir.name,
            "dir": str(self.final_song_dir),
            "mp3": "", 
            "midi": "transcribed.mid",
            "split_left": "transcribed_left.txt",
            "split_mid": "transcribed_mid.txt",
            "split_right": "transcribed_right.txt",
            "split_both": "transcribed_both.txt",
            "added_at": now_iso(),
        }
        
        # Remove old entry if same name exists
        db["songs"] = [s for s in db["songs"] if s["name"] != entry["name"]]
        db["songs"].append(entry)
        db["songs"].sort(key=lambda x: x["name"].lower())
        
        DB_PATH.write_text(json.dumps(db, indent=2), encoding="utf-8")
        self.log("[app] meta.json created and library.json updated.")

if __name__ == "__main__":
    app = QtWidgets.QApplication(sys.argv)
    w = RemixWindow()
    w.show()
    sys.exit(app.exec())
EOF

echo "[Harbor Oracle] Patch applied successfully."
