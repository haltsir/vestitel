import Foundation

/// Minimal gzip (RFC 1952) framing over Foundation's raw-DEFLATE codec, so
/// the sync document is a genuine .gz file (`gunzip` opens it) without a
/// zlib dependency. The sync document is ~1.4 MB of JSON and compresses
/// about five-fold (to ~280 KB in 20 ms); a smaller upload finishes before
/// the cloud client's next hiccup and is rewritten less often mid-transfer.
enum Gzip {
    private static let magic: [UInt8] = [0x1f, 0x8b]

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 18 && data[data.startIndex] == magic[0] && data[data.startIndex + 1] == magic[1]
    }

    static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data(capacity: deflated.count + 18)
        // ID1 ID2 CM(deflate) FLG MTIME(4, unset) XFL OS(unix)
        out.append(contentsOf: magic + [0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflated)
        out.append(littleEndian: crc32(data))
        out.append(littleEndian: UInt32(truncatingIfNeeded: data.count))
        return out
    }

    /// nil for anything that is not a complete, intact gzip member: a torn
    /// read of a file mid-write must be rejected, never half-decoded.
    static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == magic[0], bytes[1] == magic[1], bytes[2] == 0x08 else { return nil }
        let flags = bytes[3]
        var i = 10
        if flags & 0x04 != 0 {   // FEXTRA
            guard i + 2 <= bytes.count else { return nil }
            i += 2 + Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {   // FNAME, FCOMMENT: zero-terminated
            guard let end = bytes[i...].firstIndex(of: 0) else { return nil }
            i = end + 1
        }
        if flags & 0x02 != 0 { i += 2 }   // FHCRC
        guard i + 8 <= bytes.count else { return nil }
        let body = Data(bytes[i ..< bytes.count - 8])
        guard let inflated = try? (body as NSData).decompressed(using: .zlib) as Data else { return nil }
        let expectedCRC = readLittleEndian(bytes, at: bytes.count - 8)
        let expectedSize = readLittleEndian(bytes, at: bytes.count - 4)
        guard crc32(inflated) == expectedCRC,
              UInt32(truncatingIfNeeded: inflated.count) == expectedSize else { return nil }
        return inflated
    }

    private static func readLittleEndian(_ bytes: [UInt8], at i: Int) -> UInt32 {
        UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
