# Stereo / multichannel spotting — correctness notes (for porting to SFXLibrary)

Fixes made in PTpeek for spotting stereo & multichannel clips to Pro Tools via Apple Events.
Written so the same logic can be checked/ported into **SFXLibrary** (our other SFX spotting app).
If SFXLibrary shares this spot code path, it very likely has the same two bugs.

## TL;DR — two independent bugs

1. **Audio (channel routing).** The spotter decided *how many streams to send* from parser
   bookkeeping (`channelFiles.count`) instead of the file's **real channel count**. An
   **interleaved** file (N channels in one file) that carried >1 channel entry got sent as N
   separate mono events → channel 1 landed in every stream (or a wrong file in stream 2).
   → **Fix:** read the primary file's real channel count; if it's interleaved, send **one**
   `Strm=1` event and let PT read all channels; only send N streams for N genuinely distinct
   **mono** files.

2. **Naming.** Every stream event was sent with the **channel-1 clip name**, so PT labeled both
   channels of a stereo clip `…_L-09` — looked like "two left channels" even though the audio
   was correct. → **Fix:** carry a **per-channel name** and label each stream with its own
   (`…_L-09` → stream 1, `…_R-08` → stream 2).

Both were verified against ground truth (see *Diagnostic method*). The audio was actually correct
the whole time for multi-mono clips; #1 only bites true interleaved files, #2 is cosmetic-but-visible.

---

## Background: how PT Apple Event spotting works

Spot uses the classic `'Sd2a'`/`'SRgn'` Apple Event (accepted since PT 5.1; no PTSL/gRPC needed).
**One event per channel.** Each event carries:

| Param | Meaning |
|-------|---------|
| `FILE` | the audio file for **this one channel** (one file per event) |
| `Strm` | destination playlist/channel within the track (1 = mono / left) |
| `name` | the region name PT shows — **PT uses whatever we send; it is not derived from the file** |
| `Trak=-99`, `TkOf` | spot onto selected track / track offset |
| `SMSt` | sample offset from PT's edit cursor |
| `Rgn.Star`/`Stop` | source in/out within the file (full handles = 0…fileLength) |

