import Foundation

/// MIDI control of the transport: message decoding and bindings, as midi.py does.
public enum MIDI {
    public static let actions = ["play", "pause", "stop", "rewind"]

    /// Standard transport messages, understood without any setup.
    public static let standard: [Trigger: [String]] = [
        Trigger("mmc", 0x01): ["stop"],
        Trigger("mmc", 0x02): ["play"],
        Trigger("mmc", 0x03): ["play"],  // deferred play
        Trigger("mmc", 0x05): ["rewind"],
        Trigger("mmc", 0x09): ["pause"],
        Trigger("realtime", 0xFA): ["rewind", "play"],  // start: from the beginning
        Trigger("realtime", 0xFB): ["play"],  // continue
        Trigger("realtime", 0xFC): ["stop"],
    ]

    static let mmcNames = [1: "Stop", 2: "Play", 3: "Deferred Play", 4: "Fast Forward", 5: "Rewind", 6: "Record",
                           9: "Pause"]
    static let realtimeNames = [0xFA: "Start", 0xFB: "Continue", 0xFC: "Stop"]

    /// The button press in a raw MIDI 1.0 message, or nil (releases, clock, pitch bend...).
    public static func trigger(_ message: [UInt8]) -> Trigger? {
        guard let status = message.first else {
            return nil
        }
        if realtimeNames[Int(status)] != nil {
            return Trigger("realtime", Int(status))
        }
        if status == 0xF0 {  // F0 7F <device> 06 <command> F7
            if message.count >= 6 && message[1] == 0x7F && message[3] == 0x06 {
                return Trigger("mmc", Int(message[4]))
            }
            return nil
        }
        let kind = status & 0xF0, channel = Int(status & 0x0F)
        if kind == 0x90 && message.count >= 3 && message[2] > 0 {
            return Trigger("note", channel, Int(message[1]))
        }
        if kind == 0xB0 && message.count >= 3 && message[2] >= 64 {
            return Trigger("cc", channel, Int(message[1]))
        }
        if kind == 0xC0 && message.count >= 2 {
            return Trigger("program", channel, Int(message[1]))
        }
        return nil
    }

    public static func describe(_ t: Trigger) -> String {
        switch t.kind {
        case "mmc":
            return "MMC \(mmcNames[t.values[0]] ?? String(t.values[0]))"
        case "realtime":
            return "MIDI \(realtimeNames[t.values[0]] ?? String(t.values[0]))"
        default:
            let names = ["note": "Note", "cc": "CC", "program": "Program"]
            return "\(names[t.kind] ?? t.kind) \(t.values[1]), channel \(t.values[0] + 1)"
        }
    }

    /// A port name without its trailing number, which Windows changes when devices come and go.
    public static func base(_ name: String) -> String {
        guard let space = name.lastIndex(of: " ") else {
            return name
        }
        let tail = name[name.index(after: space)...]
        return !tail.isEmpty && tail.allSatisfy(\.isNumber) ? String(name[..<space]) : name
    }

    /// The port called `name` among `ports`, also when its trailing number has changed.
    public static func find(_ name: String, in ports: [String]) -> String? {
        if ports.contains(name) {
            return name
        }
        return ports.first { base($0) == base(name) }
    }
}

/// What identifies a button: ("note", channel, number), ("cc", channel, number),
/// ("program", channel, number), ("mmc", command) or ("realtime", status).
public struct Trigger: Hashable {
    public let kind: String
    public let values: [Int]

    public init(_ kind: String, _ values: Int...) {
        self.kind = kind
        self.values = values
    }

    init(kind: String, values: [Int]) {
        self.kind = kind
        self.values = values
    }

    /// As it is saved in settings.json: ["note", 0, 60].
    public var json: [Any] {
        [kind] + values.map { $0 as Any }
    }

    public init?(json: Any?) {
        guard let list = json as? [Any], let kind = list.first as? String else {
            return nil
        }
        let sizes = ["note": 3, "cc": 3, "program": 3, "mmc": 2, "realtime": 2]
        guard list.count == sizes[kind] else {
            return nil
        }
        var values: [Int] = []
        for item in list.dropFirst() {
            guard let number = item as? Int else {  // not "a", not 1.5
                return nil
            }
            values.append(number)
        }
        self.init(kind: kind, values: values)
    }
}

/// One learned trigger per action, on top of the standard messages.
public struct Bindings {
    private var learned: [String: Trigger] = [:]

    public init(saved: [String: Any]? = nil) {
        for (action, value) in saved ?? [:] {
            if MIDI.actions.contains(action), let t = Trigger(json: value) {
                learned[action] = t
            }
        }
    }

    public func get(_ action: String) -> Trigger? {
        learned[action]
    }

    /// Bind a trigger; a trigger drives one action only.
    public mutating func learn(_ action: String, _ t: Trigger) {
        learned = learned.filter { $0.value != t && $0.key != action }
        learned[action] = t
    }

    public mutating func clear(_ action: String) {
        learned[action] = nil
    }

    public func actions(_ t: Trigger) -> [String] {
        if let action = learned.first(where: { $0.value == t })?.key {
            return [action]
        }
        return MIDI.standard[t] ?? []
    }

    public var json: [String: Any] {
        learned.mapValues { $0.json }
    }
}

/// Turns the Universal MIDI Packets that CoreMIDI delivers (MIDI 1.0 protocol) back into the
/// plain MIDI 1.0 messages that `MIDI.trigger` reads. System exclusive messages arrive in
/// pieces and are put together again.
public struct UMPDecoder {
    private var sysex: [UInt8]? = nil

    public init() {}

    /// The messages in some 32-bit words.
    public mutating func decode(_ words: [UInt32]) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        var i = 0
        while i < words.count {
            let word = words[i]
            let type = Int(word >> 28)
            let size = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][type]
            guard i + size <= words.count else {
                break
            }
            switch type {
            case 0x1:  // system real time and common
                let status = UInt8((word >> 16) & 0xFF)
                messages.append([status, UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F)])
            case 0x2:  // MIDI 1.0 channel voice
                let status = UInt8((word >> 16) & 0xFF)
                let length = (status & 0xF0) == 0xC0 || (status & 0xF0) == 0xD0 ? 2 : 3
                messages.append(Array([status, UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F)].prefix(length)))
            case 0x3:  // 7-bit system exclusive, up to 6 bytes in each packet
                let state = (word >> 20) & 0xF
                let count = min(Int((word >> 16) & 0xF), 6)
                let second = words[i + 1]
                let bytes: [UInt8] = [UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F),
                                      UInt8((second >> 24) & 0x7F), UInt8((second >> 16) & 0x7F),
                                      UInt8((second >> 8) & 0x7F), UInt8(second & 0x7F)]
                let data = Array(bytes.prefix(count))
                switch state {
                case 0:  // complete in one packet
                    messages.append([0xF0] + data + [0xF7])
                    sysex = nil
                case 1:  // start
                    sysex = [0xF0] + data
                case 2:  // continue
                    sysex? += data
                default:  // end
                    if let started = sysex {
                        messages.append(started + data + [0xF7])
                    }
                    sysex = nil
                }
            default:
                break  // utility messages, MIDI 2.0 and data: nothing for the transport
            }
            i += size
        }
        return messages
    }
}
