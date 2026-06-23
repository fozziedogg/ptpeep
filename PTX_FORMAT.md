# The Pro Tools `.ptx` Binary Format — Reverse-Engineering Notes

> Everything we've worked out about the Pro Tools session (`.ptx`) on-disk format by
> reverse-engineering it for **PTpeek** (a read-only session inspector). This is **unofficial** —
> derived from observation, not Avid documentation. It's accurate enough to extract tracks,
> clips, clip groups, video, routing, plugins, markers, and session parameters **without Pro
> Tools running**, but there are gaps and almost certainly version-specific quirks. Offsets are
> given the way our parser uses them; verify against your own files.

Tested mostly against PT 2022.12–2025.x sessions (format byte `0x05`). Binary parsing works for
PT 10+ era files; older (`0x01`) files use a different obfuscation constant (noted below).

A note on conventions: a **block** starts with a `0x5a` marker followed by a 9-byte header; we
call the byte immediately after that header **`dataOffset`**, and field offsets like `[+7]` are
relative to `dataOffset` unless stated otherwise. All multi-byte integers are **little-endian**
unless the big-endian flag (below) is set — which we've never seen in practice.

---

## 1. File header & obfuscation

The first 4 KB (`0x0000`–`0x0FFF`) is plaintext; the rest is lightly obfuscated with a
position-dependent XOR.

| Offset | Meaning |
|--------|---------|
| `0x11` | Endianness flag. `0` = little-endian (universal in practice); non-zero = big-endian headers. |
| `0x12` | Format/version byte. `0x05` = PT 10+; `0x01` = PT 5–9. |
| `0x13` | XOR seed byte. |

### The XOR scheme (PT 10+)

It is **not** a flat XOR — the key changes every 4096-byte page, and the per-page key comes from
a multiply table seeded by byte `0x13`:

1. Find `delta`: the value such that a 256-entry table `table[i] = (i * 11) & 0xFF` is built, then
   the seed maps to a page key. Concretely, PT 10+ uses **multiplier 11, negative=true**; PT 5–9
   uses **multiplier 53, negative=false**. (`delta = genXorDelta(seed, mul, negative)` — find `i`
   where `(i*mul)&0xFF == seed`, then `negative ? 256-i : i`.)
2. Build `table[i] = (i * delta) & 0xFF` for `i` in `0..255`.
3. For each 4096-byte page starting at `chunk` (page 0 = bytes `0x0000`–`0x0FFF`):
   `xorByte = table[(chunk >> 12) & 0xFF]`, then `decoded[i] = raw[i] ^ xorByte`.
4. Page 0's key is `0`, so the first 4096 bytes are effectively plaintext.

After decoding the whole file you can scan for blocks.

---

## 2. Block structure

Everything past the header is a flat stream of length-prefixed **blocks**, each introduced by a
`0x5a` marker:

```
[0x5a] [blockType: u16] [blockSize: u32] [contentType: u16]  <-- 9-byte header
[ ...blockSize bytes of content... ]                          <-- starts at dataOffset
```

- `blockSize` is the **content** size (excludes the 9-byte header).
- `contentType` (the u16 at header offset +7) is the value we key everything off — the "block
  type codes" below are content types.
- Blocks **nest**: a parent block's content contains child blocks (each with its own `0x5a`).

### Scanning

Start at file offset `0x1f` and walk byte-by-byte. At each position, if the byte is `0x5a`, read
the prospective `blockSize`/`contentType`; accept if `0 < size < 50,000,000` and the block fits in
the file. Record `(contentType, dataOffset = i+9, dataSize = size)`. Advance by **1 byte** (not
`size`) so nested child blocks are also discovered. A real session yields ~2000 blocks.

---

## 3. Block type catalog (content types)

The codes we decode (there are many more we ignore):