Key consequences:
- To place a **multi-mono** stereo clip you send **two** events: L file → `Strm=1`, R file → `Strm=2`.
- To place an **interleaved** file you send **one** event (`Strm=1`); PT pulls all channels from it.
  Sending N events for an interleaved file spots channel 1 into every stream (bug #1).
- The region name is **only** what you put in `name`. Send the same name twice → both channels
  show the same name (bug #2).

---

## The correct data model (what makes both fixable)

A clip should carry, separately:
- **one display name** (`clip.name`) — what the timeline shows;
- **`channelFiles: [String]`** — the actual audio file per channel, in stream order (index 0 = ch1);
- **`channelNames: [String]`** — the per-channel *clip* name, index-aligned with `channelFiles`
  (e.g. `["…wav_L-09", "…wav_R-08"]`).

The trap we hit: the parser built `channelFiles` from each channel's **file**, but for companion
channels it **discarded that companion clip entry's own `.name`** — so we only had the channel-1
name and reused it everywhere. The right channel's real name was available all along on the
companion clip entry; we just weren't reading it.

`channelFiles` (the files) and `channelNames` (the labels) are different things and must both be
tracked per channel. `clip.name` (one label) is fine for the timeline display.

---

## Interleaved vs multi-mono — the distinction that matters

Pro Tools stores stereo/multichannel two ways; the spotter must handle both:

- **Interleaved / poly WAV** (one file, N channels — typical field-recorder output):
  `channelFiles` has **one** entry. Spot as **one** `Strm=1` event.
- **Multi-mono** (one file per channel/mic): `channelFiles` has **N distinct** entries. Spot as
  **N** events, `Strm=1…N`, each with its own file **and its own name**.

**Do not** decide which case you're in from parser metadata alone. Open the primary file and read
its real channel count (`AVAudioFile.processingFormat.channelCount`). That is the only reliable
signal — parser bookkeeping can represent an interleaved source with >1 channel entry.

---

## The fix, in PTpeek terms (mirror in SFXLibrary)

Resolution block in the spot path (`PTAppleEventSpot.spotRegionViaAppleEvent`):

```swift
// 1. Resolve each channel to (file URL, stream, per-channel name).
var resolved: [(url: URL, stream: Int16, name: String)] =
    clip.channelFiles.enumerated().compactMap { i, fname in
        guard let u = poolByName[fname] else { return nil }
        let chName = i < clip.channelNames.count ? clip.channelNames[i] : clip.name
        return (u, Int16(i + 1), chName)
    }

// 2. Decide interleaved vs multi-mono from the FILE, not from channelFiles.count.
let primaryChannels = resolved.first
    .flatMap { try? AVAudioFile(forReading: $0.url) }
    .map { Int($0.processingFormat.channelCount) } ?? 1
if let first = resolved.first,
   primaryChannels >= 2 || (Set(resolved.map(\.url)).count == 1 && resolved.count > 1) {
    resolved = [first]                      // interleaved (or duplicate refs) → one Strm=1 event
}

// 3. Send one event per remaining channel, each with ITS OWN name.
for (chURL, stream, chName) in resolved {
    aeSendSpot(url: chURL, name: chName, stream: stream, /* Star/Stop/offset/... */)
}
```

Parser side — capture the companion's name alongside its file (index-aligned):

```swift
var channelFiles = [ch1File]
var channelNames = [clipEntry?.name ?? name]     // channel-1 name
for compIdx in placement.companionClipIdxs {
    if let entry = clipPool[compIdx], let fn = fileNameByIndex[entry.audioFileIndex] {
        channelFiles.append(fn)
        channelNames.append(entry.name)          // <-- was being discarded
    }
}
```

---

## Porting checklist for SFXLibrary

- [ ] Find the spot path (the code that builds `Sd2a`/`SRgn` events, or its equivalent).
- [ ] Does it decide stream count from a channel-file **count**/metadata, or from the file's real
      channel count? If from count → **bug #1 present**. Add the `AVAudioFile` channel-count check.
- [ ] Does it send the **same `name`** to every stream event? If yes → **bug #2 present**. Give it
      per-channel names.
- [ ] Does its clip model store a **per-channel name list**, or only one name + a file list? If only
      one name, add the per-channel names (and check the parser isn't discarding companion names).
- [ ] Watch the **filename→URL resolver**: if it keys by an extension-stripped stem with
      first-wins, distinct channel files with colliding stems can resolve to the wrong URL. Prefer
      exact-name keys; at least log collisions.
- [ ] **Channel order for N > 2**: multi-mono 4/6/8-channel sets must produce channel files in the
      correct order (1,2,3,4…). Two channels is trivial; higher counts are where an ordering slip
      shows. Validate with a real poly / multi-mono recording.

---

## Diagnostic method (how we verified — reuse it)

You do **not** need Pro Tools or the audio files to check the parser side:

1. Compile the real parser into a tiny CLI (`swiftc parser sources + a main.swift`) and dump, per
   stereo clip: `channelFiles`, `channelNames`, and the `(stream → file, name)` the spotter would
   build. (No GUI, no PT.)
2. **Ground truth = Pro Tools' own EDL text export.** For a stereo track it lists `CHANNEL 1` /
   `CHANNEL 2` rows with each channel's clip name, and a file-list section mapping clip name → file.
   Cross-check the parser's pairing against it. This is deterministic — no guessing.
3. For the runtime (spot) side, the spotter logs each event; capture those lines while spotting a
   known clip and compare `Strm`/`url`/`name` to the EDL. **Spot into a BLANK session** — spotting
   into a copy of the same session lets PT match incoming clips to existing same-named clips and
   masks/changes the result.

---

## Reference (PTpeek)

- `PTPeep/ProTools/PTAppleEventSpot.swift` — spot event construction, channel resolution.
- `PTPeep/Parser/PTXParser.swift`, `PTPeep/Parser/PTXSession.swift` — `PTXClip.channelFiles` /
  `channelNames`, companion-channel assembly.
- Commits: `7ca33a9` (interleaved detection via real channel count), `e8133b0` (per-channel naming).
- Symptom history: reported as "spots left + a wrong 2nd channel" / "two .L channels"; the audio was
  actually correct for multi-mono — the fixable issues were interleaved handling (#1) and naming (#2).
