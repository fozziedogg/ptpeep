import Foundation

// Find the 0x1028 block and print its raw bytes, to verify TC frame rate reading.
// Also print what PTXBlockDecoder.extractSessionParams would return.

func run() {
    guard CommandLine.arguments.count > 1 else { print("Usage: find_tc_rate <file.ptx>"); exit(1) }
    guard let raw = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
        print("Cannot read file"); exit(1)
    }
    let n = raw.count

    // XOR decode
    let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
    for i: UInt16 in 0...255 {
        if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break }
    }
    var table = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 { table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
    var d = raw
    d.withUnsafeMutableBytes { dst in
        raw.withUnsafeBytes { src in
            let dPtr = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let sPtr = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var off = 4096
            while off < n {
                let xorByte = table[(off >> 12) & 0xff]
                if xorByte != 0 {
                    let end = min(off + 4096, n)
                    for j in off..<end { dPtr[j] = sPtr[j] ^ xorByte }
                }
                off += 4096
            }
        }
    }

    func byte(_ i: Int) -> UInt8 {
        d.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self)[i] }
    }
    func u16(_ i: Int) -> UInt16 { UInt16(byte(i)) | UInt16(byte(i+1)) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(byte(i)) | UInt32(byte(i+1)) << 8 | UInt32(byte(i+2)) << 16 | UInt32(byte(i+3)) << 24 }
    func hex(_ i: Int, _ count: Int) -> String {
        (0..<min(count, n-i)).map { String(format: "%02x", byte(i+$0)) }.joined(separator: " ")
    }

    // Find 0x1028 block
    var i = 0x1f
    var found1028 = false
    var found1001count = 0
    while i + 9 <= n {
        guard byte(i) == 0x5a else { i += 1; continue }
        let sz = Int(u32(i + 3))
        let ct = u16(i + 7)
        guard sz > 0, sz < 50_000_000, i + 9 + sz <= n else { i += 1; continue }
        let dataOff = i + 9

        if ct == 0x1001 && found1001count < 3 {
            print("0x1001 @\(dataOff) size=\(sz): \(hex(dataOff, min(sz, 32)))")
            let sr = u32(dataOff)
            let bd = byte(dataOff + 5)
            print("  → sr=\(sr) bd=\(bd)")
            found1001count += 1
        }

        if ct == 0x1028 && !found1028 {
            found1028 = true
            print("\n0x1028 @\(dataOff) size=\(sz)")
            print("Full hex: \(hex(dataOff, min(sz, 256)))")
            // Try to parse: skip 12 bytes for unknown fields, then u32 componentCount at +12
            if sz >= 16 {
                let compCount = Int(u32(dataOff + 12))
                print("componentCount @+12 = \(compCount)")
                if compCount >= 0 && compCount <= 20 {
                    var pos = dataOff + 16
                    for ci in 0..<compCount {
                        guard pos + 4 <= dataOff + sz else { break }
                        let len = Int(u32(pos))
                        guard len <= 512, pos + 4 + len <= dataOff + sz else { break }
                        let s = String(bytes: d[pos+4..<pos+4+len], encoding: .utf8) ?? "<binary>"
                        print("  path[\(ci)]: '\(s)'")
                        pos += 4 + len
                    }
                    print("After paths, pos=\(pos), remaining=\(dataOff + sz - pos)")
                    // Print next 20 bytes
                    print("Next bytes: \(hex(pos, 20))")
                    // Try TC offset: +5 zeros + 3 bytes + 1 flag + 1 TC byte
                    let tcOff = pos + 5 + 3 + 1
                    if tcOff < dataOff + sz {
                        let tcByte = byte(tcOff)
                        print("TC byte @tcOff=\(tcOff) (pos+9): 0x\(String(format: "%02x", tcByte)) = \(tcByte)")
                        // Also show surrounding context
                        print("Context: \(hex(pos, min(16, dataOff + sz - pos)))")
                    }
                }
            }
        }
        i += 1
    }

    if !found1028 { print("No 0x1028 block found!") }
}
run()
