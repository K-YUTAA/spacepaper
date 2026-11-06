import AppKit
import SpacePaperCore

private struct ImageCheck {
    let assets: [String: WallpaperAsset]
    let warnings: [String]
    let observed: [String: String]
    let urlIdentities: [String: String]
    let seeds: [String]
}

/// Its mutable image caches are confined to a serial background queue.
private final class ImageWorker {
    let library = ImageLibrary(directory: AppPaths.library)
    var settings: CatalogSettings?
    var lastReload = Date.distantPast

    func check(state: AppState, urls: [String: URL], force: Bool) throws -> ImageCheck {
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "壁紙画像の読み込み")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var seeds = Set(state.seedAssetIDs)
        if !state.bootstrapped && state.folders.isEmpty {
            for url in urls.values {
                if let asset = try? autoreleasepool(invoking: { try library.importImage(url) }) { seeds.insert(asset.id) }
            }
        }
        let next = CatalogSettings(seedAssetIDs: seeds.sorted(), includeBuiltIns: state.includeBuiltIns, folders: state.folders)
        for path in next.folders {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: path) else {
                settings = nil
                throw CatalogUnavailable(message: "画像フォルダ「\(URL(fileURLWithPath: path).lastPathComponent)」を読めないため、予約を維持して待機しています。")
            }
        }
        if force || settings != next || Date().timeIntervalSince(lastReload) > 120 {
            do { try library.reload(settings: next) }
            catch { settings = nil; throw error }
            settings = next; lastReload = Date()
        }
        var observed: [String: String] = [:]
        var identities: [String: String] = [:]
        for (slot, url) in urls {
            if let id = library.identity(url) { observed[slot] = id; identities[url.standardizedFileURL.path] = id }
        }
        return ImageCheck(assets: library.assets, warnings: library.warnings, observed: observed,
                          urlIdentities: identities, seeds: seeds.sorted())
    }
}

final class Controller {
    let store: StateStore
    let reader: SpaceReader
    private(set) var assets: [String: WallpaperAsset] = [:]
    var onStatus: (() -> Void)?
    private(set) var summary = "起動しています…"
    private(set) var detail = ""
    private(set) var displayCount = 0
    private(set) var desktopCount = 0
    private var sleeping = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timers: [Timer] = []
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var lastError = ""
    private var totalWrites = 0
    private var forceReload = true
    private var busy = false
    private var needsCheck = false
    private var tracker = ApplyTracker()
    private let imageQueue = DispatchQueue(label: "local.kitano.spacepaper.images", qos: .utility)
    private let worker = ImageWorker()

    init() throws { store = try StateStore(); reader = try SpaceReader() }

