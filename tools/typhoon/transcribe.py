"""Typhoon ASR transcription wrapper — chunks long audio, real word timestamps.

Follows the official typhoon-asr inference pattern from
https://github.com/scb-10x/typhoon-asr (notebook examples) but adds:

  * 60-second chunking so memory stays bounded on long meetings.
    The PyPI package and reference notebook both load the whole file into a
    single tensor and run Conformer attention over it, which on a 20-minute
    file balloons RAM past 15 GB. 60s chunks fit in ~2-3 GB.
  * `timestamps=True` so we read real word-level start/end times from the
    RNNT decoder via `hyp.timestamp['word']` (instead of the package's
    fake "audio_duration / word_count" estimate).

Usage:
    python transcribe.py <audio_file>

Output (stdout): JSON document. Progress logs go to stderr.
"""

from __future__ import annotations

import gc
import json
import os
import sys
import tempfile
import time
from pathlib import Path

import librosa
import nemo.collections.asr as nemo_asr
import soundfile as sf
import torch

CHUNK_SECONDS = 60
TARGET_SR = 16_000
MODEL_NAME = "scb10x/typhoon-asr-realtime"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        log("usage: transcribe.py <audio>")
        return 2

    audio_path = Path(argv[1])
    if not audio_path.exists():
        print(json.dumps({"error": f"file not found: {audio_path}"}))
        return 1

    device = "cpu"  # NeMo + MPS is flaky for RNNT on Apple Silicon; CPU is reliable
    log(f"loading model {MODEL_NAME} on {device}...")
    t0 = time.time()
    model = nemo_asr.models.ASRModel.from_pretrained(
        model_name=MODEL_NAME, map_location=device
    )
    log(f"model ready in {time.time() - t0:.1f}s")

    log(f"loading audio: {audio_path}")
    y, sr = librosa.load(str(audio_path), sr=TARGET_SR, mono=True)
    duration = len(y) / sr
    log(f"audio: {duration:.1f}s @ {sr}Hz mono ({len(y) * 4 / 1e6:.1f}MB)")

    # Peak-normalize once (matches Typhoon's reference prepare_audio()).
    peak = float(max(abs(y.max()), abs(y.min())))
    if peak > 1e-8:
        y = y / peak

    chunk_samples = CHUNK_SECONDS * sr
    num_chunks = (len(y) + chunk_samples - 1) // chunk_samples
    log(f"processing {num_chunks} chunks of {CHUNK_SECONDS}s")

    all_words: list[dict] = []
    all_segments: list[dict] = []
    text_parts: list[str] = []
    start_total = time.time()

    with torch.inference_mode():
        for i in range(num_chunks):
            cstart = i * chunk_samples
            cend = min(cstart + chunk_samples, len(y))
            chunk = y[cstart:cend]
            if len(chunk) < sr // 2:  # skip < 0.5 s tail
                continue

            cstart_s = cstart / sr
            cend_s = cend / sr

            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                tmp_path = tmp.name
            try:
                sf.write(tmp_path, chunk, sr)
                hyps = model.transcribe(audio=[tmp_path], timestamps=True)
            finally:
                if os.path.exists(tmp_path):
                    os.unlink(tmp_path)

            text = ""
            words: list[dict] = []
            segs: list[dict] = []
            if hyps:
                hyp = hyps[0]
                text = (hyp.text or "").strip() if hasattr(hyp, "text") else ""
                ts = getattr(hyp, "timestamp", None) or {}
                # Word-level — the canonical timing we want for diarization alignment.
                for w in ts.get("word", []) or []:
                    words.append(
                        {
                            "word": w.get("word", ""),
                            "start": float(w.get("start", 0)) + cstart_s,
                            "end": float(w.get("end", 0)) + cstart_s,
                        }
                    )
                # Segment-level — coarser, but useful for SRT/markdown export.
                for s in ts.get("segment", []) or []:
                    seg_text = s.get("segment", "")
                    if seg_text:
                        segs.append(
                            {
                                "text": seg_text,
                                "start": float(s.get("start", 0)) + cstart_s,
                                "end": float(s.get("end", 0)) + cstart_s,
                            }
                        )

            if text:
                text_parts.append(text)
            all_words.extend(words)
            all_segments.extend(segs)

            elapsed = time.time() - start_total
            log(
                f"  chunk {i + 1}/{num_chunks} ({cstart_s:6.1f}–{cend_s:6.1f}s) "
                f"[{elapsed:5.1f}s] words={len(words)} segs={len(segs)} {text[:60]!r}"
            )

            gc.collect()

    payload = {
        "text": " ".join(text_parts),
        "duration": duration,
        "words": all_words,
        "segments": all_segments,
        "processing_time": time.time() - start_total,
        "chunk_seconds": CHUNK_SECONDS,
        "model": MODEL_NAME,
    }
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
