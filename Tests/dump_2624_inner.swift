import Foundation

@main
struct Dump2624Inner {
    static func main() {
        guard CommandLine.arguments.count > 1 else { exit(1) }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        var t = [UInt8](repeating: 0, count: 256)
        let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
        for i: UInt16 in 0...255 { if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break } }
        for i in 0..<256 { t[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
        var data = raw; for i in 0..<raw.count { data[i] = raw[i] ^ t[(i >> 12) & 0xff] }

        var blocks = [(ct: UInt16, off: Int, size: Int)]()
        var i = 0x1f
        while i + 9 <= data.count {
            guard data[i] == 0x5a else { i += 1; continue }
            let sz = Int(UInt32(data[i+3]) | UInt32(data[i+4]) << 8 | UInt32(data[i+5]) << 16 | UInt32(data[i+6]) << 24)
            let ct = UInt16(data[i+7]) | UInt16(data[i+8]) << 8
            guard sz > 0, sz < 50_000_000, i + 9 + sz <= data.count else { i += 1; continue }
            blocks.append((ct, i + 9, sz))
            i += 1
        }

        guard let b2624 = blocks.first(where: { $0.ct == 0x2624 }) else { print("no 0x2624"); return }
        let lo = b2624.off, hi = b2624.off + b2624.size

        for ct in [UInt16(0x2037), 0x2038, 0x200a, 0x200b, 0x2015, 0x261b, 0x261c] {
            let inner = blocks.filter { $0.ct == ct && $0.off >= lo && $0.off + $0.size <= hi }
            guard !inner.isEmpty else { continue }
            print(String(format: "═══ 0x%04x inside 0x2624 (%d total) ═══", ct, inner.count))
            for b in inner.prefix(5) {
                let n = min(b.size, 64)
                let hex = (0..<n).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
                print("  @\(b.off) size=\(b.size):  \(hex)")
            }
        }
    }
}
