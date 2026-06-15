// Compare placements on 1-4 split tracks around sample 188885472 in two files
import Foundation

func decode(_ path: String) -> (data: Data, blocks: [(ct: UInt16, off: Int, sz: Int)]) {
    let raw = try! Data(contentsOf: URL(fileURLWithPath: path))
    let n = raw.count
    let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
    for i: UInt16 in 0...255 {
        if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break }
    }
    var table = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 { table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
    var d = raw; let src = Array(raw)
    d.withUnsafeMutableBytes { dst in
        let dp = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
        var off = 4096; while off < n {
            let xb = table[(off >> 12) & 0xff]
            if xb != 0 { let e = min(off+4096,n); for j in off..<e { dp[j]=src[j]^xb } }; off += 4096
        }
    }
    func b(_ i: Int) -> UInt8 { d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in p[i] } }
    func u16le(_ i: Int) -> UInt16 { UInt16(b(i)) | UInt16(b(i+1))<<8 }
    func u32le(_ i: Int) -> UInt32 { UInt32(b(i)) | UInt32(b(i+1))<<8 | UInt32(b(i+2))<<16 | UInt32(b(i+3))<<24 }
    var blocks: [(ct: UInt16, off: Int, sz: Int)] = []
    var i = 0x1f; while i+9 <= n {
        guard b(i)==0x5a else { i+=1; continue }
        let sz=Int(u32le(i+3)); let ct=u16le(i+7)
        guard sz>0, sz<50_000_000, i+9+sz<=n else { i+=1; continue }
        blocks.append((ct, i+9, sz)); i += 1
    }
    return (d, blocks)
}

func analyze(_ path: String, label: String) {
    let (d, blocks) = decode(path)
    func b(_ i: Int) -> UInt8 { d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in p[i] } }
    func u16le(_ i: Int) -> UInt16 { UInt16(b(i)) | UInt16(b(i+1))<<8 }
    func u32le(_ i: Int) -> UInt32 { UInt32(b(i)) | UInt32(b(i+1))<<8 | UInt32(b(i+2))<<16 | UInt32(b(i+3))<<24 }
    func u64le(_ i: Int) -> UInt64 { UInt64(u32le(i)) | UInt64(u32le(i+4))<<32 }
    func readLE(_ i: Int, _ c: Int) -> UInt64 { var v: UInt64=0; for j in 0..<c { v |= UInt64(b(i+j))<<(j*8) }; return v }
    let n = d.count

    // Audio clip pool
    let all2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }
    let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }
    func clipName(_ idx: Int) -> String {
        guard idx < all2629.count else { return "OUT[\(idx)]" }
        let parent = all2629[idx]; let pEnd = parent.off+parent.sz
        guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else { return "<no child>" }
        let pos = child.off; guard pos+4 < n else { return "<oob>" }
        let nl = Int(u32le(pos)); guard nl>0, nl<=512, pos+4+nl<=n else { return "<badnl>" }
        return String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<utf8?>"
    }

    // Compound pool
    let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
    func compoundName(_ idx: Int) -> String {
        guard idx < all262b.count else { return "OUT[\(idx)]" }
        let parent = all262b[idx]; let pEnd = parent.off+parent.sz
        guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else { return "<no child>" }
        let pos = child.off; guard pos+4 < n else { return "<oob>" }
        let nl = Int(u32le(pos)); guard nl>0, nl<=512, pos+4+nl<=n else { return "<badnl>" }
        return String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<utf8?>"
    }

    let all1052 = blocks.filter { $0.ct == 0x1052 }.sorted { $0.off < $1.off }
    let all104f = blocks.filter { $0.ct == 0x104f }.sorted { $0.off < $1.off }
    let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
    guard let ft54 = all1054.first else { return }
    let ft54End = ft54.off + ft54.sz

    // Find 1-4 split sections
    let splitNames = ["1 split", "2 split", "3 split", "4 split"]
    let rangeStart: Int64 = 188000000
    let rangeEnd:   Int64 = 190500000

    print("\n=== \(label) ===")
    for trackName in splitNames {
        let secs = all1052.filter { sec in
            guard sec.off >= ft54.off && sec.off+sec.sz <= ft54End else { return false }
            let nl = sec.sz >= 4 ? Int(u32le(sec.off)) : 0
            guard nl > 0 && nl <= 256 && sec.off+4+nl <= n else { return false }
            return String(bytes: d[sec.off+4..<sec.off+4+nl], encoding: .utf8) == trackName
        }
        guard let sec = secs.first else { continue }
        let secEnd = sec.off + sec.sz
        let placements = all104f.filter { $0.off >= sec.off && $0.off+$0.sz <= secEnd }
        let nearby = placements.filter { pl in
            guard pl.sz >= 19 else { return false }
            let tl = Int64(bitPattern: u64le(pl.off+7))
            return tl >= rangeStart && tl <= rangeEnd
        }
        if nearby.isEmpty { print("  \(trackName): no placements in range"); continue }
        print("  \(trackName):")
        for pl in nearby {
            let clipIdx = Int(u16le(pl.off+2))
            let tl = Int64(bitPattern: u64le(pl.off+7))
            let b18 = b(pl.off+18); let b0 = b(pl.off)
            let b35 = pl.sz >= 36 ? b(pl.off+35) : 0xff
            guard b35 == 0x00 else { continue }  // skip hidden
            let info = b18 == 0x01 ? "GROUP '\(compoundName(clipIdx))'" : "clip '\(clipName(clipIdx))'"
            let muted = b0 == 0x01 ? " [MUTED]" : ""
            print("    tl=\(tl) \(info)\(muted)")
        }
    }
}

let path1 = "Tests/honeybunch_PeepTest.ptx"
let path2 = "Tests/honeybunch_PeepTestC.ptx"
analyze(path1, label: "Original (grouped)")
analyze(path2, label: "PeepTestC (ungrouped at 01:05:31:04)")
