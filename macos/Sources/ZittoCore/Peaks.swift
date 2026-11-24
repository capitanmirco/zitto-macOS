import Foundation

public let sampleRate = 44100

/// What the waveform draws: the loudest sample of every `hop` samples, and of every pixel column.
public enum Peaks {
    /// Samples per stored peak: the closest zoom.
    public static let hop = 64

    /// Loudest sample of every `hop` frames of the sum of some stems (interleaved stereo int16).
    /// A part made of pieces is drawn from the sum of its pieces.
    public static func peaks(_ stems: [[Int16]]) -> [Int32] {
        guard let first = stems.first else {
            return []
        }
        let frames = first.count / 2
        let blocks = (frames + hop - 1) / hop
        var result = [Int32](repeating: 0, count: blocks)
        if stems.count == 1 {
            first.withUnsafeBufferPointer { data in
                for block in 0..<blocks {
                    var loudest: Int32 = 0
                    for i in block * hop * 2..<min((block + 1) * hop, frames) * 2 {
                        let v = abs(Int32(data[i]))
                        if v > loudest { loudest = v }
                    }
                    result[block] = loudest
                }
            }
            return result
        }
        var sum = [Int32](repeating: 0, count: hop * 2)
        for block in 0..<blocks {
            let start = block * hop * 2, end = min((block + 1) * hop, frames) * 2
            for i in 0..<(end - start) { sum[i] = 0 }
            for stem in stems {
                stem.withUnsafeBufferPointer { data in
                    for i in start..<end { sum[i - start] += Int32(data[i]) }
                }
            }
            var loudest: Int32 = 0
            for i in 0..<(end - start) {
                let v = abs(sum[i])
                if v > loudest { loudest = v }
            }
            result[block] = loudest
        }
        return result
    }

    /// Loudest peak under each pixel column of a view that starts at sample `first`.
    public static func columns(_ values: [Int32], first: Double, perPixel: Double, width: Int) -> [Int32] {
        var out = [Int32](repeating: 0, count: max(width, 0))
        guard width > 0, !values.isEmpty else {
            return out
        }
        let edges = (0...width).map { Int64(((first + Double($0) * perPixel) / Double(hop)).rounded(.towardZero)) }
        let inside = (0..<width).filter { edges[$0] >= 0 && edges[$0] < Int64(values.count) }
        guard !inside.isEmpty else {
            return out
        }
        let end = min(Int(edges[width]) + 1, values.count)
        values.withUnsafeBufferPointer { v in
            for (n, column) in inside.enumerated() {
                let lo = Int(edges[column])
                let hi = n + 1 < inside.count ? Int(edges[inside[n + 1]]) : end
                var loudest = v[lo]
                if hi > lo {
                    for i in lo..<hi where v[i] > loudest { loudest = v[i] }
                }
                out[column] = loudest
            }
        }
        return out
    }

    /// "m:ss.d" for a position in samples.
    public static func clock(_ samples: Int, decimals: Int = 1) -> String {
        let scale = Int(pow(10.0, Double(decimals)))
        let units = Int((Double(samples) / Double(sampleRate) * Double(scale)).rounded(.toNearestOrEven))
        let seconds = units / scale, fraction = units % scale
        let text = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
        return decimals > 0 ? text + "." + String(format: "%0\(decimals)d", fraction) : text
    }
}
