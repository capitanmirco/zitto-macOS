import Foundation

/// A song of the list.
public struct Song: Equatable {
    public let key: String
    public let title: String  // as shown: "Artist - Title", or the name given by the user
    public let source: String
    public let ready: Bool
    public let error: String?
    public let single: Bool  // added on its own, not only as part of a playlist
    public let order: Double
}

public struct SavedPlaylist: Equatable {
    public let id: String
    public let title: String
    public let songs: [String]
}

public struct LibraryError: LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The songs: what has been added, downloaded and separated, and in which playlist.
///
/// The same folders and files as library.py, shared with the Python worker:
///
///     playlists.json
///     <key>/song.json      in the list: source, title...          (written by the window)
///     <key>/download.json  the original audio, next to it         (written by whoever downloads)
///     <key>/stems.json     separated, one .flac for each part     (written last, by the worker)
///     <key>/error.json     why it failed                          (written by the worker)
///     <key>/player.json    how it was left in the player          (written by the window)
public final class Library {
    public let root: URL
    /// Artist and title from the tags of a file: given by the app, which can read them.
    public var credits: (URL) -> (artist: String, title: String) = { url in
        ("", url.deletingPathExtension().lastPathComponent)
    }
    private var lastOrder = 0.0

    public init(root: URL) {
        self.root = root
    }

    // MARK: identity

    /// The full path of a file, with links resolved as Python's Path.resolve() does.
    public static func resolve(_ path: String) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard let real = realpath(expanded, nil) else {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        defer { free(real) }
        return String(cString: real)
    }

    /// Identifies a file: path and content date, as library.key_for does.
    public static func key(forFile path: String) throws -> String {
        let path = resolve(path)
        var isFolder: ObjCBool = false
        var info = stat()
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue,
              stat(path, &info) == 0 else {
            throw LibraryError("File not found: \(path)")
        }
        #if os(macOS)
        let seconds = Int64(info.st_mtimespec.tv_sec), nanos = Int64(info.st_mtimespec.tv_nsec)
        #else
        let seconds = Int64(info.st_mtim.tv_sec), nanos = Int64(info.st_mtim.tv_nsec)
        #endif
        return Texts.digest("\(path)|\(info.st_size)|\(seconds * 1_000_000_000 + nanos)")
    }

