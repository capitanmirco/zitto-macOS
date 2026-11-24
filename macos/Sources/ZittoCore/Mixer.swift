import Foundation
#if canImport(os)
import os
#endif

/// A lock short enough for the audio thread.
public final class FastLock {
    #if canImport(os)
    private let unfair: UnsafeMutablePointer<os_unfair_lock>

    public init() {
        unfair = .allocate(capacity: 1)
        unfair.initialize(to: os_unfair_lock())
    }

    deinit {
        unfair.deallocate()
    }

    @inline(__always) public func lock() { os_unfair_lock_lock(unfair) }
    @inline(__always) public func unlock() { os_unfair_lock_unlock(unfair) }
    #else
    private let mutex = NSLock()

    public init() {}

    @inline(__always) public func lock() { mutex.lock() }
    @inline(__always) public func unlock() { mutex.unlock() }
    #endif

    @inline(__always) public func run<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Transport, loop and live mixing of the stems of one track: a port of mixer.py.
///
/// There is no audio device here: `render` is called by the sound card (see AudioOutput) and by
/// the tests. Every public method can be called from any thread.
public final class Mixer {
    public enum State: String {
        case playing, paused, stopped
    }

    /// Samples (3 ms): long enough to hide a jump, short enough not to be heard.
    public static let fade = 128
    public static let minLoop = sampleRate / 20

    public let length: Int
    private let stems: [[Int16]]  // interleaved stereo
    private let unit: Float
    private let lock = FastLock()
    private var wanted: [Float]
    private var level: [Float]  // follows `wanted`, one block at a time
    private var pos = 0
    private var _state = State.stopped
    private var gate = 0  // 0 silent ... fade fully open
    private var park: Int? = nil  // where to go once the gate has closed
    private var fadeFrom = 0
    private var fadeLeft = 0
    private var _loop: (start: Int, end: Int)? = nil
    private var _loopOn = false

    // Gain of each stem in this block, at frame k: base + slope * (k + 1).
    private var base: [Float]
    private var slope: [Float]
    // Room for one block, and for what it blends from: allocated outside the audio thread.
    private var result: UnsafeMutablePointer<Float>
    private var other: UnsafeMutablePointer<Float>
    private var capacity = 0

    /// `stems`: interleaved stereo int16, all of the same length. `gain`: their overall level.
    public init(stems: [[Int16]], gain: Float = 1.0) {
        precondition(!stems.isEmpty, "a song has at least one part")
        self.stems = stems
        length = stems[0].count / 2
        unit = gain / 32768
        wanted = Array(repeating: 1, count: stems.count)
        level = wanted
        base = Array(repeating: 0, count: stems.count)
        slope = base
        result = .allocate(capacity: 2)
        other = .allocate(capacity: 2)
        capacity = 1
        reserve(8192)
    }

    deinit {
        result.deallocate()
        other.deallocate()
    }

    /// Only grows when the sound card asks for more than ever before.
    private func reserve(_ frames: Int) {
        if frames > capacity {
            result.deallocate()
            other.deallocate()
            capacity = frames
            result = .allocate(capacity: frames * 2)
            other = .allocate(capacity: frames * 2)
        }
    }

    // MARK: state

    public var state: State {
        lock.run { _state }
    }

    public var loop: (start: Int, end: Int)? {
        lock.run { _loop }
    }

    public var loopOn: Bool {
        lock.run { _loopOn }
    }

    public var position: Int {
        lock.run { min(max(park ?? pos, 0), length) }
    }

    // MARK: transport

    public func play() {
        lock.run {
            if let park {
                move(park)
            }
            _state = .playing
        }
    }

    /// Pause, or resume when already paused.
    public func pause() {
        lock.run {
            if _state == .playing {
                _state = .paused
            } else if _state == .paused {
                if let park {
                    move(park)
                }
                _state = .playing
            }
        }
    }

    public func toggle() {
        state == .playing ? pause() : play()
    }

