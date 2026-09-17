import Compression
import Foundation

/// Reads files from a ZIP archive held in memory, such as a PowerPoint (.pptx) file.
/// Supports stored and deflated entries, which is all Office files use.
nonisolated struct ZipArchive {
    enum ZipError: Error {
        case notAZipFile
        case corrupt
        case unsupportedCompression(Int)
        case entryTooLarge
    }

    struct Entry {
        let path: String
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Entries larger than this aren't extracted, to guard against malformed or hostile files.
    static let maxEntrySize = 64 * 1024 * 1024

    private let data: Data
    let entries: [String: Entry]

    init(data: Data) throws {
        self.data = data
        entries = try Self.readCentralDirectory(data)
    }

    static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
    }

    var paths: [String] { Array(entries.keys) }

    func contains(_ path: String) -> Bool { entries[path] != nil }

    func data(for path: String) throws -> Data? {
        guard let entry = entries[path] else { return nil }
        guard entry.uncompressedSize <= Self.maxEntrySize, entry.compressedSize <= Self.maxEntrySize else {
            throw ZipError.entryTooLarge
        }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, readUInt32(at: header) == 0x0403_4B50 else { throw ZipError.corrupt }
        let start = header + 30 + Int(readUInt16(at: header + 26)) + Int(readUInt16(at: header + 28))
        guard start + entry.compressedSize <= data.count else { throw ZipError.corrupt }
        let compressed = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))

        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try Self.inflate(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupportedCompression(entry.method)
        }
    }

    func string(for path: String) throws -> String? {
        try data(for: path).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Parsing

    private static func readCentralDirectory(_ data: Data) throws -> [String: Entry] {
        guard data.count >= 22 else { throw ZipError.notAZipFile }
        let reader = ByteReader(data: data)

        // The end-of-central-directory record sits in the last 22 bytes plus an optional comment.
        let searchStart = max(0, data.count - 22 - 65_535)
        var endRecord: Int?
        var offset = data.count - 22
        while offset >= searchStart {
            if reader.uint32(at: offset) == 0x0605_4B50 {
                endRecord = offset
                break
            }
            offset -= 1
        }
        guard let endRecord else { throw ZipError.notAZipFile }

        var entryCount = Int(reader.uint16(at: endRecord + 10))
        var directoryOffset = Int(reader.uint32(at: endRecord + 16))

        // ZIP64 archives point to a second end record.
        if (entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF), endRecord >= 20,
           reader.uint32(at: endRecord - 20) == 0x0706_4B50 {
            let zip64Record = Int(reader.uint64(at: endRecord - 12))
            guard zip64Record + 56 <= data.count, reader.uint32(at: zip64Record) == 0x0606_4B50 else {
                throw ZipError.corrupt
            }
            entryCount = Int(reader.uint64(at: zip64Record + 32))
            directoryOffset = Int(reader.uint64(at: zip64Record + 48))
        }

        var entries: [String: Entry] = [:]
        var position = directoryOffset
        for _ in 0..<entryCount {
            guard position + 46 <= data.count, reader.uint32(at: position) == 0x0201_4B50 else {
                throw ZipError.corrupt
            }
            let method = Int(reader.uint16(at: position + 10))
            var compressedSize = Int(reader.uint32(at: position + 20))
            var uncompressedSize = Int(reader.uint32(at: position + 24))
            let nameLength = Int(reader.uint16(at: position + 28))
            let extraLength = Int(reader.uint16(at: position + 30))
            let commentLength = Int(reader.uint16(at: position + 32))
            var localOffset = Int(reader.uint32(at: position + 42))
            let nameStart = position + 46
            guard nameStart + nameLength + extraLength <= data.count else { throw ZipError.corrupt }

            let nameData = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)

            // ZIP64 sizes and offsets live in extra field 0x0001, in this order, when needed.
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = reader.uint16(at: extra)
                let size = Int(reader.uint16(at: extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if uncompressedSize == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        uncompressedSize = Int(reader.uint64(at: field)); field += 8
                    }
                    if compressedSize == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        compressedSize = Int(reader.uint64(at: field)); field += 8
                    }
                    if localOffset == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        localOffset = Int(reader.uint64(at: field))
                    }
                }
                extra += 4 + size
            }

            if !name.hasSuffix("/") {
                entries[name] = Entry(
                    path: name,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localOffset
                )
            }
            position = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0, !compressed.isEmpty else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                // COMPRESSION_ZLIB is raw DEFLATE, which is what ZIP stores.
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    source.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw ZipError.corrupt }
        return output
    }

    private func readUInt16(at offset: Int) -> UInt16 { ByteReader(data: data).uint16(at: offset) }
    private func readUInt32(at offset: Int) -> UInt32 { ByteReader(data: data).uint32(at: offset) }
}

/// Little-endian integer reads that return 0 past the end instead of trapping.
nonisolated private struct ByteReader {
    let data: Data

    func uint16(at offset: Int) -> UInt16 { UInt16(truncatingIfNeeded: value(at: offset, size: 2)) }
    func uint32(at offset: Int) -> UInt32 { UInt32(truncatingIfNeeded: value(at: offset, size: 4)) }
    func uint64(at offset: Int) -> UInt64 { value(at: offset, size: 8) }

    private func value(at offset: Int, size: Int) -> UInt64 {
        guard offset >= 0, offset + size <= data.count else { return 0 }
        var result: UInt64 = 0
        for index in 0..<size {
            result |= UInt64(data[data.startIndex + offset + index]) << (8 * UInt64(index))
        }
        return result
    }
}
