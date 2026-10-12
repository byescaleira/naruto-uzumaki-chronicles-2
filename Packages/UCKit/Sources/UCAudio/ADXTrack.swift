import Foundation
import UCFormats

/// One ADX stream held in memory, ready for playback (the whole file: 0.04–17 MB here).
///
/// The bytes live in a buffer that never moves or changes after `init`, so the real-time
/// thread can decode from it without locks or reference counting.
public final class ADXTrack: Sendable {
    public enum Failure: Error, Equatable {
        case undecodable(ADXHeader.Encoding)
        /// Every bus runs at ``AudioSystem/sampleRate`` (all of the game's streams are 48 kHz).
        case unsupportedSampleRate(Int)
    }

    public let header: ADXHeader
    nonisolated(unsafe) let bytes: UnsafeMutableRawBufferPointer

    public init(_ data: some ContiguousBytes) throws {
        let header = try data.withUnsafeBytes { try ADXHeader($0.prefix(ADXHeader.maximumHeaderSize)) }
        guard header.isDecodable else { throw Failure.undecodable(header.encoding) }
        guard header.sampleRate == Int(AudioSystem.sampleRate) else {
            throw Failure.unsupportedSampleRate(header.sampleRate)
        }
        self.header = header
        bytes = data.withUnsafeBytes { source in
            let copy = UnsafeMutableRawBufferPointer.allocate(byteCount: source.count, alignment: 16)
            copy.copyMemory(from: source)
            return copy
        }
    }

    /// Entry `index` of a CRI AFS archive (`XA/XA.AFS`, `XA/XAVOICE.AFS`).
    public convenience init(archive: AFSArchive, index: Int) throws {
        try self.init(archive.read(archive.entries[index]))
    }

    deinit { bytes.deallocate() }

    public var duration: Duration { .seconds(header.duration) }
}
