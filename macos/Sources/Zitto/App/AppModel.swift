import AppKit
import Combine
import UniformTypeIdentifiers
import ZittoCore

/// A row of the list on the left.
struct SongRow: Identifiable, Equatable {
    enum Look { case normal, todo, failed, open }

    let id: String  // "<group>/<key>": a song can be in more than one playlist
    let key: String
    let title: String
    let state: String
    let look: Look
}

/// A playlist, or the songs added on their own.
struct SongGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let count: String
    let rows: [SongRow]
    var isPlaylist: Bool { id != AppModel.singles }
}

/// The window: the songs on the left, the player on the right. The equivalent of gui.App.
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let singles = "songs"  // group of the songs that are in no playlist

    @Published private(set) var groups: [SongGroup] = []
    @Published var selection: Set<String> = [] {
        didSet { explain() }
    }
    @Published var query = "" {
        didSet { searchSoon() }
    }
    @Published var linkText = ""
    @Published private(set) var status = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var links: [String] = []  // what plugins can open, besides files
    @Published private(set) var windowTitle = "zitto"
    @Published var focusSearch = 0  // changes when the search field should take the keyboard

    let library: Library
    let settings: SettingsFile
    let player: PlayerModel
    private var work: Work!
    private var current: String?  // song being prepared
    private var stage = ""
    private var percent: Int?
    private var notice = ""  // shown when nothing is being prepared
    private var reading = 0  // playlists being read
    private var opening: String?
    private var openWhenReady: String?
    private var songs: [String: Song] = [:]  // what is in the library, kept in memory
    private var lists: [SavedPlaylist] = []
    private var keys: [String: String] = [:]  // row -> song
    private var searchLater: DispatchWorkItem?
    private var timer: Timer?
    private var keyMonitor: Any?

    private init() {
        library = Library(root: Paths.library)
        library.credits = AudioFiles.credits
        settings = SettingsFile(url: Paths.settings)
        player = PlayerModel(library: library, settings: settings)
        work = Work { [weak self] run, event in self?.workEvent(run, event) }
        reload()
        askInfo()
        if let last = settings.load()["last_song"] as? String, let song = library.get(last), song.ready {
            open(last)
        }
        startWork()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.player.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)  // also while a menu is open or the window is resized
        installKeys()
    }

    // MARK: list

    /// Read the whole library again.
    func reload() {
        songs = Dictionary(uniqueKeysWithValues: library.songs().map { ($0.key, $0) })
        lists = library.playlists()
        sync()
    }

    /// Read one song again.
    private func updateSong(_ key: String) {
        guard let song = library.get(key), songs[key] != nil else {
            reload()
            return
        }
        songs[key] = song
        sync()
    }

    /// Make the list show what is known, or what the search finds in it.
    private func sync() {
        let words = Texts.words(query)
        let listed = Set(lists.flatMap(\.songs))
        let ordered = songs.values.sorted { $0.order < $1.order }.map(\.key)
        var all = lists.map { ($0.id, $0.title, $0.songs) }
        all.append((AppModel.singles, "Songs", ordered.filter { songs[$0]!.single || !listed.contains($0) }))
        var made: [SongGroup] = []
        keys = [:]
        for (id, title, members) in all {
            let found = members.filter { key in songs[key].map { Texts.matches(words, $0.title, title) } ?? false }
            if found.isEmpty {
                continue
            }
            let rows = found.map { key -> SongRow in
                let song = songs[key]!
                let (state, look) = self.look(song)
                keys["\(id)/\(key)"] = key
                return SongRow(id: "\(id)/\(key)", key: key, title: song.title, state: state, look: look)
            }
            made.append(SongGroup(id: id, title: title, count: count(found), rows: rows))
        }
        if made != groups {
            groups = made
        }
        let still = selection.filter { keys[$0] != nil }
        if still != selection {
            selection = still
        }
        showStatus()
    }

    private func count(_ members: [String]) -> String {
        let ready = members.filter { songs[$0]?.ready == true }.count
        return ready == members.count ? "\(members.count)" : "\(ready)/\(members.count)"
    }

    /// Songs still to be prepared.
    private var left: Int {
        songs.values.filter { !$0.ready && $0.error == nil }.count
    }

    private func look(_ song: Song) -> (String, SongRow.Look) {
        if song.ready {
            return ("", song.key == player.key ? .open : .normal)
        }
        if song.error != nil {
            return ("failed", .failed)
        }
        if song.key == current {
            return (percent.map { "\($0)%" } ?? "...", .todo)
        }
        return ("waiting", .todo)
    }

    private func showStatus() {
        if let current, let song = songs[current] {
            let more = left > 1 ? "\n\(left - 1) more waiting" : ""
            status = "\(stage.isEmpty ? "Starting" : stage): \(song.title.prefix(70))\(more)"
            progress = Double(percent ?? 0)
        } else {
            status = reading > 0 ? "Reading the playlist..." : notice
            progress = 0
        }
    }

    func say(_ text: String) {
        notice = text
        showStatus()
    }

    // MARK: search

    /// When the typing pauses, so that it never waits for the list.
    private func searchSoon() {
        searchLater?.cancel()
        let later = DispatchWorkItem { [weak self] in self?.sync() }
        searchLater = later
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: later)
    }

    func searchNow() {
        searchLater?.cancel()
        sync()
    }

    func clearSearch() {
        query = ""
        searchNow()
    }

    /// Enter in the search: the first song found.
    func openFirst() {
        searchNow()
        if let first = groups.first?.rows.first {
            open(first.key)
        }
    }

    // MARK: selection

    /// Songs selected.
    var selected: [String] {
        var seen = Set<String>()
        return groups.flatMap(\.rows).filter { selection.contains($0.id) }.map(\.key).filter { seen.insert($0).inserted }
    }

    func song(_ key: String) -> Song? {
        songs[key]
    }

    private func explain() {
        let chosen = selected
        if chosen.count == 1, let error = songs[chosen[0]]?.error {
            say(error)
        }
    }

    // MARK: adding

    func addEntry() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            add(text) { [weak self] added in
                if added { self?.linkText = "" }
            }
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let others = ["mp3", "wav", "flac", "m4a", "ogg", "opus", "aac", "wma", "mp4", "mkv", "webm"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent] + others
        panel.message = "Add audio or video files"
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    /// Files given in any way: the dialog, dragged on the window, opened from the Finder.
    func addFiles(_ urls: [URL]) {
        let added = urls.compactMap { register($0.path) }
        reload()
        if added.count == 1 {
            open(added[0])
        }
        startWork()
    }

    /// Add a file, or a link that a plugin opens. Says through `done` whether it was accepted.
    func add(_ text: String, done: @escaping (Bool) -> Void = { _ in }) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard Texts.isURL(text) else {
            if let key = register(text) {
                reload()
                open(key)
                startWork()
                done(true)
            } else {
                done(false)
            }
            return
        }
        guard !links.isEmpty else {
            alert("This is a link, and only files can be opened.")
            done(false)
            return
        }
        // Only the plugins, which are Python, know what a link is.
        WorkerProcess.ask(["--link", text], fallback: .error(text: "The link could not be read.")) { [weak self] answer in
            guard let self else { return }
            switch answer {
            case .link(let kind, let key, let clean):
                var whole = kind == LinkKind.list
                if kind == LinkKind.songInList {
                    switch self.choose("This song is inside a list.", buttons: ["The whole list", "Only this song", "Cancel"]) {
                    case 0: whole = true
                    case 1: whole = false
                    default:
                        done(false)
                        return
                    }
                }
                if whole {
                    self.addPlaylist(text)
                    done(true)
                } else if let song = try? self.library.add(source: clean, key: key) {
                    self.reload()
                    self.open(song.key)
                    self.startWork()
                    done(true)
                } else {
                    self.alert("The song could not be added.")
                    done(false)
                }
            case .error(let text):
                self.alert(text)
                done(false)
            default:
                done(false)
            }
        }
    }

    private func addPlaylist(_ link: String) {
        reading += 1
        showStatus()
        WorkerProcess.ask(["--add", link], fallback: .error(text: "The playlist could not be read.")) { [weak self] answer in
            guard let self else { return }
            self.reading -= 1
            switch answer {
            case .added(_, let title, let count):
                self.say("Added: \(title), \(count) songs")
            case .error(let text):
                self.alert(text)
            default:
                break
            }
            self.reload()
            self.startWork()
        }
    }

    private func register(_ path: String) -> String? {
        do {
            return try library.add(source: path).key
        } catch {
            alert(error.localizedDescription)
            return nil
        }
    }

    /// What the plugins and the models offer: asked once to the worker.
    private func askInfo() {
        WorkerProcess.ask(["--info"], fallback: .error(text: "")) { [weak self] answer in
            guard let self else { return }
            switch answer {
            case .info(let links, let problems, let stems):
                self.links = links
                if !problems.isEmpty {
                    self.say(problems.joined(separator: " "))
                }
                if !self.player.hasSong && !stems.isEmpty {
                    self.player.useParts(stems)
                }
            case .error(let text):
                if Paths.python == nil {
                    self.say(WorkerProcess.Failure.noPython.localizedDescription)
                } else if !text.isEmpty {
                    self.say(text)
                }
            default:
                break
            }
        }
    }

    // MARK: opening

    func openSelected() {
        if let key = selected.first {
            open(key)
        }
    }

    /// Open a song, now or as soon as it is ready.
    func open(_ key: String) {
        guard let song = library.get(key) else { return }
        if let error = song.error {
            say(error)
        } else if !song.ready {
            openWhenReady = key
            library.want(key)
            say("")
            player.say("Opens as soon as it is ready: \(song.title)")
            startWork()
        } else {
            openWhenReady = nil
            opening = key
            player.leave()
            let library = self.library
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let stems = try AudioFiles.loadStems(library, key: key)
                    let peaks = AppModel.allPeaks(stems)
                    DispatchQueue.main.async { self?.opened(song, stems, peaks) }
                } catch {
                    DispatchQueue.main.async { self?.player.say("\(song.title): \(error.localizedDescription)") }
                }
            }
        }
    }

    /// What the waveform needs of each stem, and of each part that is made of pieces.
    static func allPeaks(_ stems: StemSet) -> [String: [Int32]] {
        var jobs: [(String, [[Int16]])] = zip(stems.names, stems.data).map { ($0.0, [$0.1]) }
        for (part, pieces) in Parts.pieces {
            let data = zip(stems.names, stems.data).filter { pieces.contains($0.0) }.map(\.1)
            if !data.isEmpty {
                jobs.append((part, data))
            }
        }
        var found = [[Int32]](repeating: [], count: jobs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let values = Peaks.peaks(jobs[i].1)
            lock.lock()
            found[i] = values
            lock.unlock()
        }
        return Dictionary(uniqueKeysWithValues: zip(jobs.map(\.0), found))
    }

    private func opened(_ song: Song, _ stems: StemSet, _ peaks: [String: [Int32]]) {
        guard song.key == opening else {
            return  // another one was chosen meanwhile
        }
        opening = nil
        player.open(key: song.key, title: song.title, stems: stems, peaks: peaks)
        player.say("")
        windowTitle = "\(song.title) - zitto"
        settings.save(["last_song": song.key])
        player.wave.window?.makeFirstResponder(player.wave)
        sync()
    }

    // MARK: deleting, retrying, renaming

    func retry(_ keys: [String]) {
        keys.forEach(library.retry)
        say("")
        reload()
        startWork()
    }

    func renameSelected() {
        guard let key = selected.first, let song = songs[key] else { return }
        let alert = NSAlert()
        alert.messageText = "Name of the song"
        alert.informativeText = "Empty: its own name."
        let field = NSTextField(string: song.title)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.rename(key, to: field.stringValue)
        updateSong(key)
        if key == player.key, let title = songs[key]?.title {
            player.rename(title)
            windowTitle = "\(title) - zitto"
        }
    }

    /// Delete what is selected, or a whole playlist.
    func deleteSelected(playlist: String? = nil) {
        let lists = playlist.map { [$0] } ?? []
        var chosen = playlist == nil ? selected : []
        if playlist == AppModel.singles {
            chosen = groups.first { $0.id == AppModel.singles }?.rows.map(\.key) ?? []
        }
        let playlists = lists.filter { $0 != AppModel.singles }
        guard !playlists.isEmpty || !chosen.isEmpty else { return }
        let total = self.lists.filter { playlists.contains($0.id) }.map(\.songs.count).reduce(0, +)
        var what: [String] = []
        if !playlists.isEmpty { what.append("the playlist with all its \(total) songs") }
        if !chosen.isEmpty { what.append("\(chosen.count) song\(chosen.count > 1 ? "s" : "")") }
        let answer = choose("Delete \(what.joined(separator: " and ")) from this Mac?",
                            text: "Files you saved or added from your disk are not touched.", buttons: ["Delete", "Cancel"])
        if answer == 0 {
            delete(lists: playlists, keys: chosen)
        }
    }

    private func delete(lists: [String], keys: [String]) {
        work.stop()  // it may be writing one of them
        current = nil
        lists.forEach { library.deletePlaylist($0) }
        keys.forEach(library.delete)
        reload()
        startWork()
    }

    // MARK: the worker

    func startWork() {
        guard !work.running, left > 0 else { return }
        do {
            try work.start()
        } catch {
            say(error.localizedDescription)
        }
    }

    private func workEvent(_ run: Int, _ event: WorkerEvent) {
        guard run == work.run else { return }
        switch event {
        case .song(let key):
            current = key
            stage = ""
            percent = nil
            updateSong(key)
        case .status(let text):
            stage = text.hasSuffix(".") ? String(text.dropLast()) : text
            percent = nil
            if let current { updateSong(current) }
        case .progress(let value):
            percent = value
            sync()
        case .ready(let key), .failed(let key):
            current = nil
            percent = nil
            updateSong(key)
            if key == openWhenReady {
                if player.mixer?.state == .playing {  // do not cut the music
                    openWhenReady = nil
                    player.say("Ready: \(library.get(key)?.title ?? "")")
                } else {
                    open(key)
                }
            }
        case .blocked(let text):
            say("\(text). Try again later: what is missing continues at the next start.")
        case .ended(let code):
            workEnded(code)
        default:
            break
        }
    }

    private func workEnded(_ code: Int32) {
        let key = current
        current = nil
        work.ended()
        if code == WorkerExit.busy {
            say("Another window is preparing the songs.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.say("")
                self?.reload()
                self?.startWork()
            }
        } else if code != WorkerExit.done && code != WorkerExit.blocked {
            // It crashed: blame the song it was on, so as not to crash on it for ever.
            if let key {
                library.fail(key, reason: "The separation stopped unexpectedly.")
            } else {
                say("The preparation stopped unexpectedly.")
            }
        }
        reload()
        if code == WorkerExit.done || (code != WorkerExit.busy && code != WorkerExit.blocked && key != nil) {
            startWork()
        }
    }

    // MARK: keyboard

    /// Space, Home, L, Esc and the numbers act on the player, unless a text is being typed.
    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let window = NSApp.keyWindow
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                || window?.firstResponder is NSText || window?.attachedSheet != nil || window?.isSheet == true {
                return event
            }
            switch event.keyCode {
            case 49: player.perform("toggle")  // space
            case 115: player.perform("rewind")  // home
            case 53: player.perform("clear_loop")  // escape
            default:
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                if key == "l" {
                    player.toggleLoop()
                } else if let n = Int(key), (1...Parts.names.count).contains(n) {
                    player.toggleMain(n - 1)
                } else {
                    return event
                }
            }
            return nil
        }
    }

    // MARK: dialogs

    private func alert(_ text: String) {
        _ = choose("zitto", text: text, buttons: ["OK"])
    }

    /// Asks, and gives the position of the button pressed.
    private func choose(_ message: String, text: String = "", buttons: [String]) -> Int {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    func close() {
        work.stop()
        player.close()
        timer?.invalidate()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }
}
