import Foundation

/// What the Python worker says, one JSON object per line (see worker.py).
public enum WorkerEvent: Equatable {
    case song(key: String)
    case status(text: String)
    case progress(percent: Int)
    case ready(key: String)
    case failed(key: String)
    case blocked(text: String)
    case added(id: String, title: String, count: Int)
    case error(text: String)
    case info(links: [String], problems: [String], stems: [String])
    case link(kind: String, key: String, clean: String)
    /// Not said by the worker: it has ended, with this exit code.
    case ended(code: Int32)

    /// The event on a line, or nil for whatever else a library printed.
    public static func parse(_ line: Data) -> WorkerEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let data = object as? [String: Any], let event = data["event"] as? String else {
            return nil
        }
        let text = data["text"] as? String ?? ""
        let key = data["key"] as? String ?? ""
        switch event {
        case "song": return .song(key: key)
        case "status": return .status(text: text)
        case "progress": return .progress(percent: JSONValue.int(data["percent"]) ?? 0)
        case "ready": return .ready(key: key)
        case "failed": return .failed(key: key)
        case "blocked": return .blocked(text: text)
        case "added":
            return .added(id: data["id"] as? String ?? "", title: data["title"] as? String ?? "",
                          count: JSONValue.int(data["count"]) ?? 0)
        case "error": return .error(text: text)
        case "info":
            return .info(links: data["links"] as? [String] ?? [], problems: data["problems"] as? [String] ?? [],
                         stems: data["stems"] as? [String] ?? [])
        case "link":
            return .link(kind: data["kind"] as? String ?? LinkKind.song, key: key, clean: data["clean"] as? String ?? "")
        default: return nil
        }
    }
}

/// Exit codes of the worker.
public enum WorkerExit {
    public static let done: Int32 = 0, blocked: Int32 = 2, busy: Int32 = 3
}

/// What a link leads to (see source.py).
public enum LinkKind {
    public static let song = "song", list = "list", songInList = "song in list"
}

/// Splits what a process writes into lines, whatever the size of the pieces it arrives in.
public struct LineSplitter {
    private var pending = Data()

    public init() {}

    public mutating func feed(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let end = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<end])
            pending = Data(pending[pending.index(after: end)...])
        }
        return lines
    }

    /// What is left when the stream ends.
    public mutating func finish() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}

/// The last percentage of the progress bars that tqdm draws on stderr: "45%|████".
public func lastPercent(_ chunk: Data) -> Int? {
    let bytes = [UInt8](chunk)
    var found: Int? = nil
    var i = 0
    while i + 1 < bytes.count {
        if bytes[i] == UInt8(ascii: "%") && bytes[i + 1] == UInt8(ascii: "|") {
            var start = i
            while start > 0 && i - start < 3 && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[start - 1]) {
                start -= 1
            }
            if start < i, let value = Int(String(decoding: bytes[start..<i], as: UTF8.self)) {
                found = value
            }
        }
        i += 1
    }
    return found
}
