import XCTest
@testable import ZittoCore

final class PartsTests: XCTestCase {
    let all = ["lead", "backing", "drums", "bass", "guitar", "piano", "wind", "other"]
    let pieced = ["lead", "kick", "snare", "toms", "cymbals", "bass"]

    func name(_ stems: [String], off: [String]) -> String {
        Parts.mixName(stems.map { ($0, !off.contains($0)) })
    }

    func testMixName() {
        XCTAssertEqual(name(all, off: []), "")
        XCTAssertEqual(name(all, off: ["drums"]), " (no drums)")
        XCTAssertEqual(name(all, off: ["lead"]), " (no lead voice)")
        XCTAssertEqual(name(all, off: ["lead", "backing"]), " (no voice)")
        XCTAssertEqual(name(all, off: ["lead", "backing", "guitar"]), " (no voice, guitar)")
        XCTAssertEqual(name(all, off: all.filter { $0 != "drums" && $0 != "bass" }), " (only drums, bass)")
        XCTAssertEqual(name(all, off: all.filter { $0 != "lead" && $0 != "backing" }), " (only voice)")
    }

    func testAllThePiecesAreTheDrums() {
        let stems = ["lead", "backing", "kick", "snare", "toms", "cymbals", "bass", "guitar", "other"]
        XCTAssertEqual(name(stems, off: ["kick", "snare", "toms", "cymbals"]), " (no drums)")
        XCTAssertEqual(name(stems, off: ["kick"]), " (no kick)")
        XCTAssertEqual(name(stems, off: ["lead", "backing", "kick", "snare", "toms", "cymbals"]), " (no voice, drums)")
        XCTAssertEqual(name(stems, off: ["lead", "backing", "guitar", "other"]), " (only drums, bass)")
    }

    func testThePiecesFollowTheirPart() {
        let found = Parts.controls(pieced)
        XCTAssertEqual(found.map { $0.name }, ["lead", "drums", "kick", "snare", "toms", "cymbals", "bass"])
        XCTAssertEqual(found.map { $0.part }, [nil, nil, 1, 1, 1, 1, nil])
        XCTAssertEqual(Parts.controls(["lead", "drums", "bass"]).map { $0.part }, [nil, nil, nil])
    }

    func sounding(off: [String] = [], solo: [String] = []) -> Set<String> {
        let found = Parts.controls(pieced)
        let names = found.map { $0.name }
        let result = Parts.heard(on: names.map { !off.contains($0) }, solo: names.map { solo.contains($0) },
                                 parts: found.map { $0.part })
        return Set(zip(names, result).filter { $0.1 }.map { $0.0 })
    }

    func testMutingAndSoloingPartsAndPieces() {
        let everything: Set = ["lead", "drums", "kick", "snare", "toms", "cymbals", "bass"]
        XCTAssertEqual(sounding(), everything)
        XCTAssertEqual(sounding(off: ["kick"]), everything.subtracting(["kick"]))
        XCTAssertEqual(sounding(off: ["drums"]), ["lead", "bass"])
        XCTAssertEqual(sounding(off: ["kick", "snare", "toms", "cymbals"]), ["lead", "bass"])
        XCTAssertEqual(sounding(solo: ["drums"]), everything.subtracting(["lead", "bass"]))
        XCTAssertEqual(sounding(solo: ["kick", "bass"]), ["drums", "kick", "bass"])
        XCTAssertEqual(sounding(solo: ["drums", "kick"]), ["drums", "kick"])
        XCTAssertEqual(sounding(off: ["drums"], solo: ["kick"]), [])
    }
}

final class MIDITests: XCTestCase {
    func testTrigger() {
        let cases: [([UInt8], Trigger?)] = [
            ([0x90, 60, 100], Trigger("note", 0, 60)),
            ([0x93, 60, 1], Trigger("note", 3, 60)),
            ([0x90, 60, 0], nil),
            ([0x80, 60, 64], nil),
            ([0xB0, 20, 127], Trigger("cc", 0, 20)),
            ([0xB0, 20, 64], Trigger("cc", 0, 20)),
            ([0xB0, 20, 0], nil),
            ([0xC2, 5], Trigger("program", 2, 5)),
            ([0xF0, 0x7F, 0x7F, 0x06, 0x02, 0xF7], Trigger("mmc", 2)),
            ([0xF0, 0x7E, 0x7F, 0x06, 0x02, 0xF7], nil),
            ([0xF0, 0x43], nil),
            ([0xFA], Trigger("realtime", 0xFA)),
            ([0xF8], nil),
            ([0xE0, 0, 64], nil),
            ([0x90], nil),
            ([], nil),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(MIDI.trigger(message), expected, "\(message)")
        }
    }

