import Foundation

/// Small JSON files, read and written as settings.py does: shared with the Python worker.
public enum JSONStore {
    /// The content of a JSON file, [:] when it is missing or broken.
    public static func read(_ url: URL) -> [String: Any] {
        // Files are replaced in one step (see `write`), so a read never sees half of one.
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return [:]
        }
        return dict
    }

    /// Replace a JSON file in one step: readers see the old content or the new one.
    public static func write(_ url: URL, _ data: [String: Any]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).part")
        let bytes = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .withoutEscapingSlashes])
        try bytes.write(to: partial)
        if rename(partial.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: partial)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
        }
    }
}

/// Loose reading of JSON values, which may come from Python as int or float.
public enum JSONValue {
    public static func double(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        default: return nil
        }
    }

    public static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Double: return v.isFinite ? Int(v) : nil
        case let v as NSNumber: return v.intValue
        default: return nil
        }
    }

    public static func bool(_ value: Any?) -> Bool {
        switch value {
        case let v as Bool: return v
        case let v as NSNumber: return v.boolValue
        case let v as String: return !v.isEmpty
        default: return false
        }
    }

    public static func string(_ value: Any?) -> String? {
        value as? String
    }
}

/// The user's settings: one JSON file, same keys as the Windows version.
public final class SettingsFile {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> [String: Any] {
        JSONStore.read(url)
    }

    public func save(_ changes: [String: Any]) {
        var data = load()
        for (key, value) in changes {
            data[key] = value
        }
        try? JSONStore.write(url, data)
    }
}
