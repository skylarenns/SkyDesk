import XCTest
@testable import SkyDeskCore

final class WindowPlacementTests: XCTestCase {
    // Live geometry: built-in 2056x1329 desktop, iPad desktop 1376x1032 to its right.
    let mac = CGRect(x: 0, y: 0, width: 2056, height: 1329)
    let pad = CGRect(x: 2056, y: 25, width: 1376, height: 1007)

    func testEveryMacWindowLandsWhollyOnTheIPadDesktop() {
        let windows = [CGRect(x: 0, y: 39, width: 2056, height: 1209), CGRect(x: 718, y: 214, width: 620, height: 859),
                       CGRect(x: 1167, y: 39, width: 875, height: 978), CGRect(x: 1900, y: 1200, width: 400, height: 300),
                       CGRect(x: -300, y: 500, width: 700, height: 500)]
        for window in windows {
            let fitted = WindowPlacement.fit(window, from: mac, into: pad)
            XCTAssertTrue(WindowPlacement.isContained(fitted, in: pad, tolerance: 0), "\(window) -> \(fitted)")
            XCTAssertEqual(fitted.width, min(window.width, pad.width)); XCTAssertEqual(fitted.height, min(window.height, pad.height))
        }
    }
    func testRelativePositionIsPreserved() {
        let left = WindowPlacement.fit(CGRect(x: 0, y: 39, width: 600, height: 400), from: mac, into: pad)
        let right = WindowPlacement.fit(CGRect(x: 1456, y: 929, width: 600, height: 400), from: mac, into: pad)
        XCTAssertEqual(left.minX, pad.minX); XCTAssertEqual(right.maxX, pad.maxX); XCTAssertEqual(right.maxY, pad.maxY)
        let centred = WindowPlacement.fit(CGRect(x: 728, y: 464.5, width: 600, height: 400), from: mac, into: pad)
        XCTAssertEqual(centred.midX, pad.midX, accuracy: 1)
    }
    func testDesktopSelectionAndReachability() {
        XCTAssertEqual(WindowPlacement.desktop(for: CGRect(x: 1800, y: 100, width: 400, height: 300), among: [mac, pad]), mac)
        XCTAssertEqual(WindowPlacement.desktop(for: CGRect(x: 2100, y: 100, width: 400, height: 300), among: [mac, pad]), pad)
        XCTAssertNil(WindowPlacement.desktop(for: CGRect(x: 9000, y: 9000, width: 400, height: 300), among: [mac, pad]))
        let only = CGRect(x: 0, y: 25, width: 1376, height: 1007)
        XCTAssertTrue(WindowPlacement.isReachable(CGRect(x: 1000, y: 600, width: 900, height: 700), in: only))
        XCTAssertFalse(WindowPlacement.isReachable(CGRect(x: 2100, y: 100, width: 400, height: 300), in: only))
        XCTAssertFalse(WindowPlacement.isReachable(CGRect(x: 100, y: -400, width: 400, height: 300), in: only))
        XCTAssertFalse(WindowPlacement.isReachable(CGRect(x: 100, y: 1025, width: 400, height: 300), in: only))
    }
    func testRestoreReturnsUntouchedWindowsAndRespectsUserMoves() {
        let original = CGRect(x: 718, y: 214, width: 620, height: 859)
        let placed = CGRect(x: 480, y: 55, width: 620, height: 859)
        // Untouched on the iPad, even if the display change shifted its coordinates afterwards.
        XCTAssertEqual(WindowPlacement.restored(original: original, placed: placed, lastSeen: placed,
                                                current: placed.offsetBy(dx: 2056, dy: 0), mac: mac), original)
        // Moved by the user and still reachable on the Mac desktop: left exactly there.
        let moved = CGRect(x: 100, y: 80, width: 700, height: 500)
        XCTAssertEqual(WindowPlacement.restored(original: original, placed: placed, lastSeen: moved, current: moved, mac: mac), moved)
        // Moved by the user but stranded after the switch: same size, back on the Mac desktop.
        let stranded = moved.offsetBy(dx: 2600, dy: 0)
        let rescued = WindowPlacement.restored(original: original, placed: placed, lastSeen: moved, current: stranded, mac: mac)
        XCTAssertEqual(rescued.size, moved.size); XCTAssertTrue(WindowPlacement.isContained(rescued, in: mac))
    }
}
