import CoreMIDI
import Foundation
import ZittoCore

/// One MIDI input at a time, through CoreMIDI.
///
/// `onMessage` is called on the MIDI thread with each plain MIDI 1.0 message. `onChange` is
/// called on the main thread when devices are plugged in or out. On macOS several programs can
/// listen to the same device.
final class MIDIInput {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var source: MIDIEndpointRef = 0
    private let decoderLock = FastLock()
    private var decoder = UMPDecoder()
    private(set) var name: String?
    var onChange: (() -> Void)?

    init(onMessage: @escaping ([UInt8]) -> Void) throws {
        var status = MIDIClientCreateWithBlock("zitto" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.onChange?() }
            }
        }
        guard status == noErr else {
            throw LibraryError("MIDI is not available (\(status))")
        }
        status = MIDIInputPortCreateWithProtocol(client, "zitto in" as CFString, ._1_0, &port) { [weak self] list, _ in
            guard let self else { return }
            for packet in list.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                let words = withUnsafeBytes(of: packet.pointee.words) { raw in
                    Array(raw.bindMemory(to: UInt32.self).prefix(count))
                }
                let messages = self.decoderLock.run { self.decoder.decode(words) }
                messages.forEach(onMessage)
            }
        }
        guard status == noErr else {
            MIDIClientDispose(client)
            throw LibraryError("MIDI is not available (\(status))")
        }
    }

    deinit {
        close()
        MIDIPortDispose(port)
        MIDIClientDispose(client)
    }

    /// The names of the inputs there are now.
    func ports() -> [String] {
        (0..<MIDIGetNumberOfSources()).map { MIDIInput.displayName(MIDIGetSource($0)) }
    }

    /// Open an input. Throws when it is gone.
    func open(_ wanted: String) throws {
        close()
        let count = MIDIGetNumberOfSources()
        guard let index = (0..<count).first(where: { MIDIInput.displayName(MIDIGetSource($0)) == wanted }) else {
            throw LibraryError("MIDI port not found: \(wanted)")
        }
        let endpoint = MIDIGetSource(index)
        let status = MIDIPortConnectSource(port, endpoint, nil)
        guard status == noErr else {
            throw LibraryError("Cannot open \(wanted) (\(status)).")
        }
        decoderLock.run { decoder = UMPDecoder() }
        source = endpoint
        name = wanted
    }

    func close() {
        if source != 0 {
            MIDIPortDisconnectSource(port, source)
        }
        source = 0
        name = nil
    }

    private static func displayName(_ endpoint: MIDIEndpointRef) -> String {
        var text: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &text) == noErr, let text {
            return text.takeRetainedValue() as String
        }
        return "MIDI \(endpoint)"
    }
}
