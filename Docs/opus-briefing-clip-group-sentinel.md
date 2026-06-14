# Opus Briefing: Clip Group Sentinel Mapping

## What PTpeep Is

A native macOS app that parses Pro Tools `.ptx` session files (binary format) without opening Pro Tools. One feature is displaying clip groups (compound clips) on a visual timeline, showing which audio clips are inside each group.

---

## The Core Problem

When a clip group is placed on the Pro Tools timeline, its constituent audio clips are stored in a separate "sentinel" section of the binary. To show the right clips inside a group, we need to map: **compound pool entry → sentinel section**.

### Binary Structure (relevant parts)

Every block: `5a [blockType u16le] [size u32le] [contentType u16le] [content]` — 9-byte header.

| Block type | Role |
|------------|------|
| `0x1054` | Container. Two exist: first = **active** (timeline placements), second = **sentinel** container |
| `0x1052` | Section. One per track in active container; one per "group definition" in sentinel container |
| `0x104f` | Placement. In active sections: real timeline positions. In sentinel sections: `tl ≥ 1,000,000,000,000` (relative offsets) |
| `0x262b` | Compound pool entry (one per clip group definition) |
| `0x2629` | Audio pool entry (one per audio clip) |
| `0x2523` | Creation metadata. bytes[37..38] = u16le creation counter |

### Sentinel lookup in current code

`PTXBlockDecoder.swift` currently uses `compoundCreationCounters[clipIdx] ?? clipIdx` as the sentinel ordinal — i.e., the creation counter stored in the compound's `0x2523` block.

---

## What Works and What Doesn't

### Simple sessions (fresh, no heavy editing)
`counter == sentinelOrdinal` — verified correct. Code works.

### Complex sessions (heavily edited, split/regroup operations)
Counters are **stale** — they reflect the latest re-creation event, not the original sentinel ordinal. Example from `honeybunch_PeepTestD.ptx`:

| Compound | Name | Counter (stale) | Correct sentinel |
|----------|------|-----------------|-----------------|
| ci=479 | 1 split.grp-06 | 747 | 82 |
| ci=480 | 2 split.grp-04 | 748 | 83 |
| ci=79  | 3 split.grp-03 | 179 | 84 |
| ci=80  | 4 split.grp-02 | 180 | 85 |

Correct sentinels were found by content-matching (searching for known clip names inside sentinel sections).

### The tIdx+offset pattern
For PeepTestD: `sentinelOrdinal = tIdx + 72`, where `tIdx` = ordinal of the active track section containing the compound's b18=0x01 timeline placement. Consistent across all 16 b18=0x01 compounds. But:

- The offset (72) is **session-specific** — its structural meaning is unknown
- `sentinels.count - activeSections.count` = 493 - 96 = 397 (not 72)
- First compound-referencing sentinel is at ordinal 222 (not 72)
- Sentinels 0–71 exist but are not compound-referencing

### Exhaustive search for a stored pointer
We searched every field inside `0x262b`, `0x2628`, `0x2523`, `0x2526`, and nested blocks. **The sentinel ordinal is not stored anywhere findable in the compound's pool entry.** The sentinel sections themselves have no name blocks, no UUIDs, no compound references.

---

## Where We Are

We've exhausted structural approaches. The offset is not stored in the file in any field we can find. The current code (counter as sentinel ordinal) is the best purely-structural approximation available.

---

## The Three Options

### Option 1: Use counter as-is (status quo)
Already implemented and bounds-checked — OOB counters silently show empty constituents. Correct for simple/common sessions, wrong for heavily-edited ones. No user-facing change needed.

### Option 2: Calibration input
User provides one (compound name, clip-inside-it) pair. We find that compound's sentinel by content-match, compute the offset, store it per-session file path. Works for complex sessions if user is willing to provide one data point.

### Option 3: PTSL when available
If Pro Tools is running with the session open, query PT directly via gRPC (localhost:31416) for clip group contents. PT already knows the answer. This is the ground-truth approach when available, but requires PT to be running.

---

## The Ask

We'd like your read on which option (or combination) makes the most sense given:

1. The target user is a professional sound editor/mixer who likely has PT open when they also want to inspect the session
2. The app already has PTSL plumbing (`PTSLSessionInfo.swift`) for sample rate, bit depth, etc. — GetClipList / GetPlaylistElements exist in PTSL but aren't wired up yet
3. The calibration approach adds friction but works offline

Specifically: is PTSL the right primary path here, with counter-as-fallback for when PT isn't open? And if so, do you see any concerns with that architecture given that the app is also a Quick Look extension (which runs in a sandboxed process without network access)?

---

## Relevant Files

- `PTpeek/Parser/PTXBlockDecoder.swift` — main binary parser, sentinel expansion lives here
- `PTpeek/ProTools/PTSLSessionInfo.swift` — existing PTSL/gRPC integration
- `Docs/clip-group-sentinel-mapping.md` — full research notes with hex-level detail
- `Tests/ClipGroup_*.ptx` — simple test sessions
- `Tests/honeybunch_PeepTestD.ptx` — complex session where counter fails
