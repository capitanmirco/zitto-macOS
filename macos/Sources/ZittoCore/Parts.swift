import Foundation

/// The parts of a song, as models.py names them, and what the player does with them.
public enum Parts {
    /// The parts of a song, in the order they are shown. A set of models may tell apart only some.
    public static let names = ["lead", "backing", "drums", "bass", "guitar", "piano", "wind", "other"]

    public static let labels: [String: String] = [
        "lead": "Lead voice", "backing": "Backing voices", "drums": "Drums", "bass": "Bass",
        "guitar": "Guitar", "piano": "Piano", "wind": "Wind", "other": "Other",
        "kick": "Kick", "snare": "Snare", "toms": "Toms", "cymbals": "Cymbals",
    ]

    /// Parts that can be stored as pieces. The last piece is what the others leave.
    public static let pieces: [String: [String]] = ["drums": ["kick", "snare", "toms", "cymbals"]]

    /// What the default models store of a song: used until the worker says otherwise.
    public static let defaultStems = ["lead", "backing", "kick", "snare", "toms", "cymbals", "bass", "guitar",
                                      "piano", "wind", "other"]

    public static let colors: [String: String] = [
        "lead": "#ff7a90", "backing": "#ff9ecb", "drums": "#ffb454", "bass": "#8bd450",
        "guitar": "#4cc9f0", "piano": "#b794f6", "wind": "#5eead4", "other": "#9fb0c3",
        "kick": "#e8923a", "snare": "#ffc272", "toms": "#f2a65a", "cymbals": "#ffdcae",
    ]

    public static func label(_ name: String) -> String {
        labels[name] ?? name.capitalized
    }

    /// The part that a stem is a piece of.
    public static func whole(_ stem: String) -> String? {
        pieces.first(where: { $0.value.contains(stem) })?.key
    }

    /// What can be switched in a song: each part, followed by its pieces if it has them.
    /// For a piece, `part` is the position of its part.
    public static func controls(_ stems: [String]) -> [(name: String, part: Int?)] {
        var found: [(name: String, part: Int?)] = []
        for stem in stems {
            if let part = whole(stem) {
                if !found.contains(where: { $0.name == part && $0.part == nil }) {
                    found.append((part, nil))
                }
                let index = found.firstIndex(where: { $0.name == part && $0.part == nil })
                found.append((stem, index))
            } else {
                found.append((stem, nil))
            }
        }
        return found
    }

    /// Which controls sound: the soloed ones if any, else all; never the muted ones.
    ///
    /// `parts`: for a piece, the position of its part. Muting a part mutes its pieces, soloing it
    /// solos them unless some are soloed themselves; a part sounds when one of its pieces does.
    public static func heard(on: [Bool], solo: [Bool], parts: [Int?]) -> [Bool] {
        let anySolo = solo.contains(true)

        func chosen(_ i: Int) -> Bool {
            guard let part = parts[i], !solo[i] else {
                return solo[i]
            }
            let pieceSoloed = zip(solo, parts).contains { $0.0 && $0.1 == part }
            return solo[part] && !pieceSoloed
        }

        var result = (0..<on.count).map { i -> Bool in
            let partOn = parts[i].map { on[$0] } ?? true
            return on[i] && partOn && (!anySolo || chosen(i))
        }
        for part in Set(parts.compactMap { $0 }) {
            result[part] = zip(result, parts).contains { $0.0 && $0.1 == part }
        }
        return result
    }

    /// What to add to the title of a saved mix: " (no voice)", " (only drums, bass)", or nothing.
    /// `audible`: each stem of the song, in order, and whether it is heard.
    public static func mixName(_ audible: [(name: String, heard: Bool)]) -> String {
        func merged(_ names: [String]) -> [String] {
            var names = names
            for (part, pieces) in Parts.pieces where Set(pieces).isSubset(of: Set(names)) {
                names = names.filter { !pieces.dropFirst().contains($0) }.map { $0 == pieces[0] ? part : $0 }
            }
            return names
        }

        func words(_ names: [String]) -> String {
            var names = names
            if names.contains("lead") && names.contains("backing") {
                names = ["voice"] + names.filter { $0 != "lead" && $0 != "backing" }
            }
            let shown = ["lead": "lead voice", "backing": "backing voices"]
            return names.map { shown[$0] ?? $0 }.joined(separator: ", ")
        }

        let on = merged(audible.filter { $0.heard }.map { $0.name })
        let off = merged(audible.filter { !$0.heard }.map { $0.name })
        if off.isEmpty {
            return ""
        }
        return on.count < off.count ? " (only \(words(on)))" : " (no \(words(off)))"
    }
}
