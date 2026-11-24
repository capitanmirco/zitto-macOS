import AVFoundation
import ZittoCore

/// Plays whatever mixer it is given on the current output device.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private let box = MixerBox()
    private var observer: NSObjectProtocol?

    /// How long, in samples, between leaving the mixer and being heard.
    private(set) var latency = 0

    var mixer: Mixer? {
        get { box.get() }
        set { box.set(newValue) }
    }

    init() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2)!
        let box = self.box
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            if let mixer = box.get() {
                mixer.render(frames: frames, left: left, right: right)
            } else {
                left.update(repeating: 0, count: frames)
                right.update(repeating: 0, count: frames)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        measure()
        // Headphones plugged in, another device chosen: the engine stops and has to start again.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            try? self.engine.start()
            self.measure()
        }
    }

    private func measure() {
        let device = engine.outputNode.presentationLatency
        let buffer = 512.0 / Double(sampleRate)  // about one buffer of the device
        latency = Int((device + buffer) * Double(sampleRate))
    }

    func close() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        box.set(nil)
        engine.stop()
    }
}

/// The mixer being played, shared with the audio thread.
private final class MixerBox {
    private let lock = FastLock()
    private var mixer: Mixer?

    func get() -> Mixer? {
        lock.run { mixer }
    }

    func set(_ value: Mixer?) {
        lock.run { mixer = value }
    }
}
