import XCTest
@testable import DockMirrorCore

final class FractionalIndexTests: XCTestCase {
    func testBetweenIsStrictlyBetween() {
        let cases: [(String?, String?)] = [
            (nil, nil), (nil, "i"), ("i", nil), ("a", "b"), ("a", "a1"), ("a", "a01"),
            ("z", nil), ("zz", nil), (nil, "01"), (nil, "001"), ("9", "a"), ("a5", "a6"),
        ]
        for (lo, hi) in cases {
            let key = FractionalIndex.between(lo, hi)
            if let lo { XCTAssertGreaterThan(key, lo, "\(lo)..\(hi ?? "nil")") }
            if let hi { XCTAssertLessThan(key, hi, "\(lo ?? "nil")..\(hi)") }
            XCTAssertFalse(key.hasSuffix("0"), key)
        }
    }

    func testRepeatedInsertionStaysOrdered() {
        // Always inserting at the same spot is the worst case for key growth.
        var lo = "a", hi = "b"
        for _ in 0..<200 {
            let key = FractionalIndex.between(lo, hi)
            XCTAssertTrue(lo < key && key < hi)
            hi = key
        }
        lo = "y"
        for _ in 0..<200 {
            let key = FractionalIndex.between(lo, nil)
            XCTAssertGreaterThan(key, lo)
            lo = key
        }
    }

    func testEvenlySpacedAscends() {
        for count in [0, 1, 2, 7, 40, 300] {
            let keys = FractionalIndex.evenlySpaced(count)
            XCTAssertEqual(keys.count, count)
            XCTAssertEqual(keys, keys.sorted())
            XCTAssertEqual(Set(keys).count, count)
            XCTAssertTrue(keys.allSatisfy { !$0.hasSuffix("0") })
        }
    }

    func testOutOfOrderBoundsDoNotLoop() {
        XCTAssertGreaterThan(FractionalIndex.between("m", "c"), "m")
        XCTAssertGreaterThan(FractionalIndex.between("m", "m"), "m")
    }
}