    func testStandardTransportWorksWithoutSetup() {
        let b = Bindings()
        XCTAssertEqual(b.actions(Trigger("mmc", 1)), ["stop"])
        XCTAssertEqual(b.actions(Trigger("mmc", 2)), ["play"])
        XCTAssertEqual(b.actions(Trigger("mmc", 5)), ["rewind"])
        XCTAssertEqual(b.actions(Trigger("mmc", 9)), ["pause"])
        XCTAssertEqual(b.actions(Trigger("mmc", 6)), [])
        XCTAssertEqual(b.actions(Trigger("realtime", 0xFA)), ["rewind", "play"])
        XCTAssertEqual(b.actions(Trigger("note", 0, 60)), [])
    }

    func testLearningReplacesAndNeverDuplicates() {
        var b = Bindings()
        b.learn("play", Trigger("note", 0, 60))
        b.learn("stop", Trigger("note", 0, 60))
        XCTAssertNil(b.get("play"))
        XCTAssertEqual(b.actions(Trigger("note", 0, 60)), ["stop"])
        b.learn("stop", Trigger("cc", 0, 20))
        XCTAssertEqual(b.actions(Trigger("note", 0, 60)), [])
        b.learn("rewind", Trigger("mmc", 2))
        XCTAssertEqual(b.actions(Trigger("mmc", 2)), ["rewind"])
        b.clear("rewind")
        XCTAssertEqual(b.actions(Trigger("mmc", 2)), ["play"])
    }

    func testBindingsSurviveSavingAndIgnoreRubbish() throws {
        var b = Bindings()
        b.learn("play", Trigger("note", 9, 36))
        b.learn("pause", Trigger("mmc", 9))
        let text = try JSONSerialization.data(withJSONObject: b.json)
        let saved = try JSONSerialization.jsonObject(with: text) as! [String: Any]
        let again = Bindings(saved: saved)
        XCTAssertEqual(again.get("play"), Trigger("note", 9, 36))
        XCTAssertEqual(again.get("pause"), Trigger("mmc", 9))
        let bad: [String: Any] = ["play": ["note", 1], "stop": "x", "fly": ["note", 0, 1], "pause": [Any](),
                                  "rewind": ["note", 0, "a"]]
        XCTAssertTrue(Bindings(saved: bad).json.isEmpty)
    }

    func testDescribe() {
        XCTAssertEqual(MIDI.describe(Trigger("note", 0, 60)), "Note 60, channel 1")
        XCTAssertEqual(MIDI.describe(Trigger("cc", 15, 7)), "CC 7, channel 16")
        XCTAssertEqual(MIDI.describe(Trigger("mmc", 2)), "MMC Play")
        XCTAssertEqual(MIDI.describe(Trigger("realtime", 0xFC)), "MIDI Stop")
    }

    func testPortsAreFoundAlsoWhenRenumbered() {
        let ports = ["Pad 0", "Keys 1"]
        XCTAssertEqual(MIDI.find("Keys 7", in: ports), "Keys 1")
        XCTAssertEqual(MIDI.find("Pad 0", in: ports), "Pad 0")
        XCTAssertNil(MIDI.find("Organ 0", in: ports))
    }

    func testUniversalPacketsBecomeMIDI1Messages() {
        var decoder = UMPDecoder()
        XCTAssertEqual(decoder.decode([0x2090_3C64]), [[0x90, 0x3C, 0x64]])  // note on
        XCTAssertEqual(decoder.decode([0x20C2_0500]), [[0xC2, 0x05]])  // program change
        XCTAssertEqual(decoder.decode([0x10FA_0000]), [[0xFA, 0, 0]])  // start
        // MMC play, F0 7F 7F 06 02 F7, in one packet of 4 bytes.
        XCTAssertEqual(decoder.decode([0x3004_7F7F, 0x0602_0000]), [[0xF0, 0x7F, 0x7F, 0x06, 0x02, 0xF7]])
        // The same split over two packets.
        XCTAssertEqual(decoder.decode([0x3012_7F7F, 0x0000_0000]), [])
        XCTAssertEqual(decoder.decode([0x3032_0602, 0x0000_0000]), [[0xF0, 0x7F, 0x7F, 0x06, 0x02, 0xF7]])
        XCTAssertEqual(MIDI.trigger(decoder.decode([0x3004_7F7F, 0x0609_0000])[0]), Trigger("mmc", 9))
    }
}

final class TextTests: XCTestCase {
    func testPlainAndSearch() {
        XCTAssertEqual(Texts.plain("  Café  DEL   Mar "), "cafe del mar")
        XCTAssertTrue(Texts.matches(Texts.words("mar cafe"), "Café del Mar", "Songs"))
        XCTAssertFalse(Texts.matches(Texts.words("mar sole"), "Café del Mar"))
        XCTAssertTrue(Texts.matches(Texts.words("song"), "Café del Mar", "Songs"))
    }

