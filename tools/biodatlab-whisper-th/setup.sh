#!/usr/bin/env bash
# Convert biodatlab/whisper-th-large-v3 from HuggingFace transformers
# format to WhisperKit-compatible CoreML format. Architecture matches
# OpenAI's standard whisper-large-v3 (32-layer decoder, full attention),
# only the weights are fine-tuned for Thai — so whisperkittools converts
# it cleanly without the architectural mismatches that broke the distilled
# variant we tried first.
#
# The Meeting app's `LocalProvider` looks for the converted artifacts in:
#
#   ~/Library/Application Support/dev.fluke.meeting/Models/custom/
#       biodatlab-whisper-th-large-v3/
#
# Run this script once. Re-running is safe — conversion is skipped if the
# output already exists. Delete the output folder to force a rebuild.
#
# Time + space: ~15–20 min on M-series, ~3 GB on disk (PyTorch checkpoint
# from HF, then the generated CoreML mlmodelc bundles).

set -euo pipefail

cd "$(dirname "$0")"

HF_REPO="biodatlab/whisper-th-large-v3"
APP_MODELS="$HOME/Library/Application Support/dev.fluke.meeting/Models/custom"
OUT_DIR="$APP_MODELS/biodatlab-whisper-th-large-v3"
WORK_DIR="./_workspace"

PYTHON_BIN="${PYTHON_BIN:-python3.11}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "Need $PYTHON_BIN. Install via: brew install python@3.11" >&2
    exit 1
fi

if [ -f "$OUT_DIR/config.json" ]; then
    echo "Already converted at:"
    echo "    $OUT_DIR"
    echo "Delete that folder to re-convert."
    exit 0
fi

# whisperkittools is not on PyPI — install from source. Pinned to a checkout
# so reruns reproduce.
if [ ! -d whisperkittools ]; then
    echo "Cloning whisperkittools…"
    git clone --depth 1 https://github.com/argmaxinc/whisperkittools.git
fi

if [ ! -d venv ]; then
    "$PYTHON_BIN" -m venv venv
fi

# shellcheck disable=SC1091
source venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -e ./whisperkittools
pip install --quiet huggingface_hub

mkdir -p "$WORK_DIR"

# whisperkit-generate-model:
#   - downloads the HF checkpoint
#   - traces encoder/decoder for Apple Neural Engine
#   - writes <output-dir>/<repo-with-slashes-as-underscores>/{
#         AudioEncoder.mlmodelc, TextDecoder.mlmodelc,
#         MelSpectrogram.mlmodelc, *.mlcomputeplan.json
#     }
# The text artifacts (config.json, tokenizer.json, etc.) it does NOT emit;
# we pull them straight from HF below.
echo "Converting $HF_REPO → CoreML (15-20 min)…"
whisperkit-generate-model \
    --model-version "$HF_REPO" \
    --output-dir "$WORK_DIR"

GENERATED_DIR="$(find "$WORK_DIR" -mindepth 1 -maxdepth 2 -type d -name "*whisper-th-large-v3*" -not -name "*.mlmodelc" | head -n1)"
if [ -z "$GENERATED_DIR" ] \
   || [ ! -d "$GENERATED_DIR/AudioEncoder.mlmodelc" ] \
   || [ ! -d "$GENERATED_DIR/TextDecoder.mlmodelc" ] \
   || [ ! -d "$GENERATED_DIR/MelSpectrogram.mlmodelc" ]; then
    echo "ERROR: conversion finished but mlmodelc bundles aren't all present." >&2
    echo "Inspect $WORK_DIR for what whisperkit-generate-model produced." >&2
    exit 1
fi

echo "Downloading tokenizer + config from ${HF_REPO}…"
python - "$HF_REPO" "$GENERATED_DIR" <<'PY'
import sys
from huggingface_hub import hf_hub_download
repo, dest = sys.argv[1], sys.argv[2]
files = [
    "config.json",
    "generation_config.json",
    "preprocessor_config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "special_tokens_map.json",
    "vocab.json",
    "merges.txt",
    "normalizer.json",
    "added_tokens.json",
]
for f in files:
    try:
        hf_hub_download(repo_id=repo, filename=f, local_dir=dest)
        print(f"  + {f}")
    except Exception as e:
        print(f"  - {f} (skipped: {type(e).__name__})")
PY

mkdir -p "$APP_MODELS"
rm -rf "$OUT_DIR"
mv "$GENERATED_DIR" "$OUT_DIR"
rm -rf "$WORK_DIR"

echo
echo "Done. Model converted at:"
echo "    $OUT_DIR"
echo
echo "Open Meeting → Settings → Recording → set Whisper model to"
echo "  'Whisper TH Large v3 (Thai-tuned)' to use it."
