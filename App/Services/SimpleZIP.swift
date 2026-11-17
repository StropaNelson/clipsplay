import Foundation

// ZIP simples sem compressão (método Store), compatível com Arquivos/iPadOS.
enum SimpleZIP {
    struct Entry {
        enum Content {
            case data(Data)
            case file(URL)
        }

        let name: String
        let content: Content

        init(name: String, data: Data) {
            self.name = name
            self.content = .data(data)
        }

        init(name: String, fileURL: URL) {
            self.name = name
            self.content = .file(fileURL)
        }
    }

    static func make(from files: [URL]) throws -> Data {
        try make(entries: files.map { Entry(name: $0.lastPathComponent, fileURL: $0) })
    }

    static func make(entries: [Entry]) throws -> Data {
        var output = Data()
        var central = Data()
        for entry in entries {
            let content = try entry.data()
            try appendEntry(entry, content: content, output: &output, central: &central)
        }
        try appendCentral(central, count: entries.count, output: &output)
        return output
    }

    /// Writes the same store-only ZIP directly to disk, avoiding a full copy of
    /// source videos in memory while exporting project packages.
    static func write(entries: [Entry], to url: URL) throws {
        guard entries.count <= Int(UInt16.max) else { throw ZIPError.archiveTooLarge }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw ZIPError.writeFailed
        }
        let output = try FileHandle(forWritingTo: url)
        defer { output.closeFile() }

