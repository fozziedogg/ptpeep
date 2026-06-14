import Foundation

@main
struct DumpPTXHeader {
    static func main() {
        guard CommandLine.arguments.count > 1 else { exit(1) }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))

        func hexRowD(_ bytes: [UInt8], _ off: Int, _ n: Int) {
            let end = min(off + n, bytes.count)
            for row in stride(from: off, to: end, by: 16) {
                let rowEnd = min(row + 16, end)
                let hexPart = (row..<rowEnd).map { String(format: "%02x", bytes[$0]) }.joined(separator: " ")
                let asciiPart = (row..<rowEnd).map { b -> Character in
                    let c = bytes[b]; return (c >= 0x20 && c < 0x7f) ? Character(UnicodeScalar(c)) : "."
                }
                print(String(format: "  %04x: %-47s  %@", row, hexPart, String(asciiPart)))
            }
        }

        // Convert to array for safe access
        let rawBytes = [UInt8](raw)

        print("═══ Raw PTX Header (first 0x40 bytes) ═══")
        hexRowD(rawBytes, 0, 0x40)
        print("  [0x12] format type: 0x\(String(format: "%02x", rawBytes[0x12]))")
        print("  [0x13] XOR seed:    0x\(String(format: "%02x", rawBytes[0x13]))")

        var t = [UInt8](repeating: 0, count: 256)
        let xv = rawBytes[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
        for i: UInt16 in 0...255 { if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break } }
        for i in 0..<256 { t[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
        var decrypted = rawBytes
        for i in 0..<rawBytes.count { decrypted[i] = rawBytes[i] ^ t[(i >> 12) & 0xff] }

        print("\n═══ 0x1028 content @4382 (137 bytes) ═══")
        hexRowD(decrypted, 4382, 137)
        let sr = UInt32(decrypted[4384]) | UInt32(decrypted[4385]) << 8 | UInt32(decrypted[4386]) << 16 | UInt32(decrypted[4387]) << 24
        print("  byte[0]=0x\(String(format:"%02x",decrypted[4382])) byte[1]=0x\(String(format:"%02x",decrypted[4383])) sr=\(sr)")

        print("\n═══ 0x1001 #1 @6769 (33 bytes) ═══")
        hexRowD(decrypted, 6769, 33)
        let sr1 = UInt32(decrypted[6769]) | UInt32(decrypted[6770]) << 8 | UInt32(decrypted[6771]) << 16 | UInt32(decrypted[6772]) << 24
        print("  → sr=\(sr1) channels=\(decrypted[6773]) bitdepth=\(decrypted[6774])")
    }
}
