#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to library/test.py..."

cat << 'EOF' > /workspace/library/test.py
import json
from pathlib import Path

# Path to your library file
DB_PATH = Path("library/library.json")

def sort_library():
    if not DB_PATH.exists():
        print("Error: library.json not found.")
        return

    # 1. Load the current data
    with open(DB_PATH, "r", encoding="utf-8") as f:
        db = json.load(f)

    # 2. Sort the list by the "name" key
    # x['name'].lower() ensures A-Z regardless of Uppercase or Lowercase
    db["songs"].sort(key=lambda x: x["name"].lower())

    # 3. Save the sorted data back to the file
    with open(DB_PATH, "w", encoding="utf-8") as f:
        json.dump(db, f, indent=2, ensure_ascii=False)

    print(f"Successfully sorted {len(db['songs'])} songs alphanumerically.")

if __name__ == "__main__":
    sort_library()
EOF

echo "[Harbor Oracle] Patch applied successfully."