    func start() {
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.schedule(reason: "space", delay: 0.65)
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.schedule(reason: "display", delay: 1.4)
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(NSWorkspace.shared.notificationCenter, name) { [weak self] in
                self?.sleeping = true; self?.generation += 1
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(NSWorkspace.shared.notificationCenter, name) { [weak self] in
                self?.sleeping = false; self?.schedule(reason: "wake", delay: 2)
            }
        }
        let poll = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard self?.pending == nil else { return }
            self?.reconcile(reason: "periodic")
        }
        poll.tolerance = 3; timers.append(poll)
        schedule(reason: "launch", delay: 0.3)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
        observers.append((center, token))
    }

    func schedule(reason: String, delay: Double = 0.6) {
        generation += 1
        let token = generation
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == token else { return }
            self.pending = nil; self.reconcile(reason: reason)
            // Read back again after macOS has had time to publish the new wallpaper URL.
            for wait in [1.5, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self = self, self.generation == token else { return }
                    self.reconcile(reason: "settled-\(reason)")
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func reload() { forceReload = true; schedule(reason: "reload", delay: 0.1) }

    func setPaused(_ value: Bool) throws {
        try store.update { $0.paused = value }
        generation += 1; pending?.cancel(); pending = nil
        if value { summary = "一時停止中"; detail = ""; publish(reason: "pause", visible: []) }
        else { schedule(reason: "resume", delay: 0.1) }
    }

    func addFolder(_ path: String) throws {
        let path = try validFolder(path)
        try store.update { if !$0.folders.contains(path) { $0.folders.append(path) } }
        reload()
    }
    func useFolder(_ path: String) throws {
        let path = try validFolder(path)
        try store.update {
            $0.folders = [path]; $0.includeBuiltIns = false
            $0.seedAssetIDs = []; $0.bootstrapped = true
        }
        reload()
    }
    private func validFolder(_ path: String) throws -> String {
        let path = UserPath.absolute(path)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: path) else {
            throw AppError.message("画像フォルダを読めません: \(URL(fileURLWithPath: path).lastPathComponent)")
        }
        return path
    }
    func removeFolder(_ path: String) throws { try store.update { $0.folders.removeAll { $0 == path } }; reload() }
    func toggleBuiltIns() throws { try store.update { $0.includeBuiltIns.toggle() }; reload() }

    func reconcile(reason: String) {
        guard !sleeping else { return }
        guard !store.state.paused else { summary = "一時停止中"; publish(reason: reason, visible: []); return }
        guard !busy else { needsCheck = true; return }
        do {
            let snapshot = try reader.read()
            displayCount = snapshot.count; desktopCount = snapshot.flatMap(\.slots).count
            let urls = Dictionary(uniqueKeysWithValues: snapshot.compactMap { display -> (String, URL)? in
                guard let slot = display.currentSlot, let url = NSWorkspace.shared.desktopImageURL(for: display.screen) else { return nil }
                return (slot, url)
            })
            let state = store.state
            let token = generation
            let force = forceReload
            forceReload = false; busy = true
            if assets.isEmpty { summary = "画像を読み込み中…"; onStatus?() }
            imageQueue.async { [weak self] in
                guard let self = self else { return }
                let result = Result { try autoreleasepool { try self.worker.check(state: state, urls: urls, force: force) } }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.busy = false
                    defer {
                        if self.needsCheck { self.needsCheck = false; self.schedule(reason: "queued", delay: 0.1) }
                    }
                    guard !self.sleeping, !self.store.state.paused else { return }
                    guard self.generation == token, self.store.state.catalogSettings == state.catalogSettings else {
                        self.needsCheck = true; return
                    }
                    do {
                        let output = try result.get()
                        let fresh = try self.reader.read()
                        guard self.sameTopology(snapshot, fresh), fresh.allSatisfy({ display in
                            guard let slot = display.currentSlot else { return true }
                            return NSWorkspace.shared.desktopImageURL(for: display.screen) == urls[slot]
                        }) else { self.needsCheck = true; return }
                        self.assets = output.assets
                        if !self.store.state.bootstrapped {
                            try self.store.update { $0.bootstrapped = true; $0.seedAssetIDs = output.seeds }
                        }
                        try self.apply(snapshot: fresh, output: output, reason: reason)
                    } catch { self.report(error) }
                }
            }
        } catch { report(error) }
    }

    private func apply(snapshot: [BoundDisplay], output: ImageCheck, reason: String) throws {
        guard !assets.isEmpty else { throw AppError.message("候補の画像がありません。画像フォルダを追加してください。") }
        let slots = snapshot.flatMap(\.slots)
        let history = ReservationHistory.prune(assignments: store.state.assignments, lastSeen: store.state.displayLastSeen,
            displays: Set(snapshot.map { $0.uuid.uppercased() }), slots: Set(slots), now: Date())
        let plan = Allocator.plan(slots: slots, previous: history.assignments, observed: output.observed, assets: Array(assets.keys))
        let merged = history.assignments.merging(plan.assignments) { _, new in new }
        if merged != store.state.assignments || history.lastSeen != store.state.displayLastSeen {
            try store.update { $0.assignments = merged; $0.displayLastSeen = history.lastSeen }
        }
        tracker.keepOnly(Set(slots))
        for display in snapshot {
            guard let slot = display.currentSlot, let id = plan.assignments[slot], let asset = assets[id],
                  tracker.shouldApply(slot: slot, expected: id, actual: output.observed[slot], now: Date()) else { continue }
            let fresh = try reader.read()
            guard sameTopology(snapshot, fresh), let target = fresh.first(where: { $0.uuid == display.uuid }), target.currentSlot == slot else {
                schedule(reason: "changed-during-check", delay: 0.8); return
            }
            try store.backupWallpapersIfNeeded()
            try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: asset.path), for: target.screen,
                options: [.imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue), .allowClipping: true])
            tracker.didApply(slot: slot, image: id, now: Date())
            totalWrites += 1
            log("apply reason=\(reason) display=\(display.uuid) space=\(slot) image=\(id.prefix(12))")
        }
        let after = try reader.read()
        guard sameTopology(snapshot, after) else { schedule(reason: "changed-after-apply"); return }
        let visible: [[String: Any]] = after.compactMap { display in
            guard let slot = display.currentSlot else { return nil }
            let actualURL = NSWorkspace.shared.desktopImageURL(for: display.screen)
            // No image I/O on the main thread, including this immediate read-back.
            let actualID = knownIdentity(actualURL, output: output) ?? "unknown"
            return ["display": display.screen.localizedName, "displayUUID": display.uuid, "slot": slot,
                    "actualImage": actualID, "expectedImage": plan.assignments[slot] ?? "unassigned",
                    "matches": actualID == plan.assignments[slot]]
        }
        if !plan.isComplete {
            summary = "画像が\(plan.unassigned.count)枚不足しています"
            detail = "\(desktopCount)デスクトップに対して\(assets.count)画像。画像フォルダを追加してください。"
        } else if !visible.allSatisfy({ $0["matches"] as? Bool == true }) {
            summary = "壁紙の反映を確認中"; detail = "反映を待って再確認します。"
        } else {
            summary = "稼働中 · 表示中の壁紙に重複なし"
            detail = "未表示のデスクトップは、開いたときに反映します。"
        }
        if !output.warnings.isEmpty { detail += " " + output.warnings.prefix(5).joined(separator: " / ") }
        lastError = ""; publish(reason: reason, visible: visible, pendingCount: plan.unassigned.count)
    }

    private func knownIdentity(_ url: URL?, output: ImageCheck) -> String? {
        guard let url = url else { return nil }
        let path = url.standardizedFileURL.path
        if let id = assets.values.first(where: { $0.path == path })?.id { return id }
        return output.urlIdentities[path]
    }
    private func sameTopology(_ a: [BoundDisplay], _ b: [BoundDisplay]) -> Bool {
        func signature(_ entries: [BoundDisplay]) -> [String] {
            entries.map { "\($0.uuid)|\($0.group.currentID)|\($0.slots.sorted().joined(separator: ","))" }.sorted()
        }
        return signature(a) == signature(b)
    }
    func report(_ error: Error) {
        summary = "自動変更を待機中"; detail = error.localizedDescription
        if lastError != detail { log("error \(detail)"); lastError = detail }
        publish(reason: "error", visible: [], error: detail)
    }
    private func publish(reason: String, visible: [[String: Any]], pendingCount: Int = 0, error: String? = nil) {
        let ids = visible.compactMap { $0["actualImage"] as? String }
        var value: [String: Any] = ["updatedAt": ISO8601DateFormatter().string(from: Date()), "version": AppVersion.current,
            "pid": getpid(), "paused": store.state.paused, "reason": reason, "summary": summary, "detail": detail,
            "displayCount": displayCount, "desktopCount": desktopCount, "imageCount": assets.count,
            "unassignedCount": pendingCount, "writesThisSession": totalWrites, "visible": visible,
            "visibleUnique": !ids.isEmpty && !ids.contains("unknown") && Set(ids).count == ids.count]
        if let error = error { value["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: AppPaths.status, options: .atomic)
        }
        onStatus?()
    }
}
