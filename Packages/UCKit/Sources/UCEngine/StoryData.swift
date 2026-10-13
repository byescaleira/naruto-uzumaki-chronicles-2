import Foundation
import UCFormats

/// Story episodes → where they start (`FUN_002fa8a0` / `FUN_002fa6f0` over table 0 of `0013/01`).
public struct EpisodeTable: Sendable {
    public struct Episode: Sendable, Equatable {
        public let id: Int
        public let map: Int
        public let area: Int
    }

    public static let handle = ResourceHandle(entry: 13, subfile: 1)
    static let rowSize = 0x24
    /// `FUN_00137320`: episode 0 (a new game) plays 0xF.
    public static let newGame = 0xF

    public let episodes: [Episode]

    public init(_ bytes: [UInt8]) throws {
        let table = try DataTable(bytes)
        var episodes: [Episode] = []
        for i in 0 ..< (table.tables.first?.rows ?? 0) {
            guard let row = table.row(i, size: Self.rowSize) else { break }
            let b = Array(row)
            func u16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
            episodes.append(Episode(id: Int(b[0]), map: u16(0x10), area: u16(0x12)))
        }
        self.episodes = episodes
    }

    public func episode(_ id: Int) -> Episode? { episodes.first { $0.id == id } }
}

/// The map table compiled into the executable (`DAT_003507c0`, read by `FUN_00165870` and the
/// accessors `FUN_00164360…FUN_00165740`): per map `{u32 areas, u32 count, u32 flags}`, per area
/// 0x30 bytes of DIG handles.
public struct MapTable: Sendable {
    public static let address: UInt32 = 0x3507C0
    /// `FUN_00164360` and the others reject maps above 0x62.
    public static let maps = 0x63

    public struct Area: Sendable, Equatable {
        /// `[0]` the area entry, loaded with ``stage`` by `FUN_00165870`.
        public let areaFile: ResourceHandle
        /// `[1]` the stage entry (shared between areas).
        public let stage: ResourceHandle
        /// `[2]`, `[3]`, `[10]`: the stage object `FUN_0016a1f0` binds with `FUN_001b7640` (main
        /// model, second model at +0x60, third at +0x30).
        public let stageModels: [ResourceHandle]
        /// `[7]` the area data (23 sections), `[8]`, `[9]` more area sub-files.
        public let areaData: ResourceHandle
        public let areaExtras: [ResourceHandle]
        /// `[4…6]` stage sub-files 3–5.
        public let stageExtras: [ResourceHandle]
        /// `[11]`: music (`XA.AFS` index), −1 for none.
        public let music: Int
    }

    public let areas: [Int: [Area]]

    public init(_ executable: Executable) throws {
        var areas: [Int: [Area]] = [:]
        for map in 0 ..< Self.maps {
            let base = Self.address + UInt32(map * 12)
            let pointer = try executable.u32(at: base), count = Int(try executable.u32(at: base + 4))
            guard pointer != 0, (1 ... 64).contains(count) else { continue }
            var list: [Area] = []
            for a in 0 ..< count {
                let record = pointer + UInt32(a * 0x30)
                func handle(_ i: Int) throws -> ResourceHandle { ResourceHandle(try executable.u32(at: record + UInt32(i * 4))) }
                list.append(Area(areaFile: try handle(0), stage: try handle(1),
                                 stageModels: [try handle(2), try handle(3), try handle(10)],
                                 areaData: try handle(7), areaExtras: [try handle(8), try handle(9)],
                                 stageExtras: [try handle(4), try handle(5), try handle(6)],
                                 music: Int(try executable.i32(at: record + 44))))
            }
            areas[map] = list
        }
        self.areas = areas
    }

    /// Areas are numbered from 1 (`FUN_0016e600() - 1` indexes the records).
    public func area(map: Int, area: Int) -> Area? {
        guard let list = areas[map], (1 ... list.count).contains(area) else { return nil }
        return list[area - 1]
    }
}

extension GameData {
    /// The executable shipped in the data package (format 4).
    public func executable() throws -> Executable {
        try Executable([UInt8](try disc.read(try disc.file(Executable.name))))
    }

    public func file(_ handle: ResourceHandle) throws -> [UInt8] {
        try subfile(entry: handle.entry, handle.subfile)
    }
}
