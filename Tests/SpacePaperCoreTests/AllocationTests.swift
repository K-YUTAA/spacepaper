import XCTest
@testable import SpacePaperCore

final class AllocationTests: XCTestCase {
    let assets = ["a", "b", "c", "d", "e", "f"]

    func testNewSpacesDoNotInheritAnOccupiedImage() {
        let p = Allocator.plan(slots: ["monitor1/old", "monitor1/new", "monitor2/new"],
            previous: ["monitor1/old": "a"],
            observed: ["monitor1/old": "a", "monitor1/new": "a", "monitor2/new": "a"], assets: assets)
        XCTAssertTrue(p.isComplete)
        XCTAssertEqual(p.assignments["monitor1/old"], "a")
        XCTAssertEqual(Set(p.assignments.values).count, 3)
    }

    func testHiddenSpacesKeepTheirReservations() {
        let p = Allocator.plan(slots: ["hidden", "visible", "new"],
            previous: ["hidden": "a", "visible": "b"], observed: ["new": "a"], assets: assets)
        XCTAssertEqual(p.assignments["hidden"], "a")
        XCTAssertEqual(p.assignments["new"], "c")
    }

    func testReconnectRepairsAnOfflineReservationConflict() {
        let disconnected = Allocator.plan(slots: ["laptop", "new"],
            previous: ["laptop": "a", "external": "b"], observed: [:], assets: assets)
        XCTAssertEqual(disconnected.assignments["new"], "b")
        let reconnected = Allocator.plan(slots: ["laptop", "new", "external"],
            previous: disconnected.assignments.merging(["external": "b"]) { a, _ in a },
            observed: [:], assets: assets)
        XCTAssertTrue(reconnected.isComplete)
        XCTAssertEqual(Set(reconnected.assignments.values).count, 3)
    }

    func testChangingMainMonitorOrEnumerationOrderDoesNotReassign() {
        let initial = Allocator.plan(slots: ["one", "two", "three"], previous: [:], observed: [:], assets: assets)
        let next = Allocator.plan(slots: ["three", "one", "two"], previous: initial.assignments,
                                  observed: ["two": "a"], assets: assets.reversed())
        XCTAssertEqual(initial, next)
    }

    func testImageShortageNeverSilentlyReusesImages() {
        let p = Allocator.plan(slots: ["1", "2", "3"], previous: [:], observed: [:], assets: ["a", "a", "b"])
        XCTAssertFalse(p.isComplete)
        XCTAssertEqual(p.unassigned.count, 1)
        XCTAssertEqual(Set(p.assignments.values).count, p.assignments.count)
    }

    func testDeletedImageAndConflictingPersistedStateAreRepaired() {
        let p = Allocator.plan(slots: ["1", "2", "3"],
            previous: ["1": "deleted", "2": "a", "3": "a"], observed: [:], assets: assets)
        XCTAssertEqual(p.assignments.count, 3)
        XCTAssertEqual(Set(p.assignments.values).count, 3)
    }

    func testManyTopologyChangesConvergeAndAreIdempotent() {
        var saved: [String: String] = [:]
        for step in 0..<300 {
            let slots = (0..<(step % 6 + 1)).map { "monitor\(($0 + step / 9) % 3)/space\($0)" }
            let p = Allocator.plan(slots: slots, previous: saved,
                observed: Dictionary(uniqueKeysWithValues: slots.map { ($0, "a") }), assets: assets)
            XCTAssertTrue(p.isComplete)
            XCTAssertEqual(p.assignments.count, slots.count)
            XCTAssertEqual(Set(p.assignments.values).count, slots.count)
            XCTAssertEqual(p, Allocator.plan(slots: slots.reversed(), previous: p.assignments,
                                            observed: [:], assets: assets))
            saved.merge(p.assignments) { _, b in b }
        }
    }

    func testSnapshotIncludesHiddenDesktopsAndExcludesFullscreenFromAllocation() throws {
        let raw: [[String: Any]] = [["Display Identifier": "display", "Current Space": entry(2, "full", 4),
            "Spaces": [entry(1, "ordinary", 0), entry(2, "full", 4), entry(3, "hidden", 0)]]]
        let groups = try SpaceParser.parse(raw)
        XCTAssertFalse(try XCTUnwrap(groups.first?.current).isDesktop)
        XCTAssertEqual(groups[0].spaces.filter(\.isDesktop).count, 2)
    }

    func testIncompleteSnapshotFailsClosed() {
        XCTAssertThrowsError(try SpaceParser.parse([]))
        XCTAssertThrowsError(try SpaceParser.parse([["Display Identifier": "one"]]))
        XCTAssertThrowsError(try SpaceParser.parse([["Display Identifier": "one", "Spaces": [entry(1,"x",0)],
            "Current Space": entry(2,"y",0)]]))
    }

    private func entry(_ id: Int, _ uuid: String, _ type: Int) -> [String: Any] {
        ["ManagedSpaceID": NSNumber(value: id), "uuid": uuid, "type": NSNumber(value: type)]
    }
}