    func testFullName() {
        XCTAssertEqual(Texts.fullName(artist: "Queen", title: "Bohemian Rhapsody"), "Queen - Bohemian Rhapsody")
        XCTAssertEqual(Texts.fullName(artist: "Queen", title: "QUEEN - Bohemian Rhapsody"), "QUEEN - Bohemian Rhapsody")
        XCTAssertEqual(Texts.fullName(artist: "", title: "Alone"), "Alone")
    }

    func testSafeFilename() {
        XCTAssertEqual(Texts.safeFilename("AC/DC: Back in Black?"), "AC_DC_ Back in Black_")
        XCTAssertEqual(Texts.safeFilename("  ..name..  "), "name")
        XCTAssertEqual(Texts.safeFilename("con"), "_con")
        XCTAssertEqual(Texts.safeFilename("..."), "track")
        XCTAssertEqual(Texts.safeFilename("abcdef", limit: 3), "abc")
    }

    func testDigestIsTheOneOfPython() {
        // hashlib.sha1(b"abc").hexdigest(), and of the empty text
        XCTAssertEqual(SHA1.hex(Array("abc".utf8)), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.hex([]), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(SHA1.hex(Array(String(repeating: "a", count: 1000).utf8)),
                       "291e9a6c66994949b57ba5e650361e98fc36b1ba")
        XCTAssertEqual(Texts.digest("abc"), "a9993e364706816a")
    }
}

final class PeaksTests: XCTestCase {
    func testColumnsShowTheLoudestSampleOfEach() {
        let values: [Int32] = [1, 5, 2, 9, 3, 3, 7, 0]
        // Two values per column, from the start.
        XCTAssertEqual(Peaks.columns(values, first: 0, perPixel: Double(Peaks.hop * 2), width: 4), [5, 9, 3, 7])
        // Past the end: nothing.
        XCTAssertEqual(Peaks.columns(values, first: Double(Peaks.hop * 6), perPixel: Double(Peaks.hop * 2), width: 3),
                       [7, 0, 0])
    }

    func testLoudestValueDoesNotOverflow() {
        XCTAssertEqual(Peaks.peaks([[Int16.min, 0]]), [32768])
    }

    func testTheDrumsAreDrawnFromTheirPieces() {
        let stems = [100, 1000, 20000, 20000, 5, 7].map { [Int16](repeating: Int16($0), count: 1280) }
        XCTAssertEqual(Peaks.peaks(Array(stems[1...4])).max(), 41005)
        XCTAssertEqual(Peaks.peaks([stems[1]]).max(), 1000)
        XCTAssertEqual(Peaks.peaks([stems[0]]).count, 10)
    }