        var central = Data()
        for entry in entries {
            let name = entry.name.replacingOccurrences(of: "\\", with: "/")
            let nameData = Data(name.utf8)
            guard nameData.count <= Int(UInt16.max) else { throw ZIPError.archiveTooLarge }
            let offset = try zip32(output.offsetInFile)
            let metadata = try entry.metadata()
            guard metadata.size <= UInt64(UInt32.max) else { throw ZIPError.archiveTooLarge }
            let size = UInt32(metadata.size)
            var header = Data()
            header.appendLE(UInt32(0x04034b50))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(metadata.crc)
            header.appendLE(size)
            header.appendLE(size)
            header.appendLE(UInt16(nameData.count))
            header.appendLE(UInt16(0))
            header.append(nameData)
            output.write(header)
            try entry.writeContent(to: output)

            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(metadata.crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(nameData.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(offset)
            central.append(nameData)
        }
        guard central.count <= Int(UInt32.max) else { throw ZIPError.archiveTooLarge }
        let centralOffset = try zip32(output.offsetInFile)
        output.write(central)
        var end = Data()
        let count = try zip16(entries.count)
        end.appendLE(UInt32(0x06054b50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(count)
        end.appendLE(count)
        end.appendLE(try zip32(UInt64(central.count)))
        end.appendLE(centralOffset)
        end.appendLE(UInt16(0))
        output.write(end)
    }

    private static func appendEntry(_ entry: Entry, content: Data, output: inout Data, central: inout Data) throws {
        let name = entry.name.replacingOccurrences(of: "\\", with: "/")
        let nameData = Data(name.utf8)
        guard nameData.count <= Int(UInt16.max),
              content.count <= Int(UInt32.max),
              output.count <= Int(UInt32.max) else { throw ZIPError.archiveTooLarge }
        let crc = crc32(content)
        let offset = UInt32(output.count)
        let size = UInt32(content.count)

        output.appendLE(UInt32(0x04034b50))
        output.appendLE(UInt16(20))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(crc)
        output.appendLE(size)
        output.appendLE(size)
        output.appendLE(UInt16(nameData.count))
        output.appendLE(UInt16(0))
        output.append(nameData)
        output.append(content)

        central.appendLE(UInt32(0x02014b50))
        central.appendLE(UInt16(20))
        central.appendLE(UInt16(20))
        central.appendLE(UInt16(0))
        central.appendLE(UInt16(0))
        central.appendLE(UInt16(0))
        central.appendLE(UInt16(0))
        central.appendLE(crc)
        central.appendLE(size)
        central.appendLE(size)
        central.appendLE(UInt16(nameData.count))
        central.appendLE(UInt16(0))
        central.appendLE(UInt16(0))
        central.appendLE(UInt16(0))
        central.appendLE(UInt16(0))
        central.appendLE(UInt32(0))
        central.appendLE(offset)
        central.append(nameData)
    }

    private static func appendCentral(_ central: Data, count: Int, output: inout Data) throws {
        guard count <= Int(UInt16.max),
              central.count <= Int(UInt32.max),
              output.count <= Int(UInt32.max) else { throw ZIPError.archiveTooLarge }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.appendLE(UInt32(0x06054b50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(count))
        output.appendLE(UInt16(count))
        output.appendLE(UInt32(central.count))
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
    }
    
    /// Reads uncompressed ZIP archives created by `make(entries:)`. Method 0 is
    /// intentional: video projects can be large and the format stays debuggable.
    static func entries(from data: Data) throws -> [String: Data] {
        guard data.count >= 22 else { throw ZIPError.invalidArchive }
        let searchStart = max(0, data.count - 65_558)
        var centralOffset = -1
        var cursor = data.count - 22
        while cursor >= searchStart {
            if readLE(UInt32.self, at: cursor, in: data) == 0x06054b50 {
                centralOffset = cursor
                break
            }
            cursor -= 1
        }
        guard centralOffset >= 0,
              let count = readLE(UInt16.self, at: centralOffset + 10, in: data),
              let directoryOffset = readLE(UInt32.self, at: centralOffset + 16, in: data) else {
            throw ZIPError.invalidArchive
        }

        var entries: [String: Data] = [:]
        var offset = Int(directoryOffset)
        for _ in 0..<Int(count) {
            guard readLE(UInt32.self, at: offset, in: data) == 0x02014b50,
                  let method = readLE(UInt16.self, at: offset + 10, in: data),
                  let compressedSize = readLE(UInt32.self, at: offset + 20, in: data),
                  let nameLength = readLE(UInt16.self, at: offset + 28, in: data),
                  let extraLength = readLE(UInt16.self, at: offset + 30, in: data),
                  let commentLength = readLE(UInt16.self, at: offset + 32, in: data),
                  let localOffset = readLE(UInt32.self, at: offset + 42, in: data) else {
                throw ZIPError.invalidArchive
            }
            let nameStart = offset + 46
            guard nameStart + Int(nameLength) <= data.count,
                  let name = String(data: data.subdata(in: nameStart..<(nameStart + Int(nameLength))), encoding: .utf8) else {
                throw ZIPError.invalidArchive
            }
            guard method == 0 else { throw ZIPError.unsupportedCompression }
            guard readLE(UInt32.self, at: Int(localOffset), in: data) == 0x04034b50,
                  let localNameLength = readLE(UInt16.self, at: Int(localOffset) + 26, in: data),
                  let localExtraLength = readLE(UInt16.self, at: Int(localOffset) + 28, in: data) else {
                throw ZIPError.invalidArchive
            }
            let contentStart = Int(localOffset) + 30 + Int(localNameLength) + Int(localExtraLength)
            let contentEnd = contentStart + Int(compressedSize)
            guard contentStart >= 0, contentEnd <= data.count else { throw ZIPError.invalidArchive }
            entries[name] = data.subdata(in: contentStart..<contentEnd)
            offset = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
        return entries
    }

    /// Streams uncompressed package entries to disk instead of building a
    /// `[String: Data]` copy of a potentially multi-GB project archive.
    static func extractEntries(from archiveURL: URL, to destination: URL) throws -> [String: URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let input = try FileHandle(forReadingFrom: archiveURL)
        defer { input.closeFile() }

        let fileSize = input.seekToEndOfFile()
        guard fileSize >= 22 else { throw ZIPError.invalidArchive }
        let tailLength = min(fileSize, 65_558)
        input.seek(toFileOffset: fileSize - tailLength)
        let tail = input.readData(ofLength: Int(tailLength))
        var tailOffset = tail.count - 22
        var directoryStart: UInt64? = nil
        var entryCount = 0
        while tailOffset >= 0 {
            if readLE(UInt32.self, at: tailOffset, in: tail) == 0x06054b50 {
                guard let count = readLE(UInt16.self, at: tailOffset + 10, in: tail),
                      let offset = readLE(UInt32.self, at: tailOffset + 16, in: tail) else { break }
                entryCount = Int(count)
                directoryStart = UInt64(offset)
                break
            }
            tailOffset -= 1
        }
        guard var cursor = directoryStart else { throw ZIPError.invalidArchive }

        struct Record {
            let name: String
            let compressedSize: UInt64
            let localOffset: UInt64
        }
        var records: [Record] = []
        records.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            input.seek(toFileOffset: cursor)
            let header = input.readData(ofLength: 46)
            guard readLE(UInt32.self, at: 0, in: header) == 0x02014b50,
                  let method = readLE(UInt16.self, at: 10, in: header),
                  let compressedSize = readLE(UInt32.self, at: 20, in: header),
                  let nameLength = readLE(UInt16.self, at: 28, in: header),
                  let extraLength = readLE(UInt16.self, at: 30, in: header),
                  let commentLength = readLE(UInt16.self, at: 32, in: header),
                  let localOffset = readLE(UInt32.self, at: 42, in: header) else {
                throw ZIPError.invalidArchive
            }
            guard method == 0 else { throw ZIPError.unsupportedCompression }
            let nameData = input.readData(ofLength: Int(nameLength))
            guard let name = String(data: nameData, encoding: .utf8),
                  !name.isEmpty,
                  !name.hasPrefix("/"),
                  !name.contains(".."),
                  !name.contains("\\") else {
                throw ZIPError.invalidArchive
            }
            if !name.hasSuffix("/") {
                records.append(Record(
                    name: name,
                    compressedSize: UInt64(compressedSize),
                    localOffset: UInt64(localOffset)
                ))
            }
            cursor += UInt64(46 + Int(nameLength) + Int(extraLength) + Int(commentLength))
        }

        var extracted: [String: URL] = [:]
        for record in records {
            input.seek(toFileOffset: record.localOffset)
            let localHeader = input.readData(ofLength: 30)
            guard readLE(UInt32.self, at: 0, in: localHeader) == 0x04034b50,
                  let localNameLength = readLE(UInt16.self, at: 26, in: localHeader),
                  let localExtraLength = readLE(UInt16.self, at: 28, in: localHeader) else {
                throw ZIPError.invalidArchive
            }
            let contentOffset = record.localOffset + UInt64(30 + Int(localNameLength) + Int(localExtraLength))
            input.seek(toFileOffset: contentOffset)

            let outputURL = destination.appendingPathComponent(record.name)
            try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            guard fileManager.createFile(atPath: outputURL.path, contents: nil) else { throw ZIPError.writeFailed }
            do {
                let output = try FileHandle(forWritingTo: outputURL)
                defer { output.closeFile() }
                var remaining = record.compressedSize
                while remaining > 0 {
                    let chunk = input.readData(ofLength: Int(min(remaining, 1024 * 1024)))
                    if chunk.isEmpty { throw ZIPError.invalidArchive }
                    output.write(chunk)
                    remaining -= UInt64(chunk.count)
                }
            }
            extracted[record.name] = outputURL
        }
        return extracted
    }

    private static func zip16(_ value: Int) throws -> UInt16 {
        guard value >= 0, value <= Int(UInt16.max) else { throw ZIPError.archiveTooLarge }
        return UInt16(value)
    }

    private static func zip32(_ value: UInt64) throws -> UInt32 {
        guard value <= UInt64(UInt32.max) else { throw ZIPError.archiveTooLarge }
        return UInt32(value)
    }

    private static func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int, in data: Data) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<size {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return T(exactly: value)
    }

    enum ZIPError: LocalizedError {
        case invalidArchive
        case unsupportedCompression
        case writeFailed
        case archiveTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidArchive: return "O pacote do projeto está corrompido ou incompleto."
            case .unsupportedCompression: return "Este pacote usa compactação ZIP não suportada."
            case .writeFailed: return "Não foi possível criar o pacote ZIP."
            case .archiveTooLarge: return "O pacote excede o limite de 4 GB do formato ZIP usado pelo ClipStudio."
            }
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1
        }
        return value
    }

    private static func updateCRC(_ crc: inout UInt32, in data: Data) {
        data.withUnsafeBytes { bytes in
            for byte in bytes {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
            }
        }
    }

    fileprivate static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        updateCRC(&crc, in: data)
        return crc ^ 0xffffffff
    }

