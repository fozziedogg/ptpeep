# Clip Group Sentinel Mapping — Research Notes

## What We're Trying to Do

When a clip group (compound clip) is placed on a Pro Tools timeline, PTPeep needs to show which audio clips are inside it. The constituent audio clips are not stored directly in the compound's pool entry — they're stored in a separate "sentinel" section. The hard problem is: **given a compound pool entry, find its sentinel section**.

---

## Key Binary Structures

### Block format
Every block: `5a [blockType u16le] [size u32le] [contentType u16le] [content]` — 9-byte header.

### XOR decode
Key = `data[0x13]`. Delta = solve `(i × 11) & 0xff == key` for i, negate. Apply per 4096-byte chunk using `table[chunk>>12 & 0xff]`.

### Relevant block types
| Type | Role |
|------|------|
| `0x1054` | Container. Two exist: first = **active** (timeline), second = **sentinel** container |
| `0x1052` | Section. One per track in active container; one per "group definition" in sentinel container |
| `0x104f` | Placement. In active sections: timeline positions. In sentinel sections: `tl ≥ SENT_ORIGIN` (relative offsets) |
| `0x1050` | Thin wrapper around 0x104f |
| `0x262b` | Compound pool entry (one per clip group definition) |
| `0x2629` | Audio pool entry (one per audio clip) |
| `0x2628` | Name block (4-byte LE length + UTF-8 string, followed by metadata) |
| `0x2523` | Creation metadata. bytes[37..38] = u16le creation counter |
| `0x2526` | Reference block. bytes[12..13] = first 2 bytes of corresponding 0x2523 UUID |

### SENT_ORIGIN
`1,000,000,000,000`. Any `0x104f` with `tl ≥ SENT_ORIGIN` is a sentinel placement; `relativeOffset = tl - SENT_ORIGIN`.

### b18 flag (byte 18 of 0x104f data)
- `0x00` → the placement's `ci` (bytes[2..3]) indexes the **audio pool** (0x2629) directly
- `0x01` → the placement's `ci` indexes the **compound pool** (0x262b) → recurse into that compound's sentinel

---

## What We Confirmed Works

### Fix 1: Audio pool lookup (committed, correct)
Sentinel `ci` values address the audio pool (`audioParents[ci]`) directly — NOT the combined audio+compound pool. This was the first bug fixed.

### Creation counter = sentinel ordinal (simple sessions only)
For simple sessions (ClipGroup_HexDiffGrouped\*.ptx), the creation counter in `0x2523` bytes[37..38] equals the sentinel section's ordinal within the sentinel container. Verified against sessions with empty groups, ungrouped clips, and multiple groups created in various orders.

---

## Where It Breaks Down

### Complex sessions (honeybunch_PeepTestD)
Four "split" compounds show the wrong clips:

| Compound ci | Name | Counter | Correct sentinel |
|-------------|------|---------|-----------------|
| 479 | 1 split.grp-06 | 747 | 82 |
| 480 | 2 split.grp-04 | 748 | 83 |
| 79  | 3 split.grp-03 | 179 | 84 |
| 80  | 4 split.grp-02 | 180 | 85 |

The correct sentinels (82–85) were found by **content-matching**: searching all 493 sentinel sections for the known-correct audio clip names (e.g. `04-05T01 - Diana & Homer MWS-MS-RX9Cnct_02-03`).

The high counter values (747, 748, 179, 180) suggest these compounds were **re-created** during editing (split, ungrouped and regrouped, etc.), so the counter reflects the latest creation event — but the sentinel was laid down at the original creation and its ordinal never changed.

---

## tIdx + Offset Pattern

### Definition
- **tIdx** = the ordinal of the active section (0x1052 within first 0x1054) that contains this compound's b18=0x01 timeline placement.
- For all 16 b18=0x01 compounds in PeepTestD: `sentinelOrdinal = tIdx + 72`