    func testClock() {
        XCTAssertEqual(Peaks.clock(0), "0:00.0")
        XCTAssertEqual(Peaks.clock(44100 * 75 + 4410), "1:15.1")
        XCTAssertEqual(Peaks.clock(44100 * 61, decimals: 0), "1:01")
        XCTAssertEqual(Peaks.clock(441 * 1234, decimals: 2), "0:12.34")
    }
}

final class WorkerProtocolTests: XCTestCase {
    func testEventsAndRubbish() {
        XCTAssertEqual(WorkerEvent.parse(Data(#"{"event": "song", "key": "abc"}"#.utf8)), .song(key: "abc"))
        XCTAssertEqual(WorkerEvent.parse(Data(#"{"event": "progress", "percent": 42}"#.utf8)), .progress(percent: 42))
        XCTAssertEqual(WorkerEvent.parse(Data(#"{"event": "added", "id": "x", "title": "Mine", "count": 2}"#.utf8)),
                       .added(id: "x", title: "Mine", count: 2))
        XCTAssertEqual(WorkerEvent.parse(Data(#"{"event": "link", "kind": "list", "key": "k", "clean": "c"}"#.utf8)),
                       .link(kind: "list", key: "k", clean: "c"))
        XCTAssertNil(WorkerEvent.parse(Data("Downloading...".utf8)))
        XCTAssertNil(WorkerEvent.parse(Data(#"{"no": "event"}"#.utf8)))
    }

    func testLinesArriveInPieces() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.feed(Data("ab".utf8)), [])
        XCTAssertEqual(splitter.feed(Data("c\nde\nf".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["abc", "de"])
        XCTAssertEqual(splitter.finish().map { String(decoding: $0, as: UTF8.self) }, "f")
    }

    func testPercentOfProgressBars() {
        XCTAssertEqual(lastPercent(Data(" 12%|██    | 3/25\r 48%|█████ | 12/25".utf8)), 48)
        XCTAssertEqual(lastPercent(Data("100%|██████████|".utf8)), 100)
        XCTAssertNil(lastPercent(Data("nothing here".utf8)))
    }
}

final class LibraryTests: XCTestCase {
    var root: URL!
    var library: Library!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zitto-\(UUID().uuidString)")
        library = Library(root: root.appendingPathComponent("library"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func makeFile(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: url)
        return url.path
    }

    func testAddingTwiceKeepsOneSongAndRetriesIt() throws {
        let path = try makeFile("Artist - Title.wav")
        let song = try library.add(source: path)
        XCTAssertEqual(song.title, "Artist - Title")
        XCTAssertFalse(song.ready)
        library.fail(song.key, reason: "broken")
        XCTAssertEqual(library.get(song.key)?.error, "broken")
        let again = try library.add(source: path)
        XCTAssertEqual(again.key, song.key)
        XCTAssertNil(again.error)
        XCTAssertEqual(again.order, song.order)
        XCTAssertEqual(library.songs().count, 1)
    }

    func testOrderRenameAndWaiting() throws {
        let a = try library.add(source: try makeFile("a.wav"))
        let b = try library.add(source: try makeFile("b.wav"))
        XCTAssertEqual(library.songs().map { $0.key }, [a.key, b.key])
        XCTAssertEqual(library.waiting().map { $0.key }, [a.key, b.key])
        library.want(b.key)
        XCTAssertEqual(library.waiting().map { $0.key }, [b.key, a.key])
        library.rename(a.key, to: "  My   song ")
        XCTAssertEqual(library.get(a.key)?.title, "My song")
        library.rename(a.key, to: "")
        XCTAssertEqual(library.get(a.key)?.title, "a")
    }

    func testTitleFromTheDownload() throws {
        let song = try library.add(source: "https://songs.example/alpha", key: "song-alpha")
        XCTAssertEqual(song.title, "https://songs.example/alpha")
        try JSONStore.write(try library.folder("song-alpha").appendingPathComponent("download.json"),
                            ["title": "Alpha", "artist": "Band", "file": "original.wav"])
        XCTAssertEqual(library.get("song-alpha")?.title, "Band - Alpha")
    }

    func testReadyWhenTheWorkerHasStoredTheStems() throws {
        let song = try library.add(source: try makeFile("a.wav"))
        try JSONStore.write(try library.folder(song.key).appendingPathComponent("stems.json"),
                            ["names": ["lead", "other"], "gain": 2.5])
        XCTAssertTrue(library.get(song.key)!.ready)
        XCTAssertTrue(library.waiting().isEmpty)
        let info = try library.stemInfo(song.key)
        XCTAssertEqual(info.names, ["lead", "other"])
        XCTAssertEqual(info.gain, 2.5)
    }

    func testDeletingAPlaylistKeepsTheSongsThatAreElsewhere() throws {
        let single = try library.add(source: try makeFile("a.wav"))
        let only = try library.add(source: "https://songs.example/b", key: "song-b", single: false)
        try JSONStore.write(library.root.appendingPathComponent("playlists.json"), ["playlists": [
            ["id": "one", "title": "Mine", "songs": [single.key, only.key]],
        ]])
        XCTAssertEqual(library.playlists(), [SavedPlaylist(id: "one", title: "Mine", songs: [single.key, only.key])])
        XCTAssertEqual(library.deletePlaylist("one"), [only.key])
        XCTAssertEqual(library.songs().map { $0.key }, [single.key])
        XCTAssertTrue(library.playlists().isEmpty)
    }

    func testDeletingASongNeverTouchesTheUsersFile() throws {
        let path = try makeFile("a.wav")
        let song = try library.add(source: path)
        library.delete(song.key)
        XCTAssertNil(library.get(song.key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testPlayerStateIsKeptUnlessTheSongWasDeleted() throws {
        let song = try library.add(source: "https://songs.example/alpha", key: "song-alpha")
        library.saveState(song.key, ["loop": [1, 2]])
        XCTAssertEqual(library.loadState(song.key)["loop"] as? [Int], [1, 2])
        library.delete(song.key)
        library.saveState(song.key, ["loop": [1, 2]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try library.folder(song.key).path))
    }

    func testNotASong() {
        XCTAssertThrowsError(try library.folder("../x"))
        XCTAssertThrowsError(try library.add(source: "/no/such/file.mp3"))
    }

    func testSettings() {
        let settings = SettingsFile(url: root.appendingPathComponent("settings.json"))
        XCTAssertTrue(settings.load().isEmpty)
        settings.save(["midi_port": "Pad 0"])
        settings.save(["midi": ["play": ["note", 0, 1]]])
        XCTAssertEqual(settings.load()["midi_port"] as? String, "Pad 0")
        XCTAssertNotNil(settings.load()["midi"] as? [String: Any])
    }
}