    fileprivate static func crc32AndSize(contentsOf url: URL) throws -> (crc: UInt32, size: UInt64) {
        let input = try FileHandle(forReadingFrom: url)
        defer { input.closeFile() }
        var crc: UInt32 = 0xffffffff
        var size: UInt64 = 0
        while true {
            let chunk = input.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            updateCRC(&crc, in: chunk)
            size += UInt64(chunk.count)
        }
        return (crc ^ 0xffffffff, size)
    }
}


fileprivate extension SimpleZIP.Entry {
    func data() throws -> Data {
        switch content {
        case .data(let data): return data
        case .file(let url): return try Data(contentsOf: url)
        }
    }

    func metadata() throws -> (crc: UInt32, size: UInt64) {
        switch content {
        case .data(let data):
            return (SimpleZIP.crc32(data), UInt64(data.count))
        case .file(let url):
            return try SimpleZIP.crc32AndSize(contentsOf: url)
        }
    }

    func writeContent(to output: FileHandle) throws {
        switch content {
        case .data(let data):
            output.write(data)
        case .file(let url):
            let input = try FileHandle(forReadingFrom: url)
            defer { input.closeFile() }
            while true {
                let chunk = input.readData(ofLength: 1024 * 1024)
                if chunk.isEmpty { break }
                output.write(chunk)
            }
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}