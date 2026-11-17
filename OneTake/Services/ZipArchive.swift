import Foundation
import Compression
import zlib

/// Writes standards-compliant, store-only ZIP archives without loading large media into memory,
/// and safely reads/extracts store (`method == 0`) and deflate (`method == 8`) ZIP archives
/// via their Central Directory (supporting bit-3 Data Descriptors with bounded allocations).
nonisolated enum ZipArchive {
    struct Entry: Sendable {
        let name: String
        let fileURL: URL
    }

    enum ArchiveError: LocalizedError, Sendable {
        case tooLarge(String)
        case invalid(String)
        case unsupported(String)
        case entryNotFound(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name): return "\(name) is too large to include in this ZIP archive."
            case .invalid(let reason): return "This archive is invalid: \(reason)"
            case .unsupported(let reason): return "This ZIP format is not supported: \(reason)"
            case .entryNotFound(let name): return "Entry '\(name)' was not found in the archive."
            }
        }
    }

    private struct CentralEntry {
        let name: Data
        let checksum: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private struct CentralDirectoryEntry {
        let name: String
        let flags: UInt16
        let method: UInt16
        let checksum: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    // MARK: - Random-Access Reader Abstraction

    private protocol RandomAccessReader {
        var size: UInt64 { get }
        func read(at offset: UInt64, count: Int) throws -> Data
    }

    private final class FileHandleReader: RandomAccessReader {
        let handle: FileHandle
        let size: UInt64

        init(handle: FileHandle, size: UInt64) {
            self.handle = handle
            self.size = size
        }

        func read(at offset: UInt64, count: Int) throws -> Data {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
                throw ArchiveError.invalid("file ended unexpectedly")
            }
            if count == 0 { return Data() }
            try handle.seek(toOffset: offset)
            var result = Data()
            result.reserveCapacity(count)
            while result.count < count {
                guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                    throw ArchiveError.invalid("file ended unexpectedly")
                }
                result.append(chunk)
            }
            return result
        }
    }

    private struct DataReader: RandomAccessReader {
        let data: Data
        var size: UInt64 { UInt64(data.count) }

        func read(at offset: UInt64, count: Int) throws -> Data {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
                throw ArchiveError.invalid("archive ended unexpectedly")
            }
            if count == 0 { return Data() }
            let start = data.startIndex + Int(offset)
            let end = start + count
            return data.subdata(in: start..<end)
        }
    }

    // MARK: - Streaming Writer

    static func write(_ entries: [Entry], to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scratch = url.deletingLastPathComponent().appendingPathComponent(".zip-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: scratch) }

        let output = try FileHandle(forWritingTo: createEmptyFile(at: scratch))
        defer { try? output.close() }
        var centralEntries: [CentralEntry] = []
        var offset: UInt64 = 0

        for entry in entries {
            let attrs = try manager.attributesOfItem(atPath: entry.fileURL.path)
            guard let fileSize = attrs[.size] as? NSNumber, fileSize.uint64Value <= UInt32.max,
                  offset <= UInt32.max else { throw ArchiveError.tooLarge(entry.name) }
            let size = UInt32(fileSize.uint64Value)
            let name = Data(entry.name.utf8)
            guard name.count <= UInt16.max else { throw ArchiveError.tooLarge(entry.name) }
            let checksum = try crc32(of: entry.fileURL)

            var header = Data()
            appendUInt32(0x04034b50, to: &header)
            appendUInt16(20, to: &header)
            appendUInt16(0x0800, to: &header) // UTF-8 file name
            appendUInt16(0, to: &header)      // store, no compression
            appendUInt16(0, to: &header); appendUInt16(0, to: &header)
            appendUInt32(checksum, to: &header)
            appendUInt32(size, to: &header); appendUInt32(size, to: &header)
            appendUInt16(UInt16(name.count), to: &header); appendUInt16(0, to: &header)
            header.append(name)
            try output.write(contentsOf: header)
            offset += UInt64(header.count)
            try copy(entry.fileURL, to: output)
            centralEntries.append(CentralEntry(name: name, checksum: checksum, size: size, offset: UInt32(offset - UInt64(header.count))))
            offset += UInt64(size)
        }

        guard centralEntries.count <= Int(UInt16.max), offset <= UInt32.max else {
            throw ArchiveError.tooLarge(url.lastPathComponent)
        }
        let centralStart = UInt32(offset)
        for entry in centralEntries {
            var record = Data()
            appendUInt32(0x02014b50, to: &record)
            appendUInt16(20, to: &record); appendUInt16(20, to: &record)
            appendUInt16(0x0800, to: &record); appendUInt16(0, to: &record)
            appendUInt16(0, to: &record); appendUInt16(0, to: &record)
            appendUInt32(entry.checksum, to: &record)
            appendUInt32(entry.size, to: &record); appendUInt32(entry.size, to: &record)
            appendUInt16(UInt16(entry.name.count), to: &record)
            appendUInt16(0, to: &record); appendUInt16(0, to: &record)
            appendUInt16(0, to: &record); appendUInt16(0, to: &record)
            appendUInt32(0, to: &record); appendUInt32(entry.offset, to: &record)
            record.append(entry.name)
            try output.write(contentsOf: record)
            offset += UInt64(record.count)
        }
        let centralSize = UInt32(offset - UInt64(centralStart))
        var end = Data()
        appendUInt32(0x06054b50, to: &end)
        appendUInt16(0, to: &end); appendUInt16(0, to: &end)
        appendUInt16(UInt16(centralEntries.count), to: &end)
        appendUInt16(UInt16(centralEntries.count), to: &end)
        appendUInt32(centralSize, to: &end); appendUInt32(centralStart, to: &end)
        appendUInt16(0, to: &end)
        try output.write(contentsOf: end)
        try output.synchronize()
        try? manager.removeItem(at: url)
        try manager.moveItem(at: scratch, to: url)
    }

    static func write(_ entries: [(name: String, data: Data)], to url: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        var fileEntries: [Entry] = []
        for (idx, item) in entries.enumerated() {
            let fileURL = tempDir.appendingPathComponent("\(idx)_\(item.name.replacingOccurrences(of: "/", with: "_"))")
            try item.data.write(to: fileURL)
            fileEntries.append(Entry(name: item.name, fileURL: fileURL))
        }
        try write(fileEntries, to: url)
    }

    // MARK: - Archive Extraction (File URL)

    /// Extracts store (`method == 0`) and deflate (`method == 8`) ZIP archives (including streaming
    /// entries whose sizes live in the central directory). Paths are validated before writing so an
    /// imported archive cannot escape its staging directory.
    static func extract(
        from archiveURL: URL,
        to destination: URL,
        maxExtractedBytes: UInt64 = 8 * 1024 * 1024 * 1024,
        maxEntryCount: Int = 20_000
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let input = try FileHandle(forReadingFrom: archiveURL)
        var succeeded = false
        defer {
            try? input.close()
            if !succeeded { try? manager.removeItem(at: destination) }
        }

        let archiveSize = UInt64((try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let reader = FileHandleReader(handle: input, size: archiveSize)
        let entries = try readCentralDirectory(from: reader, maxEntryCount: maxEntryCount)
        guard !entries.isEmpty else { throw ArchiveError.invalid("archive is empty") }

        var extractedBytes: UInt64 = 0
        var entryCount = 0
        let resolvedRootURL = destination.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRootPath = resolvedRootURL.path
        let standardizedRoot = resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/"

        for entry in entries {
            try validateEntry(entry)

            let components = entry.name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !entry.name.hasPrefix("/"), !entry.name.contains("\\"), !components.isEmpty,
                  components.allSatisfy({ $0 != "." && $0 != ".." }) else {
                throw ArchiveError.invalid("unsafe file path")
            }

            let dataStart = try resolveDataStart(for: entry, reader: reader)

            let (addedBytes, overflow) = extractedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, addedBytes <= maxExtractedBytes, entryCount < maxEntryCount else {
                throw ArchiveError.tooLarge(entry.name)
            }
            extractedBytes = addedBytes
            entryCount += 1

            let outputURL = components.reduce(resolvedRootURL) { $0.appendingPathComponent($1) }
            guard outputURL.standardizedFileURL.path.hasPrefix(standardizedRoot) else {
                throw ArchiveError.invalid("unsafe file path")
            }

            if entry.name.hasSuffix("/") {
                try manager.createDirectory(at: outputURL, withIntermediateDirectories: true)
            } else {
                try manager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard manager.createFile(atPath: outputURL.path, contents: nil) else {
                    throw ArchiveError.invalid("could not create an extracted file")
                }
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close() }
                try extractEntryPayload(entry, from: reader, dataStart: dataStart, maxBytes: maxExtractedBytes) { chunk in
                    try output.write(contentsOf: chunk)
                }
                try output.synchronize()
                guard try crc32(of: outputURL) == entry.checksum else {
                    throw ArchiveError.invalid("checksum mismatch for \(entry.name)")
                }
            }
        }

        succeeded = true
    }

    // MARK: - Single Entry Reader (In-Memory Data)

    /// Reads and verifies a single entry (e.g. `word/document.xml` from a `.docx`) from in-memory ZIP data,
    /// using the Central Directory and bounded DEFLATE decoding.
    static func readEntry(
        named targetName: String,
        from archiveData: Data,
        maxEntryBytes: UInt64 = 64 * 1024 * 1024,
        maxEntryCount: Int = 20_000
    ) throws -> Data {
        let reader = DataReader(data: archiveData)
        let entries = try readCentralDirectory(from: reader, maxEntryCount: maxEntryCount)
        guard let entry = entries.first(where: { $0.name == targetName }) else {
            throw ArchiveError.entryNotFound(targetName)
        }

        try validateEntry(entry)
        guard entry.uncompressedSize <= maxEntryBytes else {
            throw ArchiveError.tooLarge(entry.name)
        }

        let dataStart = try resolveDataStart(for: entry, reader: reader)
        var result = Data()
        result.reserveCapacity(Int(min(entry.uncompressedSize, maxEntryBytes)))

        try extractEntryPayload(entry, from: reader, dataStart: dataStart, maxBytes: maxEntryBytes) { chunk in
            result.append(chunk)
        }

        guard crc32(result) == entry.checksum else {
            throw ArchiveError.invalid("checksum mismatch for \(entry.name)")
        }
        return result
    }

    // MARK: - Shared Central Directory & Payload Helpers

    private static func validateEntry(_ entry: CentralDirectoryEntry) throws {
        guard entry.flags & 0x0001 == 0 else {
            throw ArchiveError.unsupported("encrypted entries")
        }
        guard entry.method == 0 || entry.method == 8 else {
            throw ArchiveError.unsupported("compression method \(entry.method)")
        }
        if entry.method == 0 && entry.compressedSize != entry.uncompressedSize {
            throw ArchiveError.invalid("mismatched store entry sizes")
        }
    }

    private static func resolveDataStart(for entry: CentralDirectoryEntry, reader: RandomAccessReader) throws -> UInt64 {
        guard entry.localHeaderOffset + 30 <= reader.size else {
            throw ArchiveError.invalid("local header extends beyond archive")
        }
        let localHeader = try reader.read(at: entry.localHeaderOffset, count: 30)
        guard readUInt32(localHeader, at: 0) == 0x04034b50 else {
            throw ArchiveError.invalid("unexpected ZIP local header")
        }
        let localNameLength = UInt64(readUInt16(localHeader, at: 26))
        let localExtraLength = UInt64(readUInt16(localHeader, at: 28))
        let dataStart = entry.localHeaderOffset + 30 + localNameLength + localExtraLength
        guard dataStart <= reader.size, entry.compressedSize <= reader.size - dataStart else {
            throw ArchiveError.invalid("entry extends beyond the archive")
        }
        return dataStart
    }

    private static func extractEntryPayload(
        _ entry: CentralDirectoryEntry,
        from reader: RandomAccessReader,
        dataStart: UInt64,
        maxBytes: UInt64,
        writeChunk: (Data) throws -> Void
    ) throws {
        if entry.method == 0 {
            var remaining = entry.compressedSize
            var offset = dataStart
            var written: UInt64 = 0
            while remaining > 0 {
                let count = Int(min(remaining, 1024 * 1024))
                let chunk = try reader.read(at: offset, count: count)
                written += UInt64(chunk.count)
                guard written <= maxBytes else {
                    throw ArchiveError.tooLarge(entry.name)
                }
                try writeChunk(chunk)
                offset += UInt64(count)
                remaining -= UInt64(count)
            }
        } else {
            try decompressDeflateEntry(
                from: reader,
                dataStart: dataStart,
                compressedSize: entry.compressedSize,
                expectedUncompressedSize: entry.uncompressedSize,
                maxBytes: maxBytes,
                writeChunk: writeChunk
            )
        }
    }

    private static func readCentralDirectory(
        from reader: RandomAccessReader,
        maxEntryCount: Int
    ) throws -> [CentralDirectoryEntry] {
        let archiveSize = reader.size
        guard archiveSize >= 22 else {
            throw ArchiveError.invalid("archive too small")
        }
        let searchWindow = Int(min(archiveSize, 65_557))
        let windowStart = archiveSize - UInt64(searchWindow)
        let tail = try reader.read(at: windowStart, count: searchWindow)

        var eocdOffsetInTail: Int?
        for idx in stride(from: tail.count - 22, through: 0, by: -1) {
            if readUInt32(tail, at: idx) == 0x06054b50 {
                let commentLength = Int(readUInt16(tail, at: idx + 20))
                if idx + 22 + commentLength == tail.count {
                    eocdOffsetInTail = idx
                    break
                }
            }
        }
        guard let eocdIdx = eocdOffsetInTail else {
            throw ArchiveError.invalid("missing end of central directory")
        }

        let totalEntries = Int(readUInt16(tail, at: eocdIdx + 10))
        let centralSize = UInt64(readUInt32(tail, at: eocdIdx + 12))
        let centralOffset = UInt64(readUInt32(tail, at: eocdIdx + 16))
        guard centralOffset <= archiveSize, centralSize <= archiveSize - centralOffset else {
            throw ArchiveError.invalid("central directory extends beyond archive")
        }
        guard totalEntries <= maxEntryCount else {
            throw ArchiveError.tooLarge("archive")
        }

        var cursor = centralOffset
        var entries: [CentralDirectoryEntry] = []
        entries.reserveCapacity(totalEntries)

        for _ in 0..<totalEntries {
            let record = try reader.read(at: cursor, count: 46)
            cursor += 46
            guard readUInt32(record, at: 0) == 0x02014b50 else {
                throw ArchiveError.invalid("unexpected central directory record")
            }
            let flags = readUInt16(record, at: 8)
            let method = readUInt16(record, at: 10)
            let checksum = readUInt32(record, at: 16)
            let compressedSize = UInt64(readUInt32(record, at: 20))
            let uncompressedSize = UInt64(readUInt32(record, at: 24))
            let nameLength = Int(readUInt16(record, at: 28))
            let extraLength = Int(readUInt16(record, at: 30))
            let commentLength = Int(readUInt16(record, at: 32))
            let localOffset = UInt64(readUInt32(record, at: 42))

            let nameData = try reader.read(at: cursor, count: nameLength)
            cursor += UInt64(nameLength)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ArchiveError.invalid("file name is not UTF-8")
            }
            cursor += UInt64(extraLength + commentLength)

            entries.append(CentralDirectoryEntry(
                name: name,
                flags: flags,
                method: method,
                checksum: checksum,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))
        }
        return entries
    }

    private static func decompressDeflateEntry(
        from reader: RandomAccessReader,
        dataStart: UInt64,
        compressedSize: UInt64,
        expectedUncompressedSize: UInt64,
        maxBytes: UInt64,
        writeChunk: (Data) throws -> Void
    ) throws {
        if compressedSize == 0 && expectedUncompressedSize == 0 {
            return
        }
        let sentinel = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { sentinel.deallocate() }
        var stream = compression_stream(dst_ptr: sentinel, dst_size: 0, src_ptr: sentinel, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw ArchiveError.invalid("unable to initialize deflate decoder")
        }
        defer { compression_stream_destroy(&stream) }

        let chunkSize = 64 * 1024
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        var remaining = compressedSize
        var offset = dataStart
        var totalWritten: UInt64 = 0
        var inBuffer = Data()
        var inOffset = 0

        while true {
            if inOffset >= inBuffer.count && remaining > 0 {
                let toRead = Int(min(remaining, UInt64(chunkSize)))
                inBuffer = try reader.read(at: offset, count: toRead)
                offset += UInt64(toRead)
                remaining -= UInt64(toRead)
                inOffset = 0
            }

            let processFlags: Int32 = (remaining == 0) ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status: compression_status = try inBuffer.withUnsafeBytes { rawIn -> compression_status in
                let inBase = rawIn.bindMemory(to: UInt8.self).baseAddress
                return try outBuffer.withUnsafeMutableBufferPointer { rawOut -> compression_status in
                    guard let outBase = rawOut.baseAddress else {
                        throw ArchiveError.invalid("output buffer allocation failed")
                    }
                    stream.src_ptr = inBase.map { $0.advanced(by: inOffset) } ?? UnsafePointer(sentinel)
                    stream.src_size = inBuffer.count - inOffset
                    stream.dst_ptr = outBase
                    stream.dst_size = chunkSize

                    let s = compression_stream_process(&stream, processFlags)
                    let consumed = (inBuffer.count - inOffset) - stream.src_size
                    inOffset += consumed
                    let produced = chunkSize - stream.dst_size
                    if produced > 0 {
                        totalWritten += UInt64(produced)
                        if totalWritten > maxBytes || totalWritten > expectedUncompressedSize + 1024 * 1024 {
                            throw ArchiveError.invalid("deflated output exceeds declared size")
                        }
                        try writeChunk(Data(rawOut[0..<produced]))
                    }
                    return s
                }
            }

            if status == COMPRESSION_STATUS_ERROR {
                throw ArchiveError.invalid("corrupt deflate stream")
            }
            if status == COMPRESSION_STATUS_END {
                break
            }
            if remaining == 0 && inOffset >= inBuffer.count && stream.dst_size > 0 {
                throw ArchiveError.invalid("unexpected end of deflate stream")
            }
        }

        if totalWritten != expectedUncompressedSize {
            throw ArchiveError.invalid("uncompressed size mismatch")
        }
    }

    // MARK: - Low-Level I/O & CRC32

    private static func createEmptyFile(at url: URL) throws -> URL {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private static func copy(_ source: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            guard let ptr = raw.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(zlib.crc32(0, ptr, uInt(raw.count)))
        }
    }

    static func crc32(of data: Data) -> UInt32 {
        crc32(data)
    }

    static func crc32(of url: URL) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc: uLong = zlib.crc32(0, nil, 0)
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            crc = chunk.withUnsafeBytes { raw -> uLong in
                guard let ptr = raw.bindMemory(to: Bytef.self).baseAddress else { return crc }
                return zlib.crc32(crc, ptr, uInt(raw.count))
            }
        }
        return UInt32(crc)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        appendUInt16(UInt16(value & 0xffff), to: &data)
        appendUInt16(UInt16(value >> 16), to: &data)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let idx = data.startIndex + offset
        return UInt16(data[idx]) | (UInt16(data[idx + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(readUInt16(data, at: offset)) | (UInt32(readUInt16(data, at: offset + 2)) << 16)
    }
}
