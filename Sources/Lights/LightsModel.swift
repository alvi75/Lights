import Foundation
import LightsCore

extension Notification.Name {
    static let lightsDisplayChange = Notification.Name("LightsDisplayChange")
}

/// Holds every session's state and decides what the light shows.
@MainActor
final class LightsModel {
    static let shared = LightsModel()

    /// Most of a transcript read in one check; a longer stretch is skipped to its end.
    private static let maxTranscriptRead: UInt64 = 16 << 20

    private struct TranscriptMark {
        let path: String
        let offset: UInt64
    }

    private var store = SessionStore()
    private(set) var following: Follow?
    private var gate = DisplayGate()
    private var transcripts: [String: TranscriptMark] = [:]

    var displayed: SessionState? { store.displayed(following: following) }
    var trackedTabs: Set<String> { store.tabs }

    func receive(_ signal: Signal, tab: String, transcript: String?) {
        store.apply(signal, tab: tab)
        mark(transcript, for: tab, signal: signal)
        publish(isReport: true)
    }

    func follow(_ target: Follow) {
        guard target != following else { return }
        following = target
        publish()
    }

    /// Runs every couple of seconds with what the terminal tabs are doing.
    func update(_ activity: TabActivity) {
        store.retain(liveTabs: activity.live)
        store.reconcile(with: activity)
        readTranscripts()
        publish()
    }

    /// A tapped bulb or "Off": shown until the next report or change.
    func showByHand(_ light: Light?) {
        gate.pickedByHand()
        post(light)
    }

    private func publish(isReport: Bool = false) {
        let now = displayed
        guard gate.shouldShow(now, isReport: isReport) else { return }
        post(now?.light)
    }

    private func post(_ light: Light?) {
        NotificationCenter.default.post(
            name: .lightsDisplayChange, object: nil,
            userInfo: ["light": light?.rawValue ?? "off"]
        )
    }

    // MARK: - Transcripts

    /// Remembers where the transcript ended at this report; only lines after it count.
    private func mark(_ path: String?, for tab: String, signal: Signal) {
        if signal == .end {
            transcripts[tab] = nil
            return
        }
        guard let path, Transcript.isAllowed(path, home: NSHomeDirectory()),
              let size = Self.fileSize(path) else { return }
        transcripts[tab] = TranscriptMark(path: path, offset: size)
    }

    /// Esc and "no" leave a line in the transcript but fire no hook. Every transcript is
    /// read up to its end each time, so a line only counts once.
    private func readTranscripts() {
        transcripts = transcripts.filter { store.tabs.contains($0.key) }
        for (tab, mark) in transcripts {
            guard let (lines, next) = Self.newLines(after: mark) else { continue }
            transcripts[tab] = TranscriptMark(path: mark.path, offset: next)
            if store.state(of: tab) != .done, Transcript.hasInterrupt(lines) {
                store.apply(.set(.done), tab: tab)
            }
        }
    }

    private static func fileSize(_ path: String) -> UInt64? {
        withRegularFile(path) { _, size in size }
    }

    /// Whole lines written since `mark`, and where the next read starts.
    private static func newLines(after mark: TranscriptMark) -> (Data, UInt64)? {
        withRegularFile(mark.path) { handle, end in
            // Shorter than before: the file was replaced. Start again from its end.
            guard end > mark.offset else { return (Data(), end) }
            let start = max(mark.offset, end > maxTranscriptRead ? end - maxTranscriptRead : 0)
            do {
                try handle.seek(toOffset: start)
                let data = try handle.read(upToCount: Int(end - start)) ?? Data()
                let whole = Transcript.completeLength(of: data)
                return (data.prefix(whole), start + UInt64(whole))
            } catch {
                NSLog("[Lights] can't read transcript \(mark.path): \(error)")
                return nil
            }
        }
    }

    /// Opens without following a link or waiting on a pipe, and only goes on for a plain file.
    private static func withRegularFile<T>(_ path: String, _ body: (FileHandle, UInt64) -> T?) -> T? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return body(handle, UInt64(info.st_size))
    }
}
