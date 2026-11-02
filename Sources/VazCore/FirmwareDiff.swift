import Foundation

public enum FirmwareDiff {
    /// Byte ranges (offsets from the start of the image) where `a` and `b` differ.
    /// Ranges separated by at most `mergeGap` equal bytes are merged into one.
    /// If sizes differ, the tail of the longer image is reported as one range.
    public static func ranges(_ a: Data, _ b: Data, mergeGap: Int = 0) -> [Range<Int>] {
        let common = min(a.count, b.count)
        var result: [Range<Int>] = []
        a.withUnsafeBytes { (pa: UnsafeRawBufferPointer) in
            b.withUnsafeBytes { (pb: UnsafeRawBufferPointer) in
                var i = 0
                while i < common {
                    guard pa[i] != pb[i] else { i += 1; continue }
                    let start = i
                    while i < common, pa[i] != pb[i] { i += 1 }
                    if let last = result.last, start - last.upperBound <= mergeGap {
                        result[result.count - 1] = last.lowerBound ..< i
                    } else {
                        result.append(start ..< i)
                    }
                }
            }
        }
        if a.count != b.count {
            result.append(common ..< max(a.count, b.count))
        }
        return result
    }

    /// Total number of differing bytes across `ranges`.
    public static func byteCount(_ ranges: [Range<Int>]) -> Int {
        ranges.reduce(0) { $0 + $1.count }
    }
}
