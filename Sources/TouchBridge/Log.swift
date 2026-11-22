import Foundation

/// Log to stdout, ~/Library/Logs/TouchBridge.log and the in-app log window.
final class LogSink {
    static let shared = LogSink()

    let fileURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/TouchBridge.log")
    private(set) var lines: [String] = []
    private var listeners: [UUID: (String) -> Void] = [:]
    private var handle: FileHandle?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // keep the file small: start fresh when it grows over 5 MB
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 5_000_000 {
            try? fm.removeItem(at: fileURL)
        }
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    func append(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        print(line)
        fflush(stdout)
        if let d = (line + "\n").data(using: .utf8) { try? handle?.write(contentsOf: d) }
        let deliver = { [self] in
            lines.append(line)
            if lines.count > 4000 { lines.removeFirst(lines.count - 3000) }
            for l in listeners.values { l(line) }
        }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }

    func clear() { lines.removeAll() }

    @discardableResult
    func addListener(_ f: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = f
        return id
    }

    func removeListener(_ id: UUID) { listeners[id] = nil }
}

func tlog(_ s: String) { LogSink.shared.append(s) }