| Code | Meaning |
|------|---------|
| `0x1001` | Per-audio-file descriptor: sample rate, channel count, bit depth, length in samples |
| `0x1004` → `0x103a` | Audio file list (parent → entries) |
| `0x1015` → `0x1014` | Audio track list |
| `0x1017` | Plugin descriptor (AAX display name, OSType codes, bundle id) |
| `0x1028` | Session params: sample rate, bit depth, TC format, session start |
| `0x102d` → `0x2619` | Mixer strip (name + UID); parent of per-track plugin state |
| `0x1054` → `0x1052` → `0x1050` → `0x104f` | Track playlists → per-track section → entry wrapper → clip reference |
| `0x1055` → `0x104f` | Video playlist → video clip references |
| `0x2077` | Memory location (marker): number, name, sample position |
| `0x210b` | Track display-name → 8-byte UID mapping |
| `0x210c` | Folder-membership hierarchy (depth-first tree) |
| `0x2519` → `0x251a` | Track display info (type, channel format, visibility, active, color) |
| `0x2423` | Clip-group definition: group id (GID) + name |
| `0x2425` | Per-GID member count (incl. phantom slots from deleted members) |
| `0x2523` → `0x2526` | Clip-group constituent ("sentinel") + its 14-byte child |
| `0x2629` → `0x2628` | Audio clip pool (parent → clip entries) |
| `0x262b` → `0x2628` | Compound/group clip pool (+ trailing trail bytes) |
| `0x262d` → `0x2628` | Video clip pool |
| `0x261b` → `0x260d` → `0x260e` | Per-track routing container → routing parent → output/send path |
| `0x2627` → `0x2616`/`0x2625` | Per-track plugin slots (occupied / empty) |

> The hex codes cluster by subsystem: `0x10xx` = files/tracks/playlists, `0x20xx` = display/markers,
> `0x25xx`/`0x26xx` = clips/groups/routing/plugins, `0x21xx` = track identity/folders.

---

## 4. Session parameters

### `0x1001` — audio file descriptor (also the easiest sample-rate source)
```
[+0..3] sample rate (u32)        e.g. 0xBB80 = 48000
[+4]    channel count            1 = mono, 2 = stereo
[+5]    bit depth (raw)          0x10=16, 0x18=24, 0x20=32
[+6..9] file length in samples (u32)
```

### `0x1028` — session descriptor
```
[+0]        unknown
[+1]        bit depth (raw)
[+2..5]     sample rate (u32)
[+6..10]    5 padding bytes
[+11]       flag
[+12..15]   path component count N (u32)
[+16..]     N path strings: each [u32 len][UTF-8]
... then 5 zero bytes, then 0x02 0x02 0x00 ...
[enumOff]   TC format enum (see table)
[enumOff+1] nominal fps (raw int, e.g. 0x18 = 24)
[enumOff+2..+5] session start in FRAMES (u32)
```

**TC format enum:** `0`=23.976, `1`=24, `2`=25, `3`=29.97 DF, `4`=29.97 (NDF), `5`=30 DF,
`6`=30, `7`=47.952, `8`=48, `9`=50, `10`=59.94 DF, `11`=59.94, `12`=60.

**Frame-rate rationals** (use exact rationals so sample↔frame math is integer):
23.976 = 24000/1001, 29.97 = 30000/1001, 47.952 = 48000/1001, 59.94 = 60000/1001 — others integer.
At 48 kHz, 23.976 → 2002 samples/frame, 24 → 2000, etc.

> Drop-frame (the "DF" variants) only affects the *displayed* timecode label, not sample positions.
> Internally everything is samples, so DF is irrelevant to clip placement; you only need DF math if
> you render an HH:MM:SS:FF string for a DF session.

---

## 5. Plaintext regions (no blocks needed)

### Session path & name
Near `0x91` the literal `Macintosh HD` appears. The path is stored as a `u32` component count
(sane range `0 < n < 20`) followed by `[u32 len][UTF-8]` components. The session name is the
`.ptx` filename.

### Track names (quick-and-dirty)
In roughly `0x130`–`0x500` (we scan `0x100`–`0x2000`), track names appear as `[u32 len][ASCII]`
with `2 ≤ len ≤ 200`, printable ASCII only, **deduplicated by first occurrence** (names repeat
3–4× in the file). This is a heuristic fast-path; the authoritative track list comes from `0x251a`.

### Memory locations — `0x2077` (one block per marker)
```
[+0..1]   location number (u16)
[+2..3]   type/flags (typically 0x0903)
[+6..9]   name length (u32)
[+10..]   name (UTF-8)
[after name] sample position on timeline (u64)
```

---

## 6. Audio files — `0x103a`

After a small header (`[u32][version u8][entry count u32]` at `dataOffset+9`), repeated entries:
```
[u32 nameLen][name bytes][typeField: 4 bytes][trail: 5 bytes]
```
Classify by `typeField` + `trail[0]`:
- **Audio/video file:** `typeField` ∈ {`"WAVE"`,`"EVAW"`,`"AIFF"`,`"FFIA"`,`"VooM"`} (note byte order
  varies). Base name = filename without extension.
