import AVFoundation
import AudioToolbox
import ZittoCore

/// The parts of a separated song, as the worker stored them.
struct StemSet {
    let names: [String]
    let data: [[Int16]]  // interleaved stereo
    let gain: Float

    var length: Int {
        (data.first?.count ?? 0) / 2
    }
}

enum AudioFiles {
    /// Reads `<name>.flac` of every part, in parallel.
    static func loadStems(_ library: Library, key: String) throws -> StemSet {
        let info = try library.stemInfo(key)
        var loaded = [Result<[Int16], Error>](repeating: .success([]), count: info.names.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: info.names.count) { i in
            let url = info.folder.appendingPathComponent("\(info.names[i]).flac")
            let result = Result { try readInt16(url) }
            lock.lock()
            loaded[i] = result
            lock.unlock()
        }
        let data = try loaded.map { try $0.get() }
        guard Set(data.map(\.count)).count == 1 else {
            throw LibraryError("The parts of this song do not match. Delete it and add it again.")
        }
        return StemSet(names: info.names, data: data, gain: info.gain)
    }

    /// A whole file as interleaved stereo int16 at 44.1 kHz.
    static func readInt16(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let format = file.processingFormat
        guard Int(format.sampleRate) == sampleRate else {
            throw LibraryError("Unexpected sample rate in \(url.lastPathComponent)")
        }
        let frames = Int(file.length)
        let channels = Int(format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))) else {
            throw LibraryError("Not enough memory for \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        let read = Int(buffer.frameLength)
        guard let samples = buffer.int16ChannelData?[0] else {
            throw LibraryError("Cannot read \(url.lastPathComponent)")
        }
        var out = [Int16](repeating: 0, count: read * 2)
        for i in 0..<read {
            let l = samples[i * channels]
            out[2 * i] = l
            out[2 * i + 1] = channels > 1 ? samples[i * channels + 1] : l
        }
        return out
    }

    /// Artist and title from the tags of a file, or its name: as file_credits in source.py.
    static func credits(_ url: URL) -> (artist: String, title: String) {
        let fallback = ("", url.deletingPathExtension().lastPathComponent)
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else {
            return fallback
        }
        defer { AudioFileClose(file) }
        var info: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &info) == noErr,
              let dictionary = info?.takeRetainedValue() as? [String: Any] else {
            return fallback
        }
        let artist = (dictionary[kAFInfoDictionary_Artist] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let title = (dictionary[kAFInfoDictionary_Title] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return !artist.isEmpty && !title.isEmpty ? (artist, title) : fallback
    }

    /// Write a mix, interleaved float, to .wav, .flac or .mp3. The file appears under its name
    /// only when complete. ffmpeg, when there is one, copies the tags of `tagsFrom`.
    static func encode(_ audio: [Float], to out: URL, tagsFrom: URL?, title: String) throws {
        let format = out.pathExtension.lowercased()
        guard ["mp3", "flac", "wav"].contains(format) else {
            throw LibraryError("Unsupported output format '.\(format)'. Use: mp3, flac, wav")
        }
        let folder = out.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent("\(out.deletingPathExtension().lastPathComponent).part.\(format)")
        defer { try? FileManager.default.removeItem(at: partial) }

        if let ffmpeg = Paths.ffmpeg {
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("zitto_\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            try writeWAV(audio, to: wav, float: true)
            var arguments = ["-nostdin", "-v", "error", "-y", "-i", wav.path]
            if let tagsFrom {
                arguments += ["-i", tagsFrom.path, "-map", "0:a", "-map_metadata", "1"]
            }
            if !title.isEmpty {
                arguments += ["-metadata", "title=\(title)"]
            }
            let encoders = ["mp3": ["-c:a", "libmp3lame", "-b:a", "320k", "-id3v2_version", "3"],
                            "flac": ["-c:a", "flac"], "wav": ["-c:a", "pcm_s24le"]]
            try run(ffmpeg, arguments + encoders[format]! + [partial.path])
        } else if format == "wav" {
            try writeWAV(audio, to: partial, float: false)
        } else {
            throw LibraryError("Saving as .\(format) needs ffmpeg. Install it with: brew install ffmpeg. "
                               + "Or save as .wav.")
        }
        if FileManager.default.fileExists(atPath: out.path) {
            _ = try FileManager.default.replaceItemAt(out, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: out)
        }
    }

    /// 32-bit float for ffmpeg, 24-bit integer for the user.
    private static func writeWAV(_ audio: [Float], to url: URL, float: Bool) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: float ? 32 : 24, AVLinearPCMIsFloatKey: float,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let frames = audio.count / 2, piece = 1 << 18
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(piece)),
              let channels = buffer.floatChannelData else {
            throw LibraryError("Not enough memory to save")
        }
        var start = 0
        while start < frames {
            let n = min(piece, frames - start)
            for i in 0..<n {
                channels[0][i] = audio[2 * (start + i)]
                channels[1][i] = audio[2 * (start + i) + 1]
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            start += n
        }
    }

    private static func run(_ program: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LibraryError("ffmpeg failed: \(text.suffix(500))")
        }
    }
}
