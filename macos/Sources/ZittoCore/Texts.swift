import Foundation

/// Names, searches and file names: the same rules as source.py, so that both versions agree.
public enum Texts {
    /// For comparing and searching: no capitals, no accents, single spaces.
    public static func plain(_ text: String) -> String {
        let decomposed = text.lowercased().decomposedStringWithCompatibilityMapping
        var kept = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars where scalar.properties.canonicalCombiningClass.rawValue == 0 {
            kept.append(scalar)
        }
        return String(kept).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Whether every word of a search (see `plain`) is somewhere in the texts.
    public static func matches(_ words: [String], _ texts: String...) -> Bool {
        let text = plain(texts.joined(separator: " "))
        return words.allSatisfy { text.contains($0) }
    }

    /// The words of a search.
    public static func words(_ query: String) -> [String] {
        plain(query).split(separator: " ").map(String.init)
    }

    /// "Artist - Title", unless the title already says who it is.
    public static func fullName(artist: String, title: String) -> String {
        if !artist.isEmpty && !plain(title).contains(plain(artist)) {
            return "\(artist) - \(title)"
        }
        return title
    }

    public static func isURL(_ source: String) -> Bool {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("http://") || text.hasPrefix("https://")
    }

    /// Make a title usable as a file name, on macOS and on Windows alike.
    public static func safeFilename(_ name: String, limit: Int = 150) -> String {
        let forbidden = Set("<>:\"/\\|?*")
        var cleaned = String(name.map { c -> Character in
            if forbidden.contains(c) { return "_" }
            if let ascii = c.asciiValue, ascii < 0x20 { return "_" }
            return c
        })
        cleaned = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        cleaned = trim(cleaned, " .")
        cleaned = trimEnd(String(cleaned.prefix(limit)), " .")
        let reserved = ["con", "prn", "aux", "nul"] + (0...9).flatMap { ["com\($0)", "lpt\($0)"] }
        if reserved.contains(cleaned.lowercased()) {
            cleaned = "_" + cleaned
        }
        return cleaned.isEmpty ? "track" : cleaned
    }

    private static func trim(_ text: String, _ characters: String) -> String {
        let set = Set(characters)
        var slice = Substring(text)
        while let first = slice.first, set.contains(first) { slice = slice.dropFirst() }
        return trimEnd(String(slice), characters)
    }

    private static func trimEnd(_ text: String, _ characters: String) -> String {
        let set = Set(characters)
        var slice = Substring(text)
        while let last = slice.last, set.contains(last) { slice = slice.dropLast() }
        return String(slice)
    }

    /// The first 16 hex digits of the SHA-1 of a text: identifies songs and playlists.
    public static func digest(_ text: String) -> String {
        String(SHA1.hex(Array(text.utf8)).prefix(16))
    }
}

/// SHA-1, only to name things as the Python version does (hashlib.sha1). Not for security.
enum SHA1 {
    static func hex(_ message: [UInt8]) -> String {
        digest(message).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var data = message
        let bits = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
            }
            for i in 16..<80 {
                w[i] = rotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let temp = rotate(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotate(b, 30); b = a; a = temp
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return h.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(24 - $0 * 8)) } }
    }

    private static func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }
}
