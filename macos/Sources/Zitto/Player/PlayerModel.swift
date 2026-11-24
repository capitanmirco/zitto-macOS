import AppKit
import Combine
import UniformTypeIdentifiers
import ZittoCore

/// The player: parts switched live, waveform with a loop, MIDI transport, saving the mix.
/// The equivalent of PlayerView in player.py, without the widgets.
final class PlayerModel: ObservableObject {
    static let noPort = "Off"

    // What the views show.
    @Published private(set) var key: String?
    @Published private(set) var title = ""
    @Published private(set) var names: [String] = []  // what can be switched in the song that is open
    @Published private(set) var wholes: [Int?] = []  // for a piece, the position of its part
    @Published private(set) var rows: [Int] = []  // those that are shown
    @Published private(set) var opened: Set<String> = []  // parts whose pieces are shown
    @Published private(set) var on: [Bool] = []
    @Published private(set) var solo: [Bool] = []
    @Published private(set) var volume: [Float] = []
    @Published private(set) var audible: [Bool] = []
    @Published private(set) var message = ""
    @Published private(set) var timeText = ""
    @Published private(set) var transport = Mixer.State.stopped
    @Published private(set) var loopOn = false
    @Published private(set) var loopText = ""
    @Published private(set) var saving = false
    @Published private(set) var ports: [String] = [PlayerModel.noPort]
    @Published private(set) var port = PlayerModel.noPort
    @Published private(set) var learning: String?
    @Published private(set) var bindings: Bindings

    let wave = WaveformView()
    private(set) var mixer: Mixer?
    private var stems: StemSet?
    private var peaks: [String: [Int32]] = [:]
    private var output: AudioOutput?
    private var midi: MIDIInput?
    private var wantedPort: String?
    private let library: Library
    private let settings: SettingsFile
    private let router = MIDIRouter()
    var hasSong: Bool { mixer != nil }

    init(library: Library, settings: SettingsFile) {
        self.library = library
        self.settings = settings
        let saved = settings.load()
        bindings = Bindings(saved: saved["midi"] as? [String: Any])
        wantedPort = saved["midi_port"] as? String
        router.bindings = bindings
        useParts(Parts.defaultStems)
        wave.onSeek = { [weak self] in self?.mixer?.seek($0) }
        wave.onLoop = { [weak self] in self?.mixer?.setLoop($0, $1) }
        do {
            output = try AudioOutput()
        } catch {
            say("No audio output: \(error.localizedDescription)")
        }
        do {
            let midi = try MIDIInput { [weak self] message in self?.onMIDI(message) }
            midi.onChange = { [weak self] in self?.watchPorts() }
            self.midi = midi
            watchPorts()
        } catch {
            say("MIDI is not available: \(error.localizedDescription)")
        }
        applyLevels()
    }

    // MARK: parts

    /// Show the controls of these stems: songs separated with other models have others.
    func useParts(_ stems: [String]) {
        let found = Parts.controls(stems)
        let newNames = found.map(\.name)
        if newNames != names {
            names = newNames
            wholes = found.map(\.part)
            on = Array(repeating: true, count: names.count)
            solo = Array(repeating: false, count: names.count)
            volume = Array(repeating: 1, count: names.count)
            buildRows()
        }
    }

    private func buildRows() {
        rows = names.indices.filter { i in wholes[i].map { opened.contains(names[$0]) } ?? true }
        let shown = rows.map { names[$0] }
        if mixer != nil, shown.allSatisfy({ peaks[$0] != nil }) {
            wave.setLanes(shown.map { peaks[$0]! }, colors: shown.map(Theme.part))
        }
    }

    /// Whether a row is a piece of another one, and whether it has pieces (and they are shown).
    func isPiece(_ i: Int) -> Bool { wholes[i] != nil }
    func hasPieces(_ i: Int) -> Bool { wholes.contains(i) }

    func togglePieces(_ i: Int) {
        let part = names[i]
        if opened.contains(part) { opened.remove(part) } else { opened.insert(part) }
        buildRows()
        applyLevels()
    }

    // MARK: songs

    /// Remember how the song was left and fade it out.
    func leave() {
        if let mixer, let key {
            library.saveState(key, state())
            if mixer.state == .playing {
                mixer.pause()
            }
        }
    }

    /// Show a song. The previous one must have been left.
    func open(key: String, title: String, stems: StemSet, peaks: [String: [Int32]]) {
        let mixer = Mixer(stems: stems.data, gain: stems.gain)
        self.key = key
        self.title = title
        self.stems = stems
        self.peaks = peaks
        self.mixer = mixer
        useParts(stems.names)
        buildRows()
        let shown = rows.map { names[$0] }
        wave.setTracks(shown.map { peaks[$0] ?? [] }, colors: shown.map(Theme.part), length: mixer.length)
        restore(library.loadState(key))
        output?.mixer = mixer
        router.mixer = mixer
        refresh()
    }