    public func folder(_ key: String) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !key.isEmpty, key.unicodeScalars.allSatisfy(allowed.contains) else {
            throw LibraryError("Not a song: \(key)")
        }
        return root.appendingPathComponent(key, isDirectory: true)
    }

    private func file(_ key: String, _ name: String) -> URL? {
        (try? folder(key))?.appendingPathComponent(name)
    }

    private func read(_ key: String, _ name: String) -> [String: Any] {
        file(key, name).map(JSONStore.read) ?? [:]
    }

    // MARK: songs

    public func get(_ key: String) -> Song? {
        let song = read(key, "song.json")
        guard !song.isEmpty, let source = song["source"] as? String else {
            return nil
        }
        let known = read(key, "download.json")
        var title = song["name"] as? String ?? ""
        if title.isEmpty {
            title = Texts.fullName(artist: known["artist"] as? String ?? "", title: known["title"] as? String ?? "")
        }
        if title.isEmpty {
            title = song["title"] as? String ?? ""
        }
        if title.isEmpty {
            title = source
        }
        let ready = file(key, "stems.json").map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return Song(key: key, title: title, source: source, ready: ready,
                    error: read(key, "error.json")["reason"] as? String,
                    single: JSONValue.bool(song["single"]), order: JSONValue.double(song["order"]) ?? 0)
    }

    /// Every song in the list, in the order they were added.
    public func songs() -> [Song] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        return names.compactMap { name -> Song? in
            guard let place = try? folder(name),
                  FileManager.default.fileExists(atPath: place.appendingPathComponent("song.json").path) else {
                return nil
            }
            return get(name)
        }.sorted { $0.order < $1.order }
    }

    /// Put a song in the list. Adding it again keeps its work and retries it if it had failed.
    ///
    /// `source`: the full path of a file, or a link as its plugin writes it. `key`: for a link,
    /// what its plugin says (see WorkerProcess.inspect); for a file it is found here.
    @discardableResult
    public func add(source: String, key: String? = nil, title: String = "", single: Bool = true) throws -> Song {
        let isLink = Texts.isURL(source)
        let source = isLink ? source.trimmingCharacters(in: .whitespacesAndNewlines) : Library.resolve(source)
        let key = try key ?? Library.key(forFile: source)
        let path = try folder(key).appendingPathComponent("song.json")
        let known = JSONStore.read(path)
        lastOrder = max(Date().timeIntervalSince1970, lastOrder + 1e-5)  // the clock may not move between two songs
        var shown = title
        if shown.isEmpty { shown = known["title"] as? String ?? "" }
        if shown.isEmpty {
            if isLink {
                shown = source
            } else {
                let found = credits(URL(fileURLWithPath: source))
                shown = Texts.fullName(artist: found.artist, title: found.title)
            }
        }
        let order = JSONValue.double(known["order"]).flatMap { $0 == 0 ? nil : $0 } ?? lastOrder
        try JSONStore.write(path, [
            "source": source,
            "title": shown,
            "name": known["name"] as? String ?? "",
            "order": order,
            "single": single || JSONValue.bool(known["single"]),
            "wanted": JSONValue.double(known["wanted"]) ?? 0,
        ])
        retry(key)
        guard let song = get(key) else {
            throw LibraryError("The song could not be added.")
        }
        return song
    }

    /// Give a song another name; an empty one brings back its own.
    public func rename(_ key: String, to name: String) {
        update(key) { $0["name"] = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    }

    /// Prepare this song before the others.
    public func want(_ key: String) {
        update(key) { $0["wanted"] = Date().timeIntervalSince1970 }
    }

    private func update(_ key: String, _ change: (inout [String: Any]) -> Void) {
        guard let path = file(key, "song.json") else {
            return
        }
        var song = JSONStore.read(path)
        if !song.isEmpty {
            change(&song)
            try? JSONStore.write(path, song)
        }
    }

    /// Songs still to be prepared, the next one first.
    public func waiting() -> [Song] {
        let todo = songs().filter { !$0.ready && $0.error == nil }
        let wanted = Dictionary(uniqueKeysWithValues: todo.map {
            ($0.key, JSONValue.double(read($0.key, "song.json")["wanted"]) ?? 0)
        })
        return todo.sorted { (-(wanted[$0.key] ?? 0), $0.order) < (-(wanted[$1.key] ?? 0), $1.order) }
    }

    public func fail(_ key: String, reason: String) {
        if let path = file(key, "error.json") {
            try? JSONStore.write(path, ["reason": reason])
        }
    }

    public func retry(_ key: String) {
        if let path = file(key, "error.json") {
            try? FileManager.default.removeItem(at: path)
        }
    }

    /// Remove a song from the library: never the user's own file.
    public func delete(_ key: String) {
        writePlaylists(playlists().map { SavedPlaylist(id: $0.id, title: $0.title, songs: $0.songs.filter { $0 != key }) })
        if let place = try? folder(key) {
            try? FileManager.default.removeItem(at: place)
        }
    }

    // MARK: playlists

    public func playlists() -> [SavedPlaylist] {
        let data = JSONStore.read(root.appendingPathComponent("playlists.json"))
        return (data["playlists"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else {
                return nil
            }
            return SavedPlaylist(id: id, title: item["title"] as? String ?? "", songs: item["songs"] as? [String] ?? [])
        }
    }

    private func writePlaylists(_ items: [SavedPlaylist]) {
        let list = items.map { ["id": $0.id, "title": $0.title, "songs": $0.songs] as [String: Any] }
        try? JSONStore.write(root.appendingPathComponent("playlists.json"), ["playlists": list])
    }

    /// Remove a playlist with the songs that are nowhere else. Returns the songs removed.
    @discardableResult
    public func deletePlaylist(_ id: String) -> [String] {
        let known = playlists()
        guard let gone = known.first(where: { $0.id == id }) else {
            return []
        }
        let others = known.filter { $0.id != id }
        let kept = Set(others.flatMap { $0.songs }).union(songs().filter { $0.single }.map { $0.key })
        writePlaylists(others)
        let removed = gone.songs.filter { !kept.contains($0) }
        for key in removed {
            if let place = try? folder(key) {
                try? FileManager.default.removeItem(at: place)
            }
        }
        return removed
    }

    // MARK: player

    /// What the worker stored: the names of the parts, and the gain that brings them to their level.
    public func stemInfo(_ key: String) throws -> (names: [String], gain: Float, folder: URL) {
        let info = read(key, "stems.json")
        guard let names = info["names"] as? [String], !names.isEmpty, let gain = JSONValue.double(info["gain"]) else {
            throw LibraryError("This song has not been separated yet.")
        }
        return (names, Float(gain), try folder(key))
    }

    public func loadState(_ key: String) -> [String: Any] {
        read(key, "player.json")
    }

    public func saveState(_ key: String, _ state: [String: Any]) {
        // It may have been deleted meanwhile.
        guard let place = try? folder(key),
              FileManager.default.fileExists(atPath: place.appendingPathComponent("song.json").path) else {
            return
        }
        try? JSONStore.write(place.appendingPathComponent("player.json"), state)
    }
}
