import Foundation

/// Order keys that can always be squeezed between two neighbours.
///
/// A key is a base-36 fraction written without the leading "0." — "i" is 0.5,
/// "9" is 0.25. Keys compare correctly as plain strings because no generated
/// key ever ends in "0", so moving one app never requires re-keying the others.
/// That matters for sync: a move touches exactly one entry, so concurrent edits
/// to different apps on different Macs never collide.
public enum FractionalIndex {
    static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    static let base = 36

    private static func value(_ c: Character) -> Int {
        digits.firstIndex(of: c) ?? 0
    }

    private static func string(_ values: [Int]) -> String {
        String(values.map { digits[$0] })
    }

    /// A key strictly between `lo` and `hi`; nil means the open end.
    /// If the bounds are out of order (which a well-formed map never produces)
    /// this degrades to a key after `lo` rather than looping.
    public static func between(_ lo: String?, _ hi: String?) -> String {
        if let lo, let hi, lo >= hi { return between(lo, nil) }

        let a = (lo ?? "").map(value)
        let b = hi.map { $0.map(value) }
        var bounded = b != nil
        var out: [Int] = []

        for i in 0..<64 {
            let da = i < a.count ? a[i] : 0
            let db = bounded ? (i < b!.count ? b![i] : 0) : base
            if db - da > 1 {
                out.append((da + db) / 2)
                return string(out)
            }
            out.append(da)
            // Any continuation of a prefix that is already below `hi` stays below it.
            if db - da == 1 { bounded = false }
        }
        return string(out) + "i"
    }

    /// `count` ascending keys spread evenly, for seeding a whole Dock at once.
    public static func evenlySpaced(_ count: Int) -> [String] {
        guard count > 0 else { return [] }
        let width = 3
        let space = Int(pow(Double(base), Double(width)))
        guard count < space / 2 else {
            // Absurdly long Dock: fall back to chaining.
            var keys: [String] = []
            for _ in 0..<count { keys.append(between(keys.last, nil)) }
            return keys
        }
        return (1...count).map { i in
            var n = i * space / (count + 1)
            if n % base == 0 { n += 1 }   // never end in "0"
            var values = [Int](repeating: 0, count: width)
            for p in (0..<width).reversed() {
                values[p] = n % base
                n /= base
            }
            return string(values)
        }
    }
}
