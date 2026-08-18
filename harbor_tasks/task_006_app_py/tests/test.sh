#!/bin/bash
set -e
echo "[Harbor Verifier] Running test suite..."
python -m pytest .
