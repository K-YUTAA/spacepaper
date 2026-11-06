import AppKit
import SpacePaperCore

enum AppPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SpacePaper", isDirectory: true)
    static let library = root.appendingPathComponent("Images", isDirectory: true)
    static let state = root.appendingPathComponent("state.json")
    static let status = root.appendingPathComponent("status.json")
    static let agent = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/local.kitano.spacepaper.plist")

    static func prepare() throws {
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }
}

struct AppState: Codable {
    var version = 1
    var paused = false
    var includeBuiltIns = true
    var folders: [String] = []
    var assignments: [String: String] = [:]
    var seedAssetIDs: [String] = []
    var displayLastSeen: [String: Date] = [:]
    var startAtLogin: Bool?
    var bootstrapped = false
    var wallpaperBackup: String?
    var catalogSettings: CatalogSettings {
        CatalogSettings(seedAssetIDs: seedAssetIDs, includeBuiltIns: includeBuiltIns, folders: folders)
    }
    init() {}
    enum CodingKeys: String, CodingKey {
        case version, paused, includeBuiltIns, folders, assignments, seedAssetIDs
        case bootstrapped, wallpaperBackup, displayLastSeen, startAtLogin
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        includeBuiltIns = try c.decodeIfPresent(Bool.self, forKey: .includeBuiltIns) ?? true
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? []
        assignments = try c.decodeIfPresent([String:String].self, forKey: .assignments) ?? [:]
        seedAssetIDs = try c.decodeIfPresent([String].self, forKey: .seedAssetIDs) ?? []
        bootstrapped = try c.decodeIfPresent(Bool.self, forKey: .bootstrapped) ?? false
        wallpaperBackup = try c.decodeIfPresent(String.self, forKey: .wallpaperBackup)
        displayLastSeen = try c.decodeIfPresent([String:Date].self, forKey: .displayLastSeen) ?? [:]
        startAtLogin = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin)
    }
}

final class StateStore {
    private(set) var state: AppState
    init() throws {
        try AppPaths.prepare()
        if FileManager.default.fileExists(atPath: AppPaths.state.path) {
            let data = try Data(contentsOf: AppPaths.state)
            state = try JSONDecoder().decode(AppState.self, from: data)
            if let raw = try JSONSerialization.jsonObject(with: data) as? [String:Any],
               let originals = raw["originals"] as? [String:String], !originals.isEmpty {
                let target = AppPaths.root.appendingPathComponent("Before/Original-wallpapers.json")
                if !FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(originals).write(to: target, options: .atomic)
                }
            }
            guard state.version == 1 else { throw AppError.message("未対応の設定ファイルです") }
        } else { state = AppState() }
    }
    func update(_ edit: (inout AppState) -> Void) throws {
        var next = state
        edit(&next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: AppPaths.state, options: .atomic)
        state = next
    }
    func backupWallpapersIfNeeded() throws {
        let backup = AppPaths.root.appendingPathComponent("Before", isDirectory: true)
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        do {
            try BackupFile.ensure(source: source, target: backup.appendingPathComponent("Index.plist"))
        } catch { throw AppError.message("元の壁紙設定をバックアップできないため、変更を待機しています。") }
        if state.wallpaperBackup != backup.path { try update { $0.wallpaperBackup = backup.path } }
    }

}

enum AppError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let s): return s } }
}

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let url = AppPaths.root.appendingPathComponent("events.log")
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
        let rotated = AppPaths.root.appendingPathComponent("events.previous.log")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    if let file = try? FileHandle(forWritingTo: url) {
        defer { try? file.close() }
        do { try file.seekToEnd(); try file.write(contentsOf: Data(line.utf8)) } catch { }
    }
}

struct BoundDisplay {
    let screen: NSScreen
    let uuid: String
    let group: DisplaySpaces
    var currentSlot: String? {
        guard let current = group.current, current.isDesktop else { return nil }
        return SpaceParser.slot(display: uuid, space: current)
    }
    var slots: [String] {
        group.spaces.filter(\.isDesktop).map { SpaceParser.slot(display: uuid, space: $0) }
    }
}

final class SpaceReader {
    typealias Connection = @convention(c) () -> Int32
    typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private let handle: UnsafeMutableRawPointer
    private let mainConnection: Connection
    private let copySpaces: CopySpaces

    init() throws {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let c = dlsym(h, "SLSMainConnectionID") ?? dlsym(h, "CGSMainConnectionID"),
              let s = dlsym(h, "SLSCopyManagedDisplaySpaces") ?? dlsym(h, "CGSCopyManagedDisplaySpaces") else {
            throw AppError.message("このmacOSではSpace情報の読み取りを利用できません。壁紙の変更は停止しています。")
        }
        handle = h
        mainConnection = unsafeBitCast(c, to: Connection.self)
        copySpaces = unsafeBitCast(s, to: CopySpaces.self)
    }

    func read() throws -> [BoundDisplay] {
        let connection = mainConnection()
        guard connection != 0, !NSScreen.screens.isEmpty,
              let raw = copySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            throw AppError.message("デスクトップ環境に接続できません。画面の復帰後に再確認します。")
        }
        let groups = try SpaceParser.parse(raw)
        return try NSScreen.screens.map { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
                throw AppError.message("モニターの識別子を取得できません")
            }
            let identifier = CFUUIDCreateString(nil, uuid)! as String
            let group = groups.first { $0.displayID.caseInsensitiveCompare(identifier) == .orderedSame }
                ?? (groups.count == 1 && groups[0].displayID == "Main" ? groups[0] : nil)
            guard let group = group else {
                throw AppError.message("画面構成の変更中です。落ち着いてから再確認します。")
            }
            return BoundDisplay(screen: screen, uuid: identifier, group: group)
        }
    }
}

enum LoginAgent {
    static var enabled: Bool { FileManager.default.fileExists(atPath: AppPaths.agent.path) }
    static func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            if self.enabled { try FileManager.default.removeItem(at: AppPaths.agent) }
            return
        }
        let executable = Bundle.main.executableURL!.path
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw AppError.message("アプリとしてインストールしてから設定してください")
        }
        let value: [String: Any] = [
            "Label": "local.kitano.spacepaper", "ProgramArguments": [executable],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 15,
            "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive",
            "StandardOutPath": AppPaths.root.appendingPathComponent("launch.log").path,
            "StandardErrorPath": AppPaths.root.appendingPathComponent("launch.error.log").path
        ]
        try FileManager.default.createDirectory(at: AppPaths.agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            .write(to: AppPaths.agent, options: .atomic)
    }
}

enum ControlMailbox {
    static let mailbox = CommandMailbox(root: AppPaths.root)
    static func send(_ name: String, path: String? = nil) throws {
        let command = try mailbox.issue(name, path: path)
        defer { try? mailbox.cancel(command); mailbox.removeReply(to: command) }
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let reply = mailbox.reply(to: command) {
                if let error = reply.error { throw AppError.message(error) }
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw AppError.message("SpacePaperからの応答を確認できません。未処理の操作は取り消しました。")
    }
}