### Verified results (PeepTestD, activeSections=96, sentinels=493)
| ci | Name | tIdx | tIdx+72 | Correct? |
|----|------|------|---------|---------|
| 479 | 1 split.grp-06 | 10 | 82 | ✓ confirmed by content |
| 480 | 2 split.grp-04 | 11 | 83 | ✓ confirmed by content |
| 79  | 3 split.grp-03 | 12 | 84 | ✓ confirmed by content |
| 80  | 4 split.grp-02 | 13 | 85 | ✓ confirmed by content |
| 68  | dx 1.grp-39    | 92 | 164 | unverified |
| 155 | HOMER LOW      | 93 | 165 | unverified |
| 180 | deHushedBoom-07 | 94 | 166 | unverified |
| 234 | dx 6.grp-23    | 95 | 167 | unverified |
| ... (12 more, all consistent offset=72) | | | | |

Multiple compounds share the same tIdx (and therefore the same sentinel), which makes sense: they are different copies/versions of the same group definition placed on the same track.

### The "72" problem
The offset of 72 is consistent within PeepTestD but its structural meaning is unclear. It is **not**:
- `sentinels.count - activeSections.count` (493 - 96 = 397)
- The number of audio-only sentinels (438 audio-only, 7 compound-referencing, 48 empty)
- The index of the first compound sentinel (first compound-referencing sentinel is at ordinal 222)

It appears to be session-specific. Whether it's always the same value, or varies between sessions, is untested.

---

## What Is NOT Stored in the Compound

We searched exhaustively for the sentinel ordinal (82 for compound[479]) stored anywhere inside:
- `0x2628` (name + metadata block)
- `0x2523` (creation metadata, all fields)
- `0x2526` (reference block)
- Nested `0x262b` child

**None of these contain the sentinel ordinal.** The sentinel sections themselves have no name blocks (0 named sentinels out of 493).

The active timeline placement (`0x104f`, b18=0x01) for compound[479] and sentinel[82]'s placement share some common byte patterns (`03 fe ff` at bytes[15..17], nearly identical bytes[19..36]) but nothing that uniquely identifies the pairing.

---

## Data Visible in Each Structure

### Compound pool entry (0x262b), e.g. compound[479] '1 split.grp-06':
- **Name**: "1 split.grp-06"
- **UUID** (bytes[21..24] of 0x2523): `90 2a 37 0b`
- **Creation counter** (bytes[37..38] of 0x2523): 747
- **0x2526 ref**: `...90 2a` (matches UUID prefix)
- Post-name metadata in 0x2628: timestamp-like values, `ff ff ff ff` padding

### Sentinel section (0x1052), e.g. sentinel[82]:
- **0x104f placement**: ci=193 (audio pool index), tl=SENT_ORIGIN+66898, b18=0x00
- Section header bytes: `01 00 00 00 3f 01 00 00 00` (value 319 at bytes[4..7])
- No name, no UUID, no compound reference stored

---

## Open Questions

1. **What does the "72" offset represent structurally?** Is it always present? How to compute it for an arbitrary session?

2. **Is tIdx the right anchor?** We know `tIdx+72` works empirically for 16/16 compounds in PeepTestD. But can a compound appear on the timeline in multiple active sections (different tIdx values)?

3. **Do simple sessions also follow tIdx+offset?** If so, what is the offset there — is it 0, making `counter == tIdx`?

4. **Is there a stored pointer we haven't found?** The compound could reference the sentinel via some field we haven't decoded in the 0x2628 post-name metadata or in the session header.

5. **Why do sentinels 0–71 exist?** They're not compound-referencing and they predate the active-section range. Understanding what they represent might explain where the 72 comes from.

---

## Test Sessions

| File | Purpose |
|------|---------|
| `Tests/ClipGroup_HexDiffGrouped.ptx` | Baseline: simple groups, counter=sentOrd ✓ |
| `Tests/ClipGroup_HexDiffGroupedB.ptx` | Adds "Empty Group" (no audio, counter=0) |
| `Tests/ClipGroup_HexDiffGroupedC.ptx` | Adds second empty group "EmptyGroupB" |
| `Tests/ClipGroup_HexDiffGroupedD.ptx` | Adds "NewGroup6" with audio |
| `Tests/honeybunch_PeepTestD.ptx` | Complex session: counter theory fails for 4 splits |

---

## Current Code State

Branch: `appleevent-spot`, commit `80eafca`.

`PTXBlockDecoder.swift` uses `compoundCreationCounters[clipIdx] ?? clipIdx` as the sentinel ordinal. This is **wrong** for complex sessions. The fix requires implementing tIdx+offset or finding the true stored pointer.