- **Folder marker:** `typeField == 0` and `trail[0] == 0x02` → sets the current subfolder name
  (e.g. "Audio Files").
- **Path component:** `trail[0] == 0x01`, `trail[1]` = depth (1 = volume), `typeField` = HFS+
  catalog node id.

Dedup base names by first occurrence. **The binary stores base names without extensions** — you
resolve the real files by scanning the session's `Audio Files/` folder on disk.

---

## 7. Audio clips — `0x2629` (pool) → `0x2628` (entries)

The clip **pool** is the file-order sequence of `0x2629` parents; a clip's pool index is its
ordinal position (referenced later by `0x104f`). Each `0x2628` entry:

```
[u32 nameLen][name]
[+0] leading byte
[+1] nibble: byte-count for sourceOffset   (the high or low nibble; see note)
[+2] nibble: byte-count for length
[+3] nibble: byte-count for start
[+4] skip
[+5 ..]  sourceOffset (var LE), then length (var LE), then start (var LE)
... last 2 bytes of the block: file index (u16) into the 0x103a audio-file list
```

The nibble fields are **variable-length integer widths** — e.g. nibble `3` means the next value is
3 bytes LE. This keeps small numbers compact. `length` and `sourceOffset` are in samples.

---

## 8. Clip placements — `0x1054` → `0x1052` → `0x1050` → `0x104f`

There are (at least) **two** `0x1054` containers. The **first** holds the real per-track playlists;
the **second** holds clip-group "sentinel" sections (see §9).

- `0x1052` = one per-track section. Its name is `[u32 len][UTF-8]` at `dataOffset`; for multi-mono
  tracks the same track name appears in multiple consecutive `0x1052` sections (one per channel).
- `0x1050` wraps the clip references. **Multiple `0x1050` in one `0x1052` = a split** (e.g. a split
  clip group).
- `0x104f` = a single clip/group placement:

```
[+0]      0x01 = muted
[+2..3]   clip index (u16) into the clip pool
[+7..14]  timeline position in SAMPLES (u64). The sentinel value
          0xE8D4A51000 (1,000,000,000,000) marks a constituent reference (see §9).
[+15]     track-within-group ordinal (used to disambiguate shared group slots)
[+18]     0x01 = compound-group original placement; 0x00 = audio clip (or a group *copy*)
[+35]     0x01 = hidden (a sync/dialog reference not drawn on the timeline); 0x00 = visible
```

A placement is a group if `[+18] == 0x01`, or if `[+18] == 0x00` but its clip index is known to be
a group from the compound pool.

---

## 9. Clip groups / compound clips (the hard part)

This is the most involved part of the format. Compound clips ("clip groups") are defined once and
referenced like clips, but their **constituents** (the child clips inside the group) live in a
parallel structure and are positioned relative to the group.

### The pieces
- **`0x262b` → `0x2628`**: the compound clip **pool** (same entry layout as audio clips). After a
  `0x2628` compound entry, the parent `0x262b` carries **trailing bytes**:
  - `trailing[1]` = **trail index** (which `0x2423` group definition this is)
  - `trailing[5]` = **pos** (position within the group; `0,1,2,…` for split groups)
- **`0x2423`**: one per group definition. `[+0..1]` = **GID** (group id), `[+4..7]` = name length,
  `[+8..]` = name. Its ordinal (file order) is the "trail index" referenced above.
- **`0x2425`**: per-GID **member count** (includes "phantom" slots for deleted members — needed to
  align sentinel slots correctly).
- **`0x2523`** (with a 14-byte **`0x2526`** child): a constituent **sentinel**. Inside the compound
  `0x2628` entry, bytes `[+24..27]` give a constituent count, then each constituent is a ~97-byte
  record (`0x2523` header + content). Within a `0x2523`:
  - `[+23..26]` constituent absolute timeline position (u32)
  - `[+39..42]` constituent audio-clip pool index (u32)
  - `seq_idx` at +16 (relative to end of the `0x2526` child) = sequence index within the group
  - `xref` at +52 = owning group's compound-pool index (`0xFFFFFFFF` = root/no parent)
  - content-range fields around `[+49..53]` (in) and `[+57..61]` (out), each a 5-byte LE value
    **minus** the `0xE8D4A51000` origin

