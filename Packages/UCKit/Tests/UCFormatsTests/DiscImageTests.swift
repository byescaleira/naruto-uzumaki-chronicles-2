import Foundation
import Testing
@testable import UCFormats

/// Builds a minimal ISO 9660 image: PVD at sector 16, root directory at sector 18 with
/// `SYSTEM.CNF;1` and a `XA` subdirectory holding `XA.AFS;1`.
private func makeISO(systemCNF: String) -> Data {
    let sector = 2048
    var image = [UInt8](repeating: 0, count: sector * 24)

    func put32(_ value: Int, at offset: Int) {
        for i in 0 ..< 4 { image[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        for i in 0 ..< 4 { image[offset + 4 + i] = UInt8((value >> (8 * (3 - i))) & 0xFF) }
    }
    func record(at offset: Int, extent: Int, size: Int, directory: Bool, name: [UInt8]) -> Int {
        let length = 33 + name.count + (name.count % 2 == 0 ? 1 : 0)
        image[offset] = UInt8(length)
        put32(extent, at: offset + 2)
        put32(size, at: offset + 10)
        image[offset + 25] = directory ? 0x02 : 0
        image[offset + 32] = UInt8(name.count)
        image.replaceSubrange((offset + 33) ..< (offset + 33 + name.count), with: name)
        return offset + length
    }

    // Primary Volume Descriptor.
    let pvd = 16 * sector
    image[pvd] = 1
    image.replaceSubrange((pvd + 1) ..< (pvd + 6), with: Array("CD001".utf8))
    _ = record(at: pvd + 156, extent: 18, size: sector, directory: true, name: [0])

    // Root directory: ".", "..", SYSTEM.CNF, XA/.
    var p = 18 * sector
    p = record(at: p, extent: 18, size: sector, directory: true, name: [0])
    p = record(at: p, extent: 18, size: sector, directory: true, name: [1])
    let cnf = Array(systemCNF.utf8)
    p = record(at: p, extent: 20, size: cnf.count, directory: false, name: Array("SYSTEM.CNF;1".utf8))
    _ = record(at: p, extent: 19, size: sector, directory: true, name: Array("XA".utf8))

    // XA directory.
    var q = 19 * sector
    q = record(at: q, extent: 19, size: sector, directory: true, name: [0])
    q = record(at: q, extent: 18, size: sector, directory: true, name: [1])
    _ = record(at: q, extent: 21, size: 4, directory: false, name: Array("XA.AFS;1".utf8))

    image.replaceSubrange((20 * sector) ..< (20 * sector + cnf.count), with: cnf)
    image.replaceSubrange((21 * sector) ..< (21 * sector + 4), with: Array("AFS\0".utf8))
    return Data(image)
}

private func temporaryFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "nuc2-\(UUID().uuidString).iso")
    try data.write(to: url)
    return url
}

@Suite("Disc image")
struct DiscImageTests {
    @Test("Reads files and subdirectories in place from an ISO 9660 image")
    func readsISO() throws {
        let url = try temporaryFile(makeISO(systemCNF: "BOOT2 = cdrom0:\\SLES_550.90;1\r\nVMODE = PAL\r\n"))
        defer { try? FileManager.default.removeItem(at: url) }
        let disc = try DiscImage(url: url)
        #expect(Set(disc.files.keys) == ["SYSTEM.CNF", "XA/XA.AFS"])
        let afs = try disc.file("xa/xa.afs")
        #expect(afs.offset == 21 * 2048)
        #expect(try disc.read(afs) == Data("AFS\0".utf8))
        try disc.validate()
    }

    @Test("Rejects another game's disc")
    func wrongGame() throws {
        let url = try temporaryFile(makeISO(systemCNF: "BOOT2 = cdrom0:\\SLUS_123.45;1\r\n"))
        defer { try? FileManager.default.removeItem(at: url) }
        let disc = try DiscImage(url: url)
        #expect(throws: DiscImage.Failure.wrongGame("BOOT2 = cdrom0:\\SLUS_123.45;1")) { try disc.validate() }
    }

    @Test("Rejects files that are not ISO 9660")
    func notISO() throws {
        let url = try temporaryFile(Data(repeating: 0xAB, count: 40_000))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: DiscImage.Failure.notISO9660) { try DiscImage(url: url) }
    }
}
