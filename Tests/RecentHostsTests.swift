import XCTest
@testable import SkyDeskCore

final class RecentHostsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func testKeepsFiveMostRecentNewestFirstAndReportsRemoved() {
        var list = RecentHostList()
        var removed: [RecentHost] = []
        for index in 1...7 {
            removed += list.record(address: "10.0.0.\(index)", name: "Mac \(index)", serviceName: nil,
                                   at: t0.addingTimeInterval(Double(index))).removed
        }
        XCTAssertEqual(list.entries.map(\.address), ["10.0.0.7", "10.0.0.6", "10.0.0.5", "10.0.0.4", "10.0.0.3"])
        XCTAssertEqual(removed.map(\.address), ["10.0.0.1", "10.0.0.2"])
    }
    func testReconnectingMovesEntryToFrontAndKeepsItsIdentity() {
        var list = RecentHostList()
        let first = list.record(address: "10.0.0.1", name: "Studio", serviceName: "Studio", at: t0).entry
        list.record(address: "10.0.0.2", name: "Laptop", serviceName: nil, at: t0.addingTimeInterval(1))
        let again = list.record(address: " 10.0.0.1 ", name: "", serviceName: nil, at: t0.addingTimeInterval(2))
        XCTAssertEqual(again.removed, [])
        XCTAssertEqual(again.entry.id, first.id, "Same Keychain account, so the saved password still applies")
        XCTAssertEqual(again.entry.name, "Studio")
        XCTAssertEqual(again.entry.serviceName, "Studio")
        XCTAssertEqual(list.entries.map(\.address), ["10.0.0.1", "10.0.0.2"])
        XCTAssertEqual(list.entry(serviceName: "Studio")?.id, first.id)
    }
    func testAddressMatchIgnoresCase() {
        var list = RecentHostList()
        list.record(address: "My-Mac.local", name: "", serviceName: nil, at: t0)
        list.record(address: "my-mac.LOCAL", name: "", serviceName: nil, at: t0.addingTimeInterval(1))
        XCTAssertEqual(list.entries.count, 1)
        XCTAssertEqual(list.entries[0].name, "My-Mac.local")
    }
    func testPersistsThroughUserDefaults() throws {
        let suite = "skydesk.test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var list = RecentHostList()
        list.record(address: "10.0.0.9", name: "Studio", serviceName: "Studio", at: t0)
        list.save(to: defaults)
        XCTAssertEqual(RecentHostList.load(from: defaults), list)
        XCTAssertEqual(RecentHostList.load(from: UserDefaults(suiteName: suite + ".empty")!).entries, [])
    }
    func testForgetRemovesOnlyThatEntry() {
        var list = RecentHostList()
        let a = list.record(address: "10.0.0.1", name: "A", serviceName: nil, at: t0).entry
        list.record(address: "10.0.0.2", name: "B", serviceName: nil, at: t0.addingTimeInterval(1))
        XCTAssertEqual(list.remove(id: a.id)?.address, "10.0.0.1")
        XCTAssertEqual(list.entries.map(\.address), ["10.0.0.2"])
        XCTAssertNil(list.remove(id: a.id))
    }
    func testLaunchTargetIsNewestEntryWithACredential() {
        var list = RecentHostList()
        let old = list.record(address: "10.0.0.1", name: "A", serviceName: nil, at: t0).entry
        list.record(address: "10.0.0.2", name: "B", serviceName: nil, at: t0.addingTimeInterval(1))
        XCTAssertEqual(AutoConnect.launchTarget(list, hasCredential: { $0.id == old.id })?.address, "10.0.0.1")
        XCTAssertEqual(AutoConnect.launchTarget(list, hasCredential: { _ in true })?.address, "10.0.0.2")
        XCTAssertNil(AutoConnect.launchTarget(RecentHostList(), hasCredential: { _ in true }), "First launch goes straight to the connection screen")
        XCTAssertEqual(AutoConnect.deadlineSeconds, 5)
        XCTAssertEqual(AutoConnect.deadline(justUpdated: false), 5)
        XCTAssertEqual(AutoConnect.deadline(justUpdated: true), 25)
    }
}

final class SessionLifecycleTests: XCTestCase {
    func testBackground() {
        XCTAssertEqual(SessionLifecycle.onBackground(connected: true, connecting: false, hostCanPause: true), .pauseAndHold)
        XCTAssertEqual(SessionLifecycle.onBackground(connected: true, connecting: false, hostCanPause: false), .disconnectAndResumeLater)
        XCTAssertEqual(SessionLifecycle.onBackground(connected: false, connecting: true, hostCanPause: false), .disconnectAndResumeLater)
        XCTAssertEqual(SessionLifecycle.onBackground(connected: false, connecting: false, hostCanPause: true), .nothing)
    }
    func testForeground() {
        XCTAssertEqual(SessionLifecycle.onForeground(connected: true, lastReplyAge: 0.1, resumeWanted: true), .resumeVideo)
        // Held too long (suspended, link silently dead): don't wait for the 5 s timeout, reconnect now.
        XCTAssertEqual(SessionLifecycle.onForeground(connected: true, lastReplyAge: 9, resumeWanted: true), .reconnect)
        XCTAssertEqual(SessionLifecycle.onForeground(connected: true, lastReplyAge: nil, resumeWanted: false), .reconnect)
        XCTAssertEqual(SessionLifecycle.onForeground(connected: false, lastReplyAge: nil, resumeWanted: true), .reconnect)
        // Reopened hours later with nothing connected (user report 2026-11-13): connect, like a fresh launch.
        XCTAssertEqual(SessionLifecycle.onForeground(connected: false, lastReplyAge: nil, resumeWanted: false), .connectToMostRecent)
        XCTAssertEqual(SessionLifecycle.onForeground(connected: false, lastReplyAge: nil, resumeWanted: false, connecting: true), .nothing)
    }
}

final class AddressRaceTests: XCTestCase {
    func testNewestAddressWinsAtOnce() {
        var race = AddressRace(count: 3)
        XCTAssertEqual(race.answered(0), .choose(0))
    }
    func testAnOlderAnswerWaitsBrieflyForANewerOne() {
        var race = AddressRace(count: 3)
        XCTAssertEqual(race.answered(2), .waitBriefly)
        XCTAssertEqual(race.best, 2)
        XCTAssertEqual(race.answered(1), .waitBriefly)
        XCTAssertEqual(race.best, 1)
        // Once the newest has failed, nothing better can come.
        XCTAssertEqual(race.failed(0), .choose(1))
    }
    func testAwayFromHomeTheVPNAddressIsChosenWhenHomeFails() {
        var race = AddressRace(count: 2)       // 0 = home Wi-Fi (newest), 1 = VPN
        XCTAssertEqual(race.failed(0), .wait)
        XCTAssertEqual(race.answered(1), .choose(1))
    }
    func testNothingAnswering() {
        var race = AddressRace(count: 2)
        XCTAssertEqual(race.failed(1), .wait)
        XCTAssertEqual(race.failed(0), .choose(nil))
        XCTAssertNil(race.best)
    }
}
