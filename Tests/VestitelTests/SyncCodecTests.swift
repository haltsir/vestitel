import Foundation
import Testing
@testable import Vestitel

/// The sync document is gzip-framed since 1.27 (`Gzip`), plain JSON before;
/// both must decode, torn files must not, and the .gz must be a genuine
/// one so a user can gunzip it.
struct SyncCodecTests {
    private static let sample = Data(String(repeating: "{\"title\":\"Паста в червено\",\"n\":12345}\n", count: 400).utf8)

    @Test func gzipRoundTrips() throws {
        let gz = try #require(Gzip.compress(Self.sample))
        #expect(Gzip.isGzip(gz))
        #expect(!Gzip.isGzip(Self.sample))
        #expect(gz.count < Self.sample.count / 4)
        #expect(Gzip.decompress(gz) == Self.sample)
    }

    @Test func gzipIsGenuine() throws {
        // the system gunzip must accept what we wrote
        let gz = try #require(Gzip.compress(Self.sample))
        let out = try Self.run("/usr/bin/gunzip", ["-c"], input: gz)
        #expect(out == Self.sample)
    }

    @Test func gzipWithFileNameHeaderDecodes() throws {
        // `gzip <file>` writes an FNAME header (flag 0x08); the reader must
        // skip it, e.g. when a user hand-compresses a legacy .json
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.json")
        try Self.sample.write(to: file)
        _ = try Self.run("/usr/bin/gzip", [file.path], input: nil)
        let gz = try Data(contentsOf: dir.appendingPathComponent("doc.json.gz"))
        #expect(gz[gz.startIndex + 3] & 0x08 != 0)
        #expect(Gzip.decompress(gz) == Self.sample)
    }

    @Test func tornOrCorruptGzipIsRejected() throws {
        let gz = try #require(Gzip.compress(Self.sample))
        #expect(Gzip.decompress(gz.prefix(gz.count - 20)) == nil)   // cut mid-write
        var flipped = gz
        flipped[flipped.startIndex + 30] ^= 0xFF                       // body damage: CRC must catch it
        #expect(Gzip.decompress(flipped) == nil)
        #expect(Gzip.decompress(Self.sample) == nil)                    // not gzip at all
    }

    @MainActor
    @Test func syncDocumentDecodesBothGenerations() throws {
        let doc = SyncDocument(
            machineID: "M1", machineName: "Test", updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            feeds: [], articles: [], seen: ["a": Date(timeIntervalSince1970: 1_789_000_000)],
            archive: [], bookmarks: [], removedFeeds: [:], removedBookmarks: [:],
            archiveClearedAt: nil, settings: nil, settingsUpdatedAt: nil
        )
        let json = try AppStore.syncEncoder().encode(doc)
        let plain = try #require(AppStore.decodeSyncDocument(json))
        #expect(plain.machineID == "M1")
        #expect(plain.seen["a"] == doc.seen["a"])
        let gz = try #require(Gzip.compress(json))
        let fromGz = try #require(AppStore.decodeSyncDocument(gz))
        #expect(fromGz.updatedAt == doc.updatedAt)
        #expect(AppStore.decodeSyncDocument(Data("{not json".utf8)) == nil)
    }

    @Test func syncFileNames() {
        #expect(AppStore.isSyncFileName("vestitel-ABC.json"))
        #expect(AppStore.isSyncFileName("vestitel-ABC.json.gz"))
        #expect(!AppStore.isSyncFileName("vestitel-ABC.json.tmp"))
        #expect(!AppStore.isSyncFileName("notes.json"))
    }

    @MainActor
    @Test func lostAndFoundScanFindsSyncFiles() throws {
        // Google Drive's layout: <root>/<account id>/<file>, plus its own
        // bookkeeping text file, which must not be reported
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let account = root.appendingPathComponent("105364842527627657670")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: account.appendingPathComponent("vestitel-M1.json"))
        try Data("x".utf8).write(to: account.appendingPathComponent("lost_and_found_data.txt"))
        try Data("x".utf8).write(to: account.appendingPathComponent("Report.pdf"))
        try Data("x".utf8).write(to: root.appendingPathComponent("vestitel-stray.json"))   // wrong level
        let copies = AppStore.lostAndFoundCopies(under: root)
        #expect(copies.map(\.url.lastPathComponent) == ["vestitel-M1.json"])
        #expect(AppStore.lostAndFoundCopies(under: root.appendingPathComponent("missing")).isEmpty)
    }

    private static func run(_ tool: String, _ args: [String], input: Data?) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return out
    }
}