    func rename(_ title: String) {
        self.title = title
    }

    func state() -> [String: Any] {
        guard let mixer else { return [:] }
        func byName<T>(_ values: [T]) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: zip(names, values.map { $0 as Any }))
        }
        let loop = mixer.loop
        return ["on": byName(on), "solo": byName(solo), "volume": byName(volume.map(Double.init)),
                "loop": loop.map { [$0.start, $0.end] as Any } ?? NSNull(), "loop_on": mixer.loopOn,
                "position": mixer.position, "opened": opened.sorted()]
    }

    private func restore(_ state: [String: Any]) {
        guard let mixer else { return }
        func part(_ kind: String, _ name: String) -> Any? {
            (state[kind] as? [String: Any])?[name]
        }
        let wanted = Set(state["opened"] as? [String] ?? []).intersection(Parts.pieces.keys)
        if wanted != opened {
            opened = wanted
            buildRows()
        }
        on = names.map { name in part("on", name).map { JSONValue.bool($0) } ?? true }
        solo = names.map { name in part("solo", name).map { JSONValue.bool($0) } ?? false }
        volume = names.map { Float(min(max(JSONValue.double(part("volume", $0)) ?? 1, 0), 1)) }
        if let loop = state["loop"] as? [Any], loop.count == 2,
           let start = JSONValue.int(loop[0]), let end = JSONValue.int(loop[1]) {
            mixer.setLoop(start, end)
            mixer.enableLoop(JSONValue.bool(state["loop_on"]))
        }
        mixer.seek(JSONValue.int(state["position"]) ?? 0)
        applyLevels()
    }

    // MARK: actions

    func say(_ text: String) {
        message = text
    }

    /// A transport action of the mixer, when there is a song.
    func perform(_ action: String) {
        mixer?.perform(action)
        refresh()
    }

    func toggleLoop() {
        guard let mixer else { return }
        if mixer.loop == nil {
            say("Drag on the waveform to choose what to repeat.")
        }
        mixer.enableLoop(!mixer.loopOn)
        refresh()
    }

    /// The n-th part, not counting the pieces: for the keyboard.
    func toggleMain(_ n: Int) {
        let main = wholes.indices.filter { wholes[$0] == nil }
        if n < main.count {  // the keys are there for all the parts that can exist
            togglePart(main[n])
        }
    }

    func togglePart(_ i: Int) {
        on[i].toggle()
        applyLevels()
    }

    func toggleSolo(_ i: Int) {
        solo[i].toggle()
        applyLevels()
    }

    func setVolume(_ i: Int, _ value: Float) {
        volume[i] = min(max(value, 0), 1)
        applyLevels()
    }

    /// Of each stem of the song, in order.
    func levels() -> [(name: String, level: Float)] {
        let heard = Parts.heard(on: on, solo: solo, parts: wholes)
        return names.indices.filter { !wholes.contains($0) }.map { i in
            let level = volume[i] * (wholes[i].map { volume[$0] } ?? 1)
            // Squared: the slider follows how loud it sounds rather than the amplitude.
            return (names[i], heard[i] ? level * level : 0)
        }
    }

    private func applyLevels() {
        audible = Parts.heard(on: on, solo: solo, parts: wholes)
        for (n, item) in levels().enumerated() {
            mixer?.setLevel(n, item.level)
        }
        wave.setAudible(rows.map { audible[$0] })
    }

    // MARK: saving

    /// Save what is heard: the parts that are on, at their volumes.
    func save() {
        guard let stems, let key, !saving else { return }
        let levels = self.levels()
        guard levels.contains(where: { $0.level > 0 }) else {
            say("Every part is off: there is nothing to save.")
            return
        }
        let name = Texts.safeFilename(title, limit: 110) + Parts.mixName(levels.map { ($0.name, $0.level > 0) })
        let start = (settings.load()["save_dir"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Paths.output
        try? FileManager.default.createDirectory(at: start, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.directoryURL = start
        panel.nameFieldStringValue = "\(name).mp3"
        panel.allowedContentTypes = [UTType.mp3, UTType(filenameExtension: "flac") ?? .audio, UTType.wav]
        panel.message = "Save the song as you hear it: as .mp3, .flac or .wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.save(["save_dir": url.deletingLastPathComponent().path])
        saving = true
        say("Saving \(url.lastPathComponent)...")
        let song = library.get(key)
        let values = levels.map(\.level)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: Error?
            do {
                var tags: URL? = nil
                if let source = song?.source, !Texts.isURL(source), FileManager.default.fileExists(atPath: source),
                   Library.resolve(source) != Library.resolve(url.path) {
                    tags = URL(fileURLWithPath: source)
                }
                var audio = mixdown(stems.data, gain: stems.gain, levels: values)
                limit(&audio)
                try AudioFiles.encode(audio, to: url, tagsFrom: tags, title: song?.title ?? "")
            } catch {
                result = error
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.saving = false
                if let result {
                    self.say("Could not save.")
                    let alert = NSAlert()
                    alert.messageText = "Could not save."
                    alert.informativeText = result.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                } else {
                    self.say("Saved: \(url.lastPathComponent)")
                }
            }
        }
    }

    // MARK: MIDI

    /// MIDI thread: acts on the mixer at once, the window catches up on the main thread.
    private func onMIDI(_ message: [UInt8]) {
        guard let t = MIDI.trigger(message) else { return }
        switch router.route(t) {
        case .learned(let action):
            DispatchQueue.main.async { self.learned(action, t) }
        case .actions(let actions, let mixer):
            for action in actions { mixer?.perform(action) }
            DispatchQueue.main.async {
                self.say("MIDI: \(MIDI.describe(t))" + (actions.isEmpty ? "" : " (\(actions.joined(separator: ", ")))"))
                self.refresh()
            }
        }
    }

    private func learned(_ action: String, _ t: Trigger) {
        bindings.learn(action, t)
        router.bindings = bindings
        learning = nil
        router.learning = nil
        settings.save(["midi": bindings.json])
        say("\(MIDI.describe(t)): \(action)")
    }

    /// Follow devices being plugged and unplugged; reopen the chosen one when it is back.
    func watchPorts() {
        guard let midi else { return }
        let now = midi.ports()
        if ports != [PlayerModel.noPort] + now {
            ports = [PlayerModel.noPort] + now
        }
        if let name = midi.name, !now.contains(name) {
            say("MIDI device disconnected: \(name)")
            midi.close()
            port = PlayerModel.noPort
        }
        if let wanted = wantedPort, midi.name == nil, let name = MIDI.find(wanted, in: now) {
            openPort(name)
        }
    }

    func choosePort(_ name: String) {
        wantedPort = name == PlayerModel.noPort ? nil : name
        settings.save(["midi_port": wantedPort.map { $0 as Any } ?? NSNull()])
        guard let midi else { return }
        if let wanted = wantedPort {
            openPort(wanted)
        } else {
            midi.close()
            port = PlayerModel.noPort
            say("")
        }
    }

    private func openPort(_ name: String) {
        do {
            try midi?.open(name)
            port = name
            say("MIDI connected: \(name)")
        } catch {
            wantedPort = nil  // do not insist; choosing it again retries
            port = PlayerModel.noPort
            say(error.localizedDescription)
        }
    }

    func learn(_ action: String) {
        learning = learning == action ? nil : action
        if learning != nil && midi?.name == nil {
            learning = nil
            say("Choose a MIDI device first.")
        }
        router.learning = learning
    }

    func unlearn(_ action: String) {
        bindings.clear(action)
        router.bindings = bindings
        settings.save(["midi": bindings.json])
    }

    func stopLearning() {
        learning = nil
        router.learning = nil
    }

    // MARK: refresh

    /// Called many times a second by the window.
    func refresh() {
        guard let mixer else { return }
        let state = mixer.state, loop = mixer.loop, on = mixer.loopOn
        var position = mixer.position
        if state == .playing, let output {  // what is heard now left the mixer a moment ago
            let first = on && loop != nil && position >= loop!.start ? loop!.start : 0
            position = max(position - output.latency, first)
        }
        wave.setLoop(loop.map { ($0.start, $0.end) }, on: on)
        wave.setHead(position, follow: state == .playing)
        let time = "\(Peaks.clock(position)) / \(Peaks.clock(mixer.length))"
        if time != timeText { timeText = time }
        if state != transport { transport = state }
        if on != loopOn { loopOn = on }
        let text = loop.map {
            "\(Peaks.clock($0.start, decimals: 2)) - \(Peaks.clock($0.end, decimals: 2))  ("
                + String(format: "%.2f s)", Double($0.end - $0.start) / Double(sampleRate))
        } ?? ""
        if text != loopText { loopText = text }
    }

    func close() {
        leave()
        output?.close()
        router.mixer = nil
        midi?.close()
    }
}

/// What the MIDI thread may read: the bindings and whether a button is being learned.
private final class MIDIRouter {
    enum Route {
        case learned(String)
        case actions([String], Mixer?)
    }

    private let lock = FastLock()
    private var _bindings = Bindings()
    private var _learning: String?
    private var _mixer: Mixer?

    var mixer: Mixer? {
        get { lock.run { _mixer } }
        set { lock.run { _mixer = newValue } }
    }

    var bindings: Bindings {
        get { lock.run { _bindings } }
        set { lock.run { _bindings = newValue } }
    }

    var learning: String? {
        get { lock.run { _learning } }
        set { lock.run { _learning = newValue } }
    }

    func route(_ t: Trigger) -> Route {
        lock.run {
            if let action = _learning {
                _learning = nil
                return .learned(action)
            }
            return .actions(_bindings.actions(t), _mixer)
        }
    }
}
