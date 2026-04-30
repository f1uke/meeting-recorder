# Roadmap

Future work that is not yet scheduled. Move items into a branch / PR when picked up.

## Cross-meeting speaker identity

**Problem.** Today `speaker_0`, `speaker_1`, … are scoped to a single diarization run. SpeakerKit clusters embeddings inside one `output.wav` and labels them by first-seen order, so `speaker_0` in meeting A and `speaker_0` in meeting B are unrelated. Users have to rename speakers per-meeting via `customSpeakerNames` in `library.json`.

**Goal.** Recognize the same person across meetings so renaming once propagates, and the Library can show "person X attended N meetings".

**Sketch.**
1. Persist a centroid embedding per identified speaker in a Library-level store (e.g. `~/Library/Application Support/dev.fluke.meeting/speakers.json` or a small SQLite). Each identity = `{id, displayName, centroid: [Float], sampleCount, sourceMeetingIDs}`.
2. After SpeakerKit clustering on a new meeting, take each cluster's mean embedding and match against the store via cosine distance with a conservative threshold (start ~0.5 — tighter than pyannote's 0.6 cluster threshold to avoid false merges across different voices).
3. On match: reuse existing identity ID and update the centroid (running mean weighted by sampleCount). On miss: mint a new identity. Update `MergedTranscript` so `speaker` field references the global ID, with the per-meeting `speaker_N` kept as a fallback.
4. UX in Transcript Viewer's Speakers card: show match confidence, let user confirm / split / merge identities. Renames flow back to the global store, not just `library.json`.
5. Library sidebar: new "People" group listing identities with meeting counts.

**Open questions.**
- Where does SpeakerKit expose per-cluster mean embeddings? May need to compute ourselves from segment-level embeddings if not surfaced.
- Privacy / reset story — embeddings are biometric-ish; need an "Forget person" action and a global wipe.
- Migration: existing meetings have `speaker_N` IDs only. Lazy-backfill on next open, or one-time migration sweep.

**Captured.** 2026-04-30 — flagged during discussion of why Speaker 11 in meeting A ≠ Speaker 11 in meeting B.