    /// Stop and go back to the start of the loop.
    public func stop() {
        lock.run {
            _state = .stopped
            place(home)
        }
    }

    /// Back to the start of the loop, without changing whether it plays.
    public func rewind() {
        lock.run { place(home) }
    }

    public func seek(_ position: Int) {
        lock.run {
            var position = min(max(position, 0), length)
            if _loopOn, let loop = _loop, seam <= position && position < loop.end {
                position = seam - 1  // too close to the end to still repeat
            }
            place(position)
        }
    }

    public func setLoop(_ start: Int, _ end: Int) {
        lock.run {
            let a = min(max(start, 0), length), b = min(max(end, 0), length)
            var start = min(a, b), end = max(a, b)
            if end - start < Mixer.minLoop {
                end = min(start + Mixer.minLoop, length)
                start = max(end - Mixer.minLoop, 0)
            }
            _loop = (start, end)
            _loopOn = true
            enterLoop()
        }
    }

    public func clearLoop() {
        lock.run {
            _loop = nil
            _loopOn = false
        }
    }

    public func enableLoop(_ on: Bool) {
        lock.run {
            _loopOn = on && _loop != nil
            if _loopOn {
                enterLoop()
            }
        }
    }

    public func setLevel(_ index: Int, _ value: Float) {
        lock.run { wanted[index] = value }
    }

    /// Runs one of the transport actions by name: those of MIDI bindings and of the buttons.
    public func perform(_ action: String) {
        switch action {
        case "play": play()
        case "pause": pause()
        case "stop": stop()
        case "rewind": rewind()
        case "toggle": toggle()
        case "clear_loop": clearLoop()
        default: break
        }
    }

    // MARK: helpers, called with the lock held

    private var home: Int {
        _loopOn ? _loop!.start : 0
    }

    /// Where the end of the loop starts blending into what precedes its beginning.
    private var seam: Int {
        _loop!.end - Mixer.fade
    }

    private func enterLoop() {
        let at = park ?? pos
        if !(_loop!.start <= at && at < seam) {
            place(_loop!.start)
        }
    }

    /// Change position as soon as it can be done without a click.
    private func place(_ position: Int) {
        if gate > 0 && _state != .playing {
            park = position  // still fading out
        } else {
            move(position)
        }
    }

    private func move(_ position: Int) {
        if gate > 0 {
            fadeFrom = pos
            fadeLeft = Mixer.fade
        }
        pos = position
        park = nil
    }

    // MARK: audio

    /// The next `frames` samples, interleaved stereo float, clipped to -1...1.
    public func render(frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        out.withUnsafeMutableBufferPointer { render(frames: frames, into: $0.baseAddress!) }
        return out
    }

    /// Fill `left` and `right`: for a sound card that wants the channels apart.
    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        renderInterleaved(frames: frames) { interleaved in
            for i in 0..<frames {
                left[i] = interleaved[2 * i]
                right[i] = interleaved[2 * i + 1]
            }
        }
    }

    /// Interleaved stereo into `out`, which holds 2 * frames values.
    public func render(frames: Int, into out: UnsafeMutablePointer<Float>) {
        renderInterleaved(frames: frames) { interleaved in
            out.update(from: interleaved, count: frames * 2)
        }
    }

    private func renderInterleaved(frames: Int, deliver: (UnsafePointer<Float>) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        reserve(frames)
        let out = result
        out.update(repeating: 0, count: frames * 2)
        prepareGains(frames)
        var done = 0
        while done < frames {
            let n = advanceLimit(frames - done)
            if n == 0 {
                break
            }
            chunk(n, offset: done, into: out + done * 2)
            done += n
        }
        for i in 0..<frames * 2 {
            out[i] = min(max(out[i], -1), 1)
        }
        deliver(UnsafePointer(out))
    }

    /// Gain of each stem for this block: a number, or a ramp when it is changing.
    private func prepareGains(_ frames: Int) {
        for i in 0..<stems.count {
            let now = level[i], target = wanted[i]
            if now == target {
                base[i] = now * unit
                slope[i] = 0
            } else {
                base[i] = now * unit
                slope[i] = (target - now) * unit / Float(frames)
                level[i] = target
            }
        }
    }

