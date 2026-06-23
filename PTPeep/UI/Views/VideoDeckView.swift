import AVFoundation
import AppKit
import CoreMedia

/// Displays decoded `CMSampleBuffer` frames via `AVSampleBufferDisplayLayer` — GPU-composited,
/// zero-copy from the IOSurface-backed pixel buffers `LibavDecoder` produces. The deck pushes a
/// frame on every scrub/playhead change (and per-frame during playback); each is tagged
/// "display immediately" so it shows now regardless of any timebase. Main-app only.
final class VideoDeckView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
        layer = displayLayer            // layer-hosting view
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    private var didLogShow = false

    /// Show a single frame now (scrub / cursor lock / per-frame playback). Uses the modern
    /// sampleBufferRenderer on macOS 14+ (the layer-level enqueue is deprecated and does not
    /// reliably render on macOS 15/26); falls back to the layer API on 13.
    func show(_ sampleBuffer: CMSampleBuffer) {
        setDisplayImmediately(sampleBuffer)
        if #available(macOS 14.0, *) {
            let r = displayLayer.sampleBufferRenderer
            if r.status == .failed { r.flush() }
            r.enqueue(sampleBuffer)
        } else {
            if displayLayer.status == .failed { displayLayer.flush() }
            displayLayer.enqueue(sampleBuffer)
        }
        if !didLogShow { didLogShow = true; AppLog.shared.log("[Video] deck displayed first frame (\(Int(bounds.width))x\(Int(bounds.height)))") }
    }

    func clear() { displayLayer.flushAndRemoveImage() }

    /// Tag the (first) sample so AVSampleBufferDisplayLayer presents it immediately.
    private func setDisplayImmediately(_ sb: CMSampleBuffer) {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
              CFArrayGetCount(arr) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}
