# Multi-Clip Selection & Playback — Design Plan

## Scenarios

### 1. Single-track sequential playback
User draws a time selection (selStart + selEnd) on one track. All clips overlapping
that window play in order, with silence filling the gaps between them.

### 2. Multi-track simultaneous playback
User draws a selection spanning multiple tracks (selTrack ≠ selTrackEnd). All clips
across those tracks mix together and play simultaneously.

### 3. Group clip expansion
When a `PTXClip` with `isGroup = true` is selected, collect all non-group clips
across all tracks that fall within `clip.startSample ... + clip.lengthSamples` and
treat them as the group's contents. Feed to the multi-track mixer. No new binary
parsing needed — position-based lookup only.

---

## Decisions

- **Memory model:** Pre-read clips into RAM (no streaming). Cap at ~2 min / ~100 MB;
  warn past that. Typical use-case selections are short (seconds to ~1 min).
- **Volume:** Unity gain for all tracks — no automation or clip gain for now.
- **Waveform area:** Hide `ClipWaveformView` during multi-clip playback; show a text
  label like "N clips across M tracks" instead.
- **Trigger:** Spacebar plays the current selection (single clip or region). Autoplay
  behavior is preserved — selecting a region while autoplay is on starts playback.

---

## Data Model

New `PlayRegion` struct (add to `PTXSession.swift`):

```swift
struct PlayRegion {
    struct TrackSegment {
        let trackIdx: Int
        let clips: [(clip: PTXClip, url: URL)]   // sorted by startSample
    }
    let startSample: Int64        // region start (absolute samples)
    let endSample:   Int64        // region end (absolute samples)
    let segments:    [TrackSegment]   // one entry per track that has clips in range
    let sampleRate:  Double
}
```

---

## AudioPlayer Changes

- Add `playRegion(_ region: PlayRegion)`:
  - For each `TrackSegment`, build one stitched PCM buffer (clips + silence fills)
  - Create one `AVAudioPlayerNode` per track segment, connect all to `gainNode`
  - Compute a shared `AVAudioTime` anchor and start all nodes simultaneously
  - Track extra nodes in a `[AVAudioPlayerNode]` array; `stop()` detaches and removes them
- Add `@Published var isPlayingRegion: Bool` so UI can distinguish modes
- Keep existing `play(clip:url:sampleRate:fromFraction:)` unchanged

---

## SessionInspectorView Changes

### New computed var `selectedRegion: PlayRegion?`
Populated when `selEnd != nil`. Collects clips from tracks `selTrack...selTrackEnd`
that overlap the selection. Also triggers for group clips (`isGroup == true`).

### Waveform area
When `selectedRegion != nil`, replace `ClipWaveformView` with a label:
`"N clips across M tracks"` (or `"N clips"` for single-track).

### Spacebar
- `selectedRegion != nil` → `audioPlayer.playRegion(region)`
- Otherwise → existing single-clip play/stop toggle

### Autoplay
- `onChange(of: tc.selEnd)`: if `selEnd` becomes non-nil and autoplay is on,
  trigger `playRegion`
- Existing `onChange(of: tc.selStart)` handles single-clip case as before

---

## Implementation Order

1. `PlayRegion` struct in `PTXSession.swift`
2. `AudioPlayer.playRegion()` + extra node management + `isPlayingRegion`
3. `selectedRegion` computed var in `SessionInspectorView`
4. Waveform area swap (label vs `ClipWaveformView`)
5. Spacebar + autoplay hookup
6. Group clip expansion (uses `selectedRegion` machinery, no new parsing)

---

## Open Items / Future

- Streaming playback for very long selections (completion-handler chaining on
  `AVAudioPlayerNode`)
- Per-track volume / fader integration
- Waveform composite view for multi-clip selection
- True group-to-children mapping via binary parsing (0x262b block research)
