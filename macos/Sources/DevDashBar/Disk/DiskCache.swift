import Foundation

/// Stores a finished scan as a compact binary preorder dump so the window opens instantly.
enum DiskCache {
    private static let magic: UInt32 = 0x4444_5431 // "DDT1"

    struct Header: Sendable {
        let rootPath: String
        let date: Date
        let duration: Double
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("works.enso.devdash.bar", isDirectory: true)
    }

    static func url(for rootPath: String) -> URL {
        let safe = rootPath.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("disk\(safe).bin")
    }

    static func write(_ root: DiskNode, header: Header) throws {
        var writer = Writer()
        writer.u32(magic)
        writer.string(header.rootPath)
        writer.f64(header.date.timeIntervalSince1970)
        writer.f64(header.duration)
        write(root, into: &writer)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writer.data.write(to: url(for: header.rootPath), options: .atomic)
    }

    static func read(rootPath: String) -> (DiskNode, Header)? {
        guard let data = try? Data(contentsOf: url(for: rootPath), options: .mappedIfSafe) else { return nil }
        var reader = Reader(data: data)
        guard reader.u32() == magic else { return nil }
        let header = Header(rootPath: reader.string(), date: Date(timeIntervalSince1970: reader.f64()), duration: reader.f64())
        guard header.rootPath == rootPath, let root = read(from: &reader, parent: nil), !reader.failed else { return nil }
        root.aggregate()
        return (root, header)
    }

    private static func write(_ node: DiskNode, into writer: inout Writer) {
        writer.string(node.name)
        var flags: UInt8 = 0
        if node.isDirectory { flags |= 1 }
        if node.isHidden { flags |= 2 }
        if node.denied { flags |= 4 }
        if node.skippedReason != nil { flags |= 8 }
        writer.u8(flags)
        if let reason = node.skippedReason { writer.string(reason) }
        writer.u16(node.markers.rawValue)
        let own = node.own
        for value in [own.allocated, own.apparent, own.files, own.dirs, own.hiddenAllocated, own.hiddenApparent, own.hiddenFiles] {
            writer.i64(value)
        }
        writer.f64(own.newest)
        writer.u32(UInt32(node.children.count))
        for child in node.children { write(child, into: &writer) }
    }

    private static func read(from reader: inout Reader, parent: DiskNode?) -> DiskNode? {
        let name = reader.string()
        let flags = reader.u8()
        let reason = flags & 8 != 0 ? reader.string() : nil
        let node = DiskNode(name: name, parent: parent, isDirectory: flags & 1 != 0, isHidden: flags & 2 != 0)
        node.denied = flags & 4 != 0
        node.skippedReason = reason
        node.markers = ProjectMarkers(rawValue: reader.u16())
        node.own = DiskTotals(
            allocated: reader.i64(), apparent: reader.i64(), files: reader.i64(), dirs: reader.i64(),
            hiddenAllocated: reader.i64(), hiddenApparent: reader.i64(), hiddenFiles: reader.i64(), newest: reader.f64()
        )
        let count = Int(reader.u32())
        guard !reader.failed else { return nil }
        node.children.reserveCapacity(count)
        for _ in 0..<count {
            guard let child = read(from: &reader, parent: node) else { return nil }
            node.children.append(child)
        }
        return node
    }

    private struct Writer {
        var data = Data()
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func i64(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        mutating func string(_ s: String) {
            let bytes = Array(s.utf8)
            u32(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0
        var failed = false

        private mutating func take<T: FixedWidthInteger>(_: T.Type) -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { failed = true; return 0 }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
            offset += size
            return T(littleEndian: value)
        }
        mutating func u8() -> UInt8 { take(UInt8.self) }
        mutating func u16() -> UInt16 { take(UInt16.self) }
        mutating func u32() -> UInt32 { take(UInt32.self) }
        mutating func i64() -> Int64 { take(Int64.self) }
        mutating func f64() -> Double { Double(bitPattern: take(UInt64.self)) }
        mutating func string() -> String {
            let count = Int(u32())
            guard !failed, offset + count <= data.count else { failed = true; return "" }
            let value = String(decoding: data[data.startIndex + offset ..< data.startIndex + offset + count], as: UTF8.self)
            offset += count
            return value
        }
    }
}
