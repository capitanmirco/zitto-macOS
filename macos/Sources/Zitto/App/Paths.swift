import Foundation
import ZittoCore

/// Where zitto keeps its things on a Mac, and where it finds the programs it needs.
enum Paths {
    /// ~/Library/Application Support/zitto
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let folder = base.appendingPathComponent("zitto", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    static let environment = ProcessInfo.processInfo.environment

    /// The songs: ZITTO_LIBRARY, as on Windows, or a folder of zitto.
    static let library: URL = environment["ZITTO_LIBRARY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? support.appendingPathComponent("library", isDirectory: true)

    static let models: URL = environment["ZITTO_MODELS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? support.appendingPathComponent("models", isDirectory: true)

    static let settings = support.appendingPathComponent("settings.json")

    /// Where "Save..." starts the first time.
    static let output: URL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first?
        .appendingPathComponent("zitto", isDirectory: true)
        ?? support.appendingPathComponent("output", isDirectory: true)

    /// Folders where Homebrew and the system keep programs: an app started from the Finder does
    /// not have them in its PATH.
    static let programFolders = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static var searchPath: String {
        let current = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (programFolders + current).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    static func program(_ name: String) -> URL? {
        searchPath.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var ffmpeg: URL? {
        if let chosen = SettingsFile(url: settings).load()["ffmpeg"] as? String,
           FileManager.default.isExecutableFile(atPath: chosen) {
            return URL(fileURLWithPath: chosen)
        }
        return program("ffmpeg")
    }

    /// The Python that runs the worker: one with zitto and the models' libraries installed.
    /// ZITTO_PYTHON, the "python" setting, or the environment made by scripts/setup-worker.sh.
    static var python: URL? {
        var candidates: [String] = []
        if let chosen = environment["ZITTO_PYTHON"] { candidates.append(chosen) }
        if let chosen = SettingsFile(url: settings).load()["python"] as? String { candidates.append(chosen) }
        candidates.append(support.appendingPathComponent("venv/bin/python3").path)
        return candidates.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The folder with the zitto package, when it is not installed in that Python.
    static var source: String? {
        environment["ZITTO_SOURCE"] ?? SettingsFile(url: settings).load()["source"] as? String
    }
}
