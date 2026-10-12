import Foundation

/// The user's disc: either the `.iso` itself (read in place, ISO 9660) or a folder with the
/// disc's files (a mounted image or an extracted copy).
public struct DiscImage: Sendable {
    /// A file on the disc: a byte range of `url`.
    public struct File: Sendable, Hashable {
        public let url: URL
        public let offset: UInt64
        public let size: UInt64

        public init(url: URL, offset: UInt64, size: UInt64) {
            self.url = url
            self.offset = offset
            self.size = size
        }
    }

    public enum Failure: Error, Equatable {
        case notISO9660
        case missingFile(String)
        case wrongGame(String)
    }

    public static let sectorSize: UInt64 = 2048
    /// Boot executable of the PAL release this project reverse engineers.
    public static let expectedExecutable = "SLES_550.90"

    public let url: URL
    /// Upper-cased path (no leading slash, no `;1`) → file.
    public let files: [String: File]

    public init(url: URL) throws {
        self.url = url
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            files = try Self.scanFolder(url)
        } else {
            files = try Self.scanISO(url)
        }
    }

    public func file(_ path: String) throws -> File {
        guard let file = files[path.uppercased()] else { throw Failure.missingFile(path) }
        return file
    }

    public func read(_ file: File, offset: UInt64 = 0, count: Int? = nil) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: file.offset + offset)
        let length = count ?? Int(file.size - offset)
        return try handle.read(upToCount: length) ?? Data()
    }

    /// Checks `SYSTEM.CNF` boots the expected executable (`BOOT2 = cdrom0:\SLES_550.90;1`).
    public func validate() throws {
        let cnf = String(decoding: try read(try file("SYSTEM.CNF")), as: UTF8.self)
        guard cnf.uppercased().contains(Self.expectedExecutable) else {
            let boot = cnf.split(whereSeparator: \.isNewline).first { $0.uppercased().hasPrefix("BOOT2") }
            throw Failure.wrongGame(boot.map(String.init) ?? "SYSTEM.CNF")
        }
    }

    // MARK: Folder

    private static func scanFolder(_ root: URL) throws -> [String: File] {
        var files: [String: File] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return files }
        let base = root.standardizedFileURL.path
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            files[path.uppercased()] = File(url: url, offset: 0, size: UInt64(values.fileSize ?? 0))
        }
        return files
    }

    // MARK: ISO 9660

    private static func scanISO(_ url: URL) throws -> [String: File] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        func sector(_ index: UInt64, count: Int = 1) throws -> [UInt8] {
            try handle.seek(toOffset: index * sectorSize)
            return [UInt8](try handle.read(upToCount: count * Int(sectorSize)) ?? Data())
        }
        // Primary Volume Descriptor at sector 16: type 1, "CD001".
        let pvd = try sector(16)
        guard pvd.count == Int(sectorSize), pvd[0] == 1, Array(pvd[1 ..< 6]) == Array("CD001".utf8) else {
            throw Failure.notISO9660
        }
        let root = Record(pvd, at: 156)
        var files: [String: File] = [:]
        var pending: [(path: String, record: Record)] = [("", root)]
        var visited = Set<UInt32>()
        while let (path, dir) = pending.popLast() {
            guard visited.insert(dir.extent).inserted else { continue }
            let sectors = Int((UInt64(dir.size) + sectorSize - 1) / sectorSize)
            let bytes = try sector(UInt64(dir.extent), count: sectors)
            var offset = 0
            while offset < bytes.count {
                let length = Int(bytes[offset])
                if length == 0 {
                    // Records never cross a sector boundary: skip to the next sector.
                    offset = (offset / Int(sectorSize) + 1) * Int(sectorSize)
                    continue
                }
                let record = Record(bytes, at: offset)
                offset += length
                guard record.name != "\u{0}", record.name != "\u{1}" else { continue } // "." and ".."
                let name = record.name.split(separator: ";").first.map(String.init) ?? record.name
                let full = path.isEmpty ? name : "\(path)/\(name)"
                if record.isDirectory {
                    pending.append((full, record))
                } else {
                    files[full.uppercased()] = File(url: url, offset: UInt64(record.extent) * sectorSize, size: UInt64(record.size))
                }
            }
        }
        return files
    }

    /// ISO 9660 directory record (both-endian fields, little-endian half used).
    private struct Record {
        let extent: UInt32
        let size: UInt32
        let isDirectory: Bool
        let name: String

        init(_ b: [UInt8], at o: Int) {
            func u32(_ i: Int) -> UInt32 {
                UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
            }
            extent = u32(o + 2)
            size = u32(o + 10)
            isDirectory = b[o + 25] & 0x02 != 0
            let nameLength = Int(b[o + 32])
            name = String(decoding: b[(o + 33) ..< (o + 33 + nameLength)], as: UTF8.self)
        }
    }
}