    /// Handle what happens at the current position; return how far the audio is uniform.
    private func advanceLimit(_ n: Int) -> Int {
        if _state != .playing && gate == 0 {
            if let park {
                pos = park
                self.park = nil
            }
            return 0
        }
        if _loopOn, let loop = _loop, pos == seam {
            move(loop.start - Mixer.fade)  // blends over `fade` samples: lands exactly on the start
        }
        if pos >= length {
            _state = .stopped
            gate = 0
            fadeLeft = 0
            pos = home
            park = nil
            return 0
        }
        var limit = min(n, length - pos)
        if _loopOn && pos < seam {
            limit = min(limit, seam - pos)
        }
        if fadeLeft > 0 {
            limit = min(limit, fadeLeft)
        }
        if _state != .playing {
            limit = min(limit, gate)
        } else if gate < Mixer.fade {
            limit = min(limit, Mixer.fade - gate)
        }
        return limit
    }

    private func chunk(_ n: Int, offset: Int, into out: UnsafeMutablePointer<Float>) {
        let fade = Float(Mixer.fade)
        mix(at: pos, n, offset: offset, into: out)
        if fadeLeft > 0 {
            mix(at: fadeFrom, n, offset: offset, into: other)
            let first = Float(Mixer.fade - fadeLeft + 1)
            for j in 0..<n {
                let w = (Float(j) + first) / fade
                out[2 * j] = out[2 * j] * w + other[2 * j] * (1 - w)
                out[2 * j + 1] = out[2 * j + 1] * w + other[2 * j + 1] * (1 - w)
            }
            fadeFrom += n
            fadeLeft -= n
        }
        if _state != .playing {
            for j in 0..<n {
                let w = Float(gate - 1 - j) / fade
                out[2 * j] *= w
                out[2 * j + 1] *= w
            }
            gate -= n
        } else if gate < Mixer.fade {
            for j in 0..<n {
                let w = Float(gate + 1 + j) / fade
                out[2 * j] *= w
                out[2 * j + 1] *= w
            }
            gate += n
        }
        pos += n
    }

    /// The sum of the stems from `at`, for `n` frames; silence before the start and after the end.
    private func mix(at start: Int, _ n: Int, offset: Int, into out: UnsafeMutablePointer<Float>) {
        out.update(repeating: 0, count: n * 2)
        let lo = max(start, 0), hi = min(start + n, length)
        guard lo < hi else {
            return
        }
        for (s, stem) in stems.enumerated() {
            let b = base[s], k = slope[s]
            if k == 0 && b == 0 {
                continue
            }
            stem.withUnsafeBufferPointer { data in
                for frame in lo..<hi {
                    let j = frame - start
                    let gain = k == 0 ? b : b + k * Float(offset + j + 1)
                    out[2 * j] += Float(data[2 * frame]) * gain
                    out[2 * j + 1] += Float(data[2 * frame + 1]) * gain
                }
            }
        }
    }
}

/// The whole song with the given level for each part, interleaved float, not clipped.
public func mixdown(_ stems: [[Int16]], gain: Float, levels: [Float]) -> [Float] {
    var out = [Float](repeating: 0, count: stems.first?.count ?? 0)
    for (stem, level) in zip(stems, levels) where level != 0 {
        let factor = level * gain / 32768
        stem.withUnsafeBufferPointer { data in
            for i in 0..<data.count {
                out[i] += Float(data[i]) * factor
            }
        }
    }
    return out
}

/// Lower the whole signal if it would clip.
public func limit(_ signal: inout [Float]) {
    let peak = signal.reduce(Float(0)) { max($0, abs($1)) }
    if peak > 0.999 {
        let factor = 0.999 / peak
        for i in 0..<signal.count {
            signal[i] *= factor
        }
    }
}
