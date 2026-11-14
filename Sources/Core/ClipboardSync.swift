import Foundation

/// Decides when clipboard text crosses the link, for one side of a session.
///
/// Each side watches only its pasteboard's change counter (free to read, no iPadOS paste banner) and reads the
/// contents only after the counter moves. Writing text that came from the other side moves the counter too, so
/// `wroteRemote` records the new counter and the write is never sent back (no echo loop). Text identical to the last
/// text synced in either direction is also dropped, which covers apps that rewrite the clipboard unchanged.
public struct ClipboardSync: Equatable {
    /// UTF-8 bytes per transfer. Control packets are capped at 64 KiB after JSON escaping, so this leaves room
    /// even for text that escapes heavily; `fits` checks the real encoded size. Text only: no images or files.
    public static let maxBytes = 32 * 1_024
    private var changeCount: Int
    private var lastText: String?
    public init(changeCount: Int) { self.changeCount = changeCount }

    /// True when the local pasteboard changed since we last looked (and it was not our own write).
    public mutating func localChanged(changeCount count: Int) -> Bool {
        guard count != changeCount else { return false }
        changeCount = count
        return true
    }
    /// Text read after a local change: returns what to send, or nil when it is empty, too large or already synced.
    public mutating func outgoing(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text != lastText, Self.fits(text) else { return nil }
        lastText = text
        return text
    }
    /// Text from the other side: true when it should be written to the local pasteboard.
    public mutating func incoming(_ text: String) -> Bool {
        guard text != lastText, Self.fits(text) else { return false }
        lastText = text
        return true
    }
    /// Call right after writing remote text, with the pasteboard's new change counter.
    public mutating func wroteRemote(changeCount count: Int) { changeCount = count }

    public static func fits(_ text: String) -> Bool {
        guard text.utf8.count <= maxBytes else { return false }
        return (try? WirePacket.control(.clipboard(text)).encoded()) != nil
    }
}
