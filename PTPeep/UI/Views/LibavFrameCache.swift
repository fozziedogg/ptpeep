import CoreMedia
import CoreVideo
import Foundation

/// Minimal frame cache over a single `LibavDecoder`. libav decodes at ~1.6 ms/frame (~25×
/// real-time at 24 fps), so no decoder pool is needed — just a dictionary, inline decode on
/// miss, a nearest-frame fallback for smooth motion, and one rolling prefetch task.
/// Authority: the "Walter" handoff, §6. Main-app only.
final class LibavFrameCache: @unchecked Sendable {
    let decoder: LibavDecoder
    var totalFrames: Int { decoder.totalFrames }
    var fps: Double { decoder.fps }

    private var cache: [Int: CVPixelBuffer] = [:]
    private let cacheLock = NSLock()
    private let baseCacheRadius = 30          // ±30 frames ≈ ±1.25 s at 24 fps
    var speedMultiplier: Double = 1.0          // widen the window during fast shuttle

    private var prefetchGeneration = 0
    private var prefetchInFlight = false
    private var lastPrefetchAnchor = Int.min

    init(decoder: LibavDecoder) { self.decoder = decoder }

    // macOS-26 Swift marks NSLock.lock()/unlock() @noasync; the check fires at the immediate
    // call site, so routing through these trivial sync proxies lets the prefetch Task lock
    // safely. Contract: never `await` between acquire() and release() on this lock.
    private func acquire() { cacheLock.lock() }
    private func release() { cacheLock.unlock() }

    /// Blocking: exact hit → return; miss → decode inline (~1.6 ms), insert, evict, prefetch.
    func frame(at index: Int) -> CVPixelBuffer? {
        acquire()
        if let pb = cache[index] { release(); triggerPrefetch(around: index); return pb }
        release()

        guard let sb = decoder.decodeSample(at: index),
              let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        acquire(); cache[index] = pb; evictLocked(around: index); release()
        triggerPrefetch(around: index)
        return pb
    }

    /// Non-blocking motion path: exact hit → return; else nearest cached frame within a small
    /// radius (behind-first, since forward motion keeps recent frames); else decode inline.
    func cachedFrame(at index: Int) -> CVPixelBuffer? {
        acquire()
        if let pb = cache[index] { release(); triggerPrefetch(around: index); return pb }
        var nearest: CVPixelBuffer?
        for d in 1...8 {
            if let pb = cache[index - d] { nearest = pb; break }
            if let pb = cache[index + d] { nearest = pb; break }
        }
        release()
        triggerPrefetch(around: index)
        return nearest ?? frame(at: index)
    }

    /// Warm the cache around an index without blocking the caller.
    func primePrefetch(around index: Int) { triggerPrefetch(around: index) }

    // MARK: Internals

    private func evictLocked(around index: Int) {
        let keep = Int(Double(baseCacheRadius * 3) * max(1.0, speedMultiplier))
        guard cache.count > keep * 2 else { return }   // throttle: only when well over budget
        let lo = index - keep, hi = index + keep
        for k in cache.keys where k < lo || k > hi { cache.removeValue(forKey: k) }
    }

    private func triggerPrefetch(around index: Int) {
        acquire()
        let movedFar = abs(index - lastPrefetchAnchor) > (baseCacheRadius / 2)
        guard movedFar || !prefetchInFlight else { release(); return }
        prefetchGeneration &+= 1; let gen = prefetchGeneration
        lastPrefetchAnchor = index; prefetchInFlight = true
        release()

        let radius = Int(Double(baseCacheRadius) * max(1.0, speedMultiplier))
        let endIndex = min(decoder.totalFrames - 1, index + radius)
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var i = index + 1
            while i <= endIndex {
                self.acquire()
                if self.prefetchGeneration != gen { self.prefetchInFlight = false; self.release(); return }
                let already = self.cache[i] != nil
                self.release()
                if !already, let sb = self.decoder.decodeSample(at: i),
                   let pb = CMSampleBufferGetImageBuffer(sb) {
                    self.acquire(); self.cache[i] = pb; self.release()
                }
                i += 1
            }
            self.acquire(); if self.prefetchGeneration == gen { self.prefetchInFlight = false }; self.release()
        }
    }
}
