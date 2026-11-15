import Foundation

// ZIP simples sem compressão (método Store), compatível com Arquivos/iPadOS.
enum SimpleZIP {
    static func make(from files: [URL]) throws -> Data {
        var output = Data()
        var central = Data()
        for file in files {
            let content = try Data(contentsOf: file)
            let name = file.lastPathComponent
            let nameData = Data(name.utf8)
            let crc = crc32(content)
            let offset = UInt32(output.count)
            
            output.appendLE(UInt32(0x04034b50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(crc)
            output.appendLE(UInt32(content.count))
            output.appendLE(UInt32(content.count))
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
            central.appendLE(UInt32(content.count))
            central.appendLE(UInt32(content.count))
            central.appendLE(UInt16(nameData.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(offset)
            central.append(nameData)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.appendLE(UInt32(0x06054b50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(files.count))
        output.appendLE(UInt16(files.count))
        output.appendLE(UInt32(central.count))
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
        return output
    }
    
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1
            }
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}