# PTpeek

Native macOS app + Quick Look extension for inspecting Pro Tools .ptx session files without opening Pro Tools.

**Stack:** Swift/SwiftUI, AVFoundation, PTSL gRPC (localhost:31416)  
**Targets:** macOS 13+  
**Minimum PT version:** PT 2022.12 (PTSL); binary parsing works with any PT 10+ session

## Xcode Project Setup

Two targets required:

### 1. PTpeek (main app)
- Kind: macOS App
- Add all files under `PTpeek/`
- Info.plist: declare `CFBundleDocumentTypes` for `.ptx` (UTI: `com.avid.protools.session`)
- Entitlements: `com.apple.security.network.client` (for PTSL gRPC on localhost)

### 2. PTpeekQL (Quick Look Preview Extension)  
- Kind: Quick Look Preview Extension
- Add all files under `PTpeekQL/` PLUS all files from `PTpeek/Parser/`, `PTpeek/ProTools/`, `PTpeek/UI/`
- Info.plist NSExtension dict:
  ```xml
  <key>NSExtensionAttributes</key>
  <dict>
      <key>QLSupportedContentTypes</key>
      <array>
          <string>com.avid.protools.session</string>
      </array>
      <key>QLSupportsSearchableItems</key>
      <false/>
  </dict>
  <key>NSExtensionPointIdentifier</key>
  <string>com.apple.quicklook.preview</string>
  <key>NSExtensionPrincipalClass</key>
  <string>$(PRODUCT_MODULE_NAME).PreviewViewController</string>
  ```

### Shared files (add to BOTH targets)
- `PTpeek/Parser/PTXSession.swift`
- `PTpeek/Parser/PTXParser.swift`
- `PTpeek/ProTools/PTSLSessionInfo.swift`
- `PTpeek/UI/Views/SessionInspectorView.swift`

## Architecture

### Binary Parsing (PTXParser.swift)
Works without Pro Tools. Extracts from the .ptx plaintext header:
- Session name + path
- Memory location names (fixed offset 0x3a from file start)
- Track names (4-byte LE length-prefixed strings, early section ~0x130-0x500)
- Clip/audio file base names (longer strings, no extension stored in binary)

Does NOT extract: sample rate, bit depth, TC format, plugins, clip positions.
These require PTSL (see below).

### PTSL Augmentation (PTSLSessionInfo.swift)
Connects to Pro Tools via gRPC on localhost:31416 when PT is running with the session open.
Fills in: sample rate, bit depth, TC format, session length, track types, plugin list.
Fails silently if PT is not connected.

PT 2025.10+ GetClipList / GetPlaylistElements → universe view clip positions (TODO).

### Known PTX Format Notes
- Byte 0x12: format type (0x05 = PT 10+)
- Byte 0x13: XOR key for encrypted sections (later in file, not used in early plaintext)
- Bytes 0x3a-0x3d: memory location count (4-byte LE)
- "Macintosh HD" path component appears near 0x91; path component count precedes it
- Track names appear as 4-byte LE length-prefixed ASCII strings from ~0x130 onward
- Audio filenames (base names without .wav) follow track names in the same section
- Strings repeat 3-4x in the binary; PTXParser deduplicates by first occurrence
- Sample rate / bit depth stored as enums (not decoded yet) — use PTSL instead

### Architecture Notes (from SFXLibrary reference)
- Do NOT make AppState @MainActor class — use @MainActor on individual methods instead
- NSWorkspace.open is synchronous on main thread — wrap in Task
- Quick Look extension shares Parser/UI code with main app (same files, both targets)
