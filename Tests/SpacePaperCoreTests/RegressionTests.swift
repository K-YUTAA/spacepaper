import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import SpacePaperCore

final class RegressionTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testQuitCannotCrossAnAppRestartEvenWithinItsTTL() throws {
        let mailbox = CommandMailbox(root: root)
        let first = RunningInstance(id: "first", pid: 1)
        try mailbox.publish(first)
        _ = try mailbox.issue("quit", isAlive: { _ in true })
        let next = RunningInstance(id: "next", pid: 2)
        try mailbox.publish(next)
        XCTAssertNil(try mailbox.take(for: next))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mailbox.request.path))
    }

    func testExpiredAndLegacyRequestsAreDiscarded() throws {
        let mailbox = CommandMailbox(root: root)
        let instance = RunningInstance(id: "current", pid: 1)
        try mailbox.publish(instance)
        let now = Date()
        _ = try mailbox.issue("quit", now: now.addingTimeInterval(-16), isAlive: { _ in true })
        XCTAssertNil(try mailbox.take(for: instance, now: now))
        try Data(#"{"id":"legacy","name":"quit"}"#.utf8).write(to: mailbox.request)
        XCTAssertNil(try mailbox.take(for: instance, now: now))
    }

    func testStoppedAppDoesNotQueueAQuit() throws {
        let mailbox = CommandMailbox(root: root)
        XCTAssertThrowsError(try mailbox.issue("quit"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mailbox.request.path))
        try mailbox.publish(RunningInstance(id: "dead", pid: 1))
        XCTAssertThrowsError(try mailbox.issue("quit", isAlive: { _ in false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mailbox.request.path))
    }

    func testTimeoutCleanupOnlyRemovesItsOwnRequest() throws {
        let mailbox = CommandMailbox(root: root)
        let instance = RunningInstance(pid: 1)
        try mailbox.publish(instance)
        let first = try mailbox.issue("pause", isAlive: { _ in true })
        try mailbox.cancel(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mailbox.request.path))
        let next = try mailbox.issue("resume", isAlive: { _ in true })
        try mailbox.cancel(first)
        XCTAssertEqual(try mailbox.take(for: instance)?.id, next.id)
    }

    func testCommandsAreConsumedOnceAndRepliesArePerRequest() throws {
        let mailbox = CommandMailbox(root: root)
        let instance = RunningInstance(pid: 1)
        try mailbox.publish(instance)
        let first = try mailbox.issue("pause", isAlive: { _ in true })
        XCTAssertEqual(try mailbox.take(for: instance)?.id, first.id)
        XCTAssertNil(try mailbox.take(for: instance))
        let next = try mailbox.issue("resume", isAlive: { _ in true })
        try mailbox.acknowledge(next)
        try mailbox.acknowledge(first, error: "failed")
        XCTAssertEqual(mailbox.reply(to: first)?.error, "failed")
        XCTAssertNil(mailbox.reply(to: next)?.error)
    }

    func testRelativePathUsesTheClientWorkingDirectory() {
        XCTAssertEqual(UserPath.absolute("../WallPaper", directory: "/Users/user/Pictures/sub", home: "/Users/user"), "/Users/user/Pictures/WallPaper")
        XCTAssertEqual(UserPath.absolute("~/Pictures", directory: "/", home: "/Users/user"), "/Users/user/Pictures")
    }

    func testCorrectVisibleWallpaperWinsAReconnectConflict() {
        let p = Allocator.plan(slots: ["A/hidden", "Z/visible"],
            previous: ["A/hidden": "a", "Z/visible": "a"], observed: ["Z/visible": "a"], assets: ["a", "b"])
        XCTAssertEqual(p.assignments["Z/visible"], "a")
        XCTAssertEqual(p.assignments["A/hidden"], "b")
    }

    func testDeletedSpacesArePrunedButDisconnectedDisplaysHaveAGracePeriod() {
        let now = Date()
        let p = ReservationHistory.prune(assignments: ["A/live":"a", "A/deleted":"b", "B/offline":"c", "C/expired":"d"],
            lastSeen: ["B":now, "C":now.addingTimeInterval(-31 * 86400)], displays: ["A"], slots: ["A/live"], now: now)
        XCTAssertEqual(p.assignments, ["A/live":"a", "B/offline":"c"])
    }

    func testDelayedReadbackDoesNotCauseRepeatedWrites() {
        var tracker = ApplyTracker()
        let now = Date()
        XCTAssertTrue(tracker.shouldApply(slot: "one", expected: "new", actual: "old", now: now))
        tracker.didApply(slot: "one", image: "new", now: now)
        for delay in [1.0, 2, 4] {
            XCTAssertFalse(tracker.shouldApply(slot: "one", expected: "new", actual: "old", now: now.addingTimeInterval(delay)))
        }
        XCTAssertTrue(tracker.shouldApply(slot: "one", expected: "new", actual: "old", now: now.addingTimeInterval(5)))
        XCTAssertFalse(tracker.shouldApply(slot: "one", expected: "new", actual: "new", now: now.addingTimeInterval(6)))
        XCTAssertTrue(tracker.shouldApply(slot: "one", expected: "new", actual: "overwritten", now: now.addingTimeInterval(7)))
    }

    func testMissingBackupSourceDoesNotProduceABackup() throws {
        let target = root.appendingPathComponent("Before/Index.plist")
        XCTAssertThrowsError(try BackupFile.ensure(source: root.appendingPathComponent("missing"), target: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testInspectingUnrelatedWallpaperDoesNotCreateACopy() throws {
        let source = try image("one.png")
        let library = ImageLibrary(directory: root.appendingPathComponent("Images"))
        XCTAssertNotNil(library.identity(source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.directory.path))
        let imported = try library.importImage(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        let restarted = ImageLibrary(directory: library.directory)
        XCTAssertEqual(restarted.identity(URL(fileURLWithPath: imported.path)), imported.id)
    }

    func testUnavailableFolderLeavesTheLastGoodCatalogUntouched() throws {
        let folder = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = try image("Photos/one.png")
        let library = ImageLibrary(directory: root.appendingPathComponent("Images"))
        let settings = CatalogSettings(seedAssetIDs: [], includeBuiltIns: false, folders: [folder.path])
        try library.reload(settings: settings)
        let original = library.assets
        XCTAssertEqual(original.count, 1)
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Detached"))
        XCTAssertThrowsError(try library.reload(settings: settings))
        XCTAssertEqual(library.assets, original)
        try FileManager.default.moveItem(at: root.appendingPathComponent("Detached"), to: folder)
        try library.reload(settings: settings)
        XCTAssertEqual(library.assets, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func image(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }
}
