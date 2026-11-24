import XCTest
@testable import ZittoCore

/// The same cases as tests/test_player.py, on the Swift mixer.
final class MixerTests: XCTestCase {
    let n = 40000
    let fade = Mixer.fade

    /// Left channel: the sample number, so the output tells exactly what was played.
    func rampStem() -> [Int16] {
        var data = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n { data[2 * i] = Int16(i / 2) }
        return data
    }

    func tone(_ freq: Double, level: Double = 8000) -> [Int16] {
        var data = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            let x = Int16((level * sin(2 * Double.pi * freq * Double(i) / 44100)).rounded(.towardZero))
            data[2 * i] = x
            data[2 * i + 1] = x
        }
        return data
    }

    func render(_ mixer: Mixer, _ total: Int, block: Int = 512) -> [Float] {
        var out: [Float] = []
        var left = total
        while left > 0 {
            let size = min(block, left)
            out += mixer.render(frames: size)
            left -= size
        }
        return out
    }

    /// Sample positions from the ramp stem.
    func positions(_ out: [Float]) -> [Int] {
        stride(from: 0, to: out.count, by: 2).map { Int((out[$0] * 32768).rounded()) * 2 }
    }

    func biggestStep(_ out: [Float]) -> Float {
        var biggest: Float = 0
        for i in 2..<out.count { biggest = max(biggest, abs(out[i] - out[i - 2])) }
        return biggest
    }

    func testAllStemsTogetherAreTheExactSum() {
        let parts = [tone(200), tone(555), tone(900)]
        let mixer = Mixer(stems: parts, gain: 1.25)
        mixer.play()
        let out = render(mixer, 20000)
        for i in fade * 2..<40000 {
            let expected = Float(parts.map { Double($0[i]) }.reduce(0, +) * 1.25 / 32768)
            XCTAssertEqual(out[i], expected, accuracy: 1e-5)
        }
    }

    func testSilentUntilPlay() {
        let mixer = Mixer(stems: [tone(200)])
        XCTAssertTrue(render(mixer, 5000).allSatisfy { $0 == 0 })
        XCTAssertEqual(mixer.position, 0)
        XCTAssertEqual(mixer.state, .stopped)
    }

    func testResultDoesNotDependOnTheBlockSize() {
        func play(_ size: Int) -> [Float] {
            let mixer = Mixer(stems: [tone(200)])
            mixer.setLoop(1000, 9000)
            mixer.play()
            return render(mixer, 30000, block: size)
        }
        let reference = play(1)
        for block in [64, 333, 512, 4096] {
            let out = play(block)
            for i in 0..<out.count { XCTAssertEqual(out[i], reference[i], accuracy: 1e-5) }
        }
    }

    func testLoudMixIsClippedNotWrapped() {
        let mixer = Mixer(stems: [tone(200, level: 30000), tone(200, level: 30000)])
        mixer.play()
        XCTAssertEqual(render(mixer, 8000).map(abs).max(), 1.0)
    }

    func testLoopRepeatsWithExactLength() {
        let mixer = Mixer(stems: [rampStem()])
        mixer.setLoop(8000, 18000)
        XCTAssertEqual(mixer.position, 8000)
        mixer.play()
        let pos = positions(render(mixer, 35000))
        for turn in 0..<3 {
            let start = turn * 10000
            for i in start + fade..<start + 10000 - fade {
                XCTAssertEqual(Double(pos[i]), Double(8000 + i - start), accuracy: 2)
            }
        }
        XCTAssertLessThan(pos.max()!, 18000)
        XCTAssertEqual(mixer.state, .playing)
    }

    func testLoopSeamHasNoClick() {
        let mixer = Mixer(stems: [tone(440)])
        mixer.setLoop(5000, 5000 + 10037)
        mixer.play()
        let natural = biggestStep(tone(440).map { Float($0) / 32768 })
        XCTAssertLessThan(biggestStep(render(mixer, 40000)), natural * 1.6)
    }

    func testPlayingIntoALoopThenRepeating() {
        let mixer = Mixer(stems: [rampStem()])
        mixer.setLoop(8000, 18000)
        mixer.seek(2000)
        mixer.play()
        let pos = positions(render(mixer, 20000))
        for i in fade..<15000 { XCTAssertEqual(Double(pos[i]), Double(2000 + i), accuracy: 2) }
        XCTAssertEqual(Double(pos[16500]), 8500, accuracy: 2)
    }

    func testSeekCloseToTheEndOfTheLoopStillRepeats() {
        let mixer = Mixer(stems: [rampStem()])
        mixer.setLoop(8000, 18000)
        mixer.seek(17990)
        mixer.play()
        XCTAssertLessThan(positions(render(mixer, 3000)).max()!, 18000)
    }

    func testNewLoopMovesThePlayheadOnlyWhenOutside() {
        let mixer = Mixer(stems: [rampStem()])
        mixer.seek(10000)
        mixer.setLoop(8000, 18000)
        XCTAssertEqual(mixer.position, 10000)
        mixer.setLoop(20000, 30000)
        XCTAssertEqual(mixer.position, 20000)
    }

    func testLoopIsOrderedBoundedAndNotTooShort() {
        let mixer = Mixer(stems: [rampStem()])
        mixer.setLoop(18000, 8000)
        XCTAssertTrue(mixer.loop! == (8000, 18000))
        mixer.setLoop(100, 101)
        XCTAssertTrue(mixer.loop! == (100, 100 + Mixer.minLoop))
        mixer.setLoop(n - 5, n + 999)
        XCTAssertTrue(mixer.loop! == (n - Mixer.minLoop, n))
    }

    func testLoopCanBeSwitchedOffAndOn() {
        let mixer = Mixer(stems: [rampStem()])
        mixer.enableLoop(true)
        XCTAssertFalse(mixer.loopOn)
        mixer.setLoop(8000, 18000)
        mixer.enableLoop(false)
        mixer.play()
        XCTAssertGreaterThan(positions(render(mixer, 15000)).max()!, 20000)
        mixer.enableLoop(true)
        XCTAssertEqual(mixer.position, 8000)
        mixer.clearLoop()
        XCTAssertNil(mixer.loop)
        XCTAssertFalse(mixer.loopOn)
    }

    func testPauseResumesFromTheSamePoint() {
        let mixer = Mixer(stems: [rampStem()])
        mixer.play()
        _ = render(mixer, 10240)
        mixer.pause()
        let out = render(mixer, 2048)
        let held = mixer.position
        XCTAssertEqual(mixer.state, .paused)
        XCTAssertTrue(out[(fade * 2)...].allSatisfy { $0 == 0 })
        XCTAssertEqual(Double(held), 10240, accuracy: Double(fade))
        mixer.pause()
        XCTAssertEqual(mixer.state, .playing)
        XCTAssertEqual(Double(positions(render(mixer, 512)).last!), Double(held + 511), accuracy: 2)
    }

    func testStopAndRewindGoToTheStartOfTheLoop() {
        for (loop, home) in [(nil, 0), ((8000, 18000), 8000)] as [((Int, Int)?, Int)] {
            let mixer = Mixer(stems: [rampStem()])
            if let loop { mixer.setLoop(loop.0, loop.1) }
            mixer.play()
            _ = render(mixer, 4096)
            mixer.rewind()
            XCTAssertEqual(mixer.state, .playing)
            XCTAssertEqual(Double(positions(render(mixer, 1024)).last!), Double(home + 1023), accuracy: 2)
            mixer.stop()
            XCTAssertEqual(mixer.state, .stopped)
            XCTAssertEqual(mixer.position, home)
            let out = render(mixer, 1024)
            XCTAssertTrue(out[(fade * 2)...].allSatisfy { $0 == 0 })
            XCTAssertEqual(mixer.position, home)
            mixer.play()
            XCTAssertEqual(Double(positions(render(mixer, 1024)).last!), Double(home + 1023), accuracy: 2)
        }
    }

    func testTransportHasNoClicks() {
        let mixer = Mixer(stems: [tone(440)])
        let natural = biggestStep(tone(440).map { Float($0) / 32768 })
        mixer.play()
        var out = render(mixer, 3001)
        let actions: [() -> Void] = [mixer.pause, mixer.pause, mixer.rewind, mixer.stop, mixer.play,
                                     { mixer.seek(20000) }, { mixer.setLoop(2000, 9000) }, mixer.stop]
        for action in actions {
            action()
            out += render(mixer, 3001)
        }
        XCTAssertLessThan(biggestStep(out), natural * 1.6)
    }

    func testEndOfTheTrackStopsAndReturnsToTheStart() {
        let mixer = Mixer(stems: [rampStem()])
        mixer.seek(n - 1000)
        mixer.play()
        let out = render(mixer, 4096)
        XCTAssertEqual(mixer.state, .stopped)
        XCTAssertEqual(mixer.position, 0)
        XCTAssertTrue(out[2000...].allSatisfy { $0 == 0 })
    }

    func testMixdownIsWhatIsHeard() {
        let parts = [tone(200), tone(555), tone(900)]
        let levels: [Float] = [1.0, 0.0, 0.25]
        let mixer = Mixer(stems: parts, gain: 1.2)
        for (i, level) in levels.enumerated() { mixer.setLevel(i, level) }
        _ = render(mixer, 512)
        mixer.play()
        let heard = render(mixer, 20000)
        let whole = mixdown(parts, gain: 1.2, levels: levels)
        for i in fade * 2..<40000 { XCTAssertEqual(whole[i], heard[i], accuracy: 1e-5) }
    }

    func testChannelsApartAreTheSame() {
        let mixer = Mixer(stems: [tone(300)])
        let twin = Mixer(stems: [tone(300)])
        mixer.play()
        twin.play()
        var left = [Float](repeating: 0, count: 700), right = left
        mixer.render(frames: 700, left: &left, right: &right)
        let together = twin.render(frames: 700)
        for i in 0..<700 {
            XCTAssertEqual(left[i], together[2 * i])
            XCTAssertEqual(right[i], together[2 * i + 1])
        }
    }
}
