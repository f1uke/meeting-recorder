#!/usr/bin/env bash
# Sets up a Python 3.11 virtualenv with Typhoon ASR for the Meeting app.
# The Swift app spawns transcribe.py via this venv's python; Typhoon's
# NeMo + PyTorch dependency tree is large (≈1.5–2 GB on disk) so this is
# kept out of the app bundle and lives at tools/typhoon/venv/.

set -euo pipefail

cd "$(dirname "$0")"

PYTHON_BIN="${PYTHON_BIN:-python3.11}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "Need $PYTHON_BIN. Install via: brew install python@3.11" >&2
    exit 1
fi

if [ ! -d venv ]; then
    "$PYTHON_BIN" -m venv venv
fi

# shellcheck disable=SC1091
source venv/bin/activate
pip install --quiet --upgrade pip
pip install typhoon-asr

echo "Typhoon ASR ready. Try:"
echo "    venv/bin/python transcribe.py /path/to/audio.wav --with-timestamps"