### The timing model (key insight)
- **First `0x1054`** stores **absolute** group start times.
- **Second `0x1054`** stores constituent **deltas** relative to the group base, encoded as
  `stored − 0xE8D4A51000`. So a constituent's absolute position = `groupBase + (stored − ZERO_TICKS)`
  where `ZERO_TICKS = 0xE8D4A51000 = 1,000,000,000,000`.
- A compound's own start can be recovered from its `0x2628` by finding **two consecutive identical
  4-byte LE values** ~13–17 bytes after the name end, in the range ~100K–500M samples.

### Resolution algorithm (what PTpeek does)
1. Map each compound pool index → `(trailIndex, pos)` from the `0x262b` trail bytes.
2. `(trailIndex)` → `0x2423` → **GID** and group name.
3. For each unique GID, map its `(GID, pos)` pairs to **consecutive sentinel slot indices** in the
   2nd `0x1054`; reserve `max(memberCount[GID], maxPos[GID]+1)` slots so phantom/deleted members
   don't shift the alignment.
4. To resolve a group placement at `absStart` on track ordinal `t`: take its slot's `0x104f`
   members; for each, read its 5-byte offset, compute `delta = offset − ZERO_TICKS`, check `[+18]`
   (recurse if it's itself a sub-group, else it's an audio leaf), check `[+35]` for hidden,
   filter by the content range (widest non-negative span by default; tightest-fit fallback for
   fades/pre-roll), and yield `(audioClipIndex, relativeOffset = delta)`. Dedup by audio clip index.
5. **Moved groups:** if a group's creation-time start differs from its track-listing start, the
   group was moved after creation — use the track-listing start as the base for deltas.
6. **Shared slots:** when one sentinel slot backs the same group placed on multiple tracks, use the
   `[+15]` track-within-group ordinal to pick the right members; otherwise ignore it (avoids false
   matches when audio/compound pool indices collide).

> This was by far the most error-prone area — getting phantom-slot counts, moved-group bases, split
> positions, and content-range fallbacks right took many iterations. If you only need a flat clip
> list, you can skip groups; if you need accurate grouped-clip positions, budget real time for it.

---

## 10. Video clips — `0x262d` (pool) → `0x2628`, referenced via `0x1055` → `0x104f`

The video pool mirrors the audio pool (`0x262d` parents → `0x2628` children with name + length in
**frames**). Video clip references live under the `0x1055` container as `0x104f` blocks with a
**different, simpler layout** than audio `0x104f`:

```
[+0]     size byte (0x10)
[+3]     clip index (u8) into the video pool
[+7..10] timeline position in FRAMES (u32)
```

Convert to samples with `samplesPerFrame = sampleRate / frameRate` (integer division in our parser;
for exactness use the rational fps). Note the binary stores only the clip **base name** — the
actual movie file is resolved on disk (or loaded manually).

---

## 11. Multichannel & multi-mono

- **Channel count** for a track comes from the `0x251a` channel-format byte (§12).
- **Multi-mono** tracks: the first `0x1052` section for a track name drives the timeline positions;
  subsequent same-named sections are the additional channels. Companion clip indices are matched to
  the first channel's placement by identical timeline position.
- A clip can reference **one channel of an interleaved file** via a `".AN"` name suffix (`.A1`=ch1,
  `.A3`=ch3, …), 1-indexed in the name, 0-indexed when you extract the channel.

---

## 12. Track display info — `0x2519` → `0x251a`

This is the authoritative per-track record. Layout (offsets relative to `dataOffset`, `nl` = name
length):
```
[+0..1]            track type (u16): 0x00 audio, 0x02 aux, 0x08 video, 0x09 VCA, 0x0b folder
[+2..5]            name length (u32)
[+6 .. 6+nl-1]     name (UTF-8)
[+6+nl]            channel-format byte (see mapping)
... UUID/marker/display-index fields ...
[+63+nl]           visible flag   (0 = hidden)
[+64+nl]           active flag    (0 = inactive)
[+68+nl]           color index (u16); >= 0x8000 means "no custom color", else PT palette 0–55
```

**Channel-format byte → channel count:** `0x00`=1 (mono), `0x01`=2 (stereo), `0x02`=3 (LCR),
`0x06`=6 (5.1), `0x0A`=8 (7.1), `0x0C`=10 (7.1.2), `0x0E`=12 (7.1.4), … up to `0x10`=14 (9.1.4).

### Folder hierarchy — `0x210c`
A depth-first tree: header `[u32 nodeCount][5 bytes][0x2a marker]`, then entries of
`[8-byte UID][u32 childCount][padding][0x2a marker]`. `childCount > 0` = folder node, `0` = leaf.
A stack-based walk reconstructs parent/child membership. Track UIDs come from `0x210b`
(name → 8-byte UID).

---

## 13. Routing — `0x261b` → `0x260d` → `0x260e`

Per-track routing lives in a `0x261b` container (which also holds the `0x102d` mixer strip). Output
and send paths are `0x260e` blocks:
```
[+0..1]   0xff 0xff = no path; else valid
[+36]     path string: [u32 len][UTF-8]   (e.g. "UPMIX", a bus/output name)
after the string:
  [+1] channel-format byte (bed width)
  [+2] Atmos object slot (0xff/0x00 = not an object)
  [+11] Atmos bed/group id (0xff = not a bed; 0x00 = Dialog, 0x0a = Music, …)
```
`0x260e` starting with `0x13` = an aux **send**; otherwise the **main output**. The **input** path is
found by scanning forward from the end of the container's last child for a
`{00 00 00 00}{4 bytes}{00}{u32 len}{UTF-8}` sentinel.

---

## 14. Plugins

### Plugin inventory — `0x1017`
```
[+0]        type byte: 0x03/0x04 = real plugin, 0xff = placeholder (skip)
[+1..4]     display-name length (u32)
[+5..]      display name (UTF-8)
[then]      three 4-byte OSType codes (manufacturer/product), flags, then a second
            length-prefixed string (bundle id / variant)
```
Dedup by display name.

### Per-track inserts — `0x102d` → `0x2627` → `0x2616`/`0x2625`
The mixer strip (`0x102d`, with a `0x2619` sub-block carrying the strip name + 8-byte UID) is
followed by a `0x2627` plugin-state container holding up to ~10 slot records that **overlap by 2
bytes** (advance = `9 + size − 2`): `0x2625` = empty slot, `0x2616` = occupied. An occupied slot
carries an 8-byte AAX OSType key at content `+56`, matched back to the `0x1017` inventory. Tracks
are matched to strips first by UID (`0x210b`), then by strip-name fallback.

---

## 15. Key constants & gotchas

- `ZERO_TICKS = 0xE8D4A51000 = 1,000,000,000,000` — origin for 2nd-`0x1054` constituent positions
  and the `0x104f` constituent sentinel value.
- First block at file offset `0x1f`; XOR pages are 4096 bytes; page 0 is plaintext.
- Block sizes exclude the 9-byte header; scan byte-by-byte to catch nested blocks.
- Strings are almost always `[u32 length-prefix][UTF-8/ASCII]`; many strings repeat 3–4× — dedup by
  first occurrence.
- **What the binary does NOT give you reliably:** resolved on-disk file paths (you scan the
  `Audio Files/` / video folders yourself), and anything Pro Tools computes live. PTpeek augments
  via **PTSL gRPC** (localhost:31416) when PT is running for sample rate / bit depth / TC / plugin
  lists / track types — but everything above is recoverable from the binary alone.
- Endianness: we've only ever seen little-endian (`byte 0x11 == 0`); the big-endian path is
  implemented but untested.

---

## 16. Suggested parse order

1. Read `0x11/0x12/0x13`; XOR-decode the file.
2. Scan blocks from `0x1f`.
3. Session params from `0x1028` (+ `0x1001` for sample rate).
4. Tracks from `0x2519`/`0x251a` (type, channels, flags, color); folders from `0x210c`.
5. Audio files from `0x103a`; audio clip pool from `0x2629`/`0x2628`.
6. Compound pool from `0x262b`; group defs from `0x2423`; counts from `0x2425`.
7. Playlists from the 1st `0x1054` (`0x1052`/`0x1050`/`0x104f`); resolve groups against the 2nd
   `0x1054` sentinels.
8. Video pool from `0x262d`; video refs from `0x1055`/`0x104f`.
9. Markers from `0x2077`; routing from `0x261b`; plugins from `0x1017` + `0x102d`/`0x2627`.

---

*Reverse-engineered for PTpeek. Corrections/additions welcome — especially older formats, the
big-endian path, and the `0x2523` `seq_idx`/`xref` fields (decoded but not yet fully exploited).*
