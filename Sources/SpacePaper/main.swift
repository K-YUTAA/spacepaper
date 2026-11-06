import AppKit
import Darwin
import SpacePaperCore

let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--use-folder"), arguments.indices.contains(index + 1) {
    do { try ControlMailbox.send("use-folder", path: UserPath.absolute(arguments[index + 1])); print("画像フォルダを設定しました"); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

if arguments.contains("--status") {
    if let data = try? Data(contentsOf: AppPaths.status), let text = String(data: data, encoding: .utf8) { print(text); exit(0) }
    print("SpacePaperの動作記録はまだありません"); exit(1)
}
for command in ["reconcile", "pause", "resume", "quit"] where arguments.contains("--\(command)") {
    do { try ControlMailbox.send(command); print("SpacePaper: \(command) 完了"); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if arguments.contains("--diagnose") {
    let _ = NSApplication.shared
    do {
        let snapshot = try SpaceReader().read()
        let value: [String: Any] = ["displayCount": snapshot.count,
            "desktopCount": snapshot.flatMap(\.slots).count,
            "displays": snapshot.map { ["name": $0.screen.localizedName, "uuid": $0.uuid,
                "desktopCount": $0.slots.count, "currentIsDesktop": $0.currentSlot != nil] as [String: Any] }]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self)); exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
try AppPaths.prepare()
let lockFD = open(AppPaths.root.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
    print("SpacePaperはすでに起動しています"); exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var controller: Controller?
    var item: NSStatusItem!
    var startupError: String?
    var commandWatch: DispatchSourceFileSystemObject?
    let instance = RunningInstance()

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "SpacePaper")
        item.button?.image?.isTemplate = true
        do {
            controller = try Controller()
            controller?.onStatus = { [weak self] in self?.refreshTooltip() }
            if arguments.contains("--enable-login") {
                try setStartAtLogin(true)
            } else if let wanted = controller?.store.state.startAtLogin {
                // Restore the preference after a Homebrew upgrade and bind it to
                // this application's current install path.
                try LoginAgent.setEnabled(wanted)
            } else {
                let registered = LoginAgent.enabled
                try controller?.store.update { $0.startAtLogin = registered }
            }
            try ControlMailbox.mailbox.publish(instance)
            let fd = open(AppPaths.root.path, O_EVTONLY)
            guard fd >= 0 else { throw MailboxError.io }
            let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
            watch.setEventHandler { [weak self] in self?.processMailbox() }
            watch.setCancelHandler { close(fd) }
            commandWatch = watch; watch.resume()
            processMailbox()
            controller?.start()
            log("started version=\(AppVersion.current) pid=\(ProcessInfo.processInfo.processIdentifier)")
        } catch { startupError = error.localizedDescription; log("startup-error \(error.localizedDescription)") }

        rebuildMenu()
        refreshTooltip()
    }

    func processMailbox() {
        do {
            guard let command = try ControlMailbox.mailbox.take(for: instance) else { return }
            do {
                guard let controller = controller else { throw AppError.message("起動が完了していません") }
                switch command.name {
                case "use-folder":
                    guard let path = command.path else { throw AppError.message("画像フォルダが指定されていません") }
                    try controller.useFolder(path)
                case "pause": try controller.setPaused(true)
                case "resume": try controller.setPaused(false)
                case "reconcile": controller.reload()
                case "quit":
                    try ControlMailbox.mailbox.acknowledge(command)
                    NSApplication.shared.terminate(nil)
                    return
                default: throw AppError.message("未対応の操作です")
                }
                try ControlMailbox.mailbox.acknowledge(command)
            } catch { try ControlMailbox.mailbox.acknowledge(command, error: error.localizedDescription) }
        } catch { log("command-error \(error.localizedDescription)") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        commandWatch?.cancel()
        ControlMailbox.mailbox.unpublish(instance)
    }

    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { controller?.report(error); alert(error.localizedDescription) }
    }

    func refreshTooltip() {
        item.button?.toolTip = "SpacePaper · \(controller?.summary ?? startupError ?? "待機中")"
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenuContents(menu) }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        rebuildMenuContents(menu)
        item.menu = menu
    }

    func rebuildMenuContents(_ menu: NSMenu) {
        menu.removeAllItems()
        add("SpacePaper", to: menu)
        add(controller?.summary ?? startupError ?? "待機中", to: menu)
        if let controller = controller {
            add("\(controller.displayCount)画面 · \(controller.desktopCount)デスクトップ · \(controller.assets.count)画像", to: menu)
            if !controller.store.state.folders.isEmpty {
                add("候補: " + controller.store.state.folders.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "), to: menu)
            }
        }
        menu.addItem(.separator())
        action("今すぐ重複を確認", #selector(reconcile), menu)
        action(controller?.store.state.paused == true ? "自動変更を再開" : "自動変更を一時停止", #selector(togglePause), menu)
        menu.addItem(.separator())
        action("画像フォルダを選び直す…", #selector(chooseFolder), menu)
        action("画像フォルダを追加…", #selector(addFolder), menu)
        let builtins = action("Mac標準の画像も使う", #selector(toggleBuiltIns), menu)
        builtins.state = controller?.store.state.includeBuiltIns == true ? .on : .off
        if let paths = controller?.store.state.folders, !paths.isEmpty {
            let item = NSMenuItem(title: "登録したフォルダ", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for path in paths {
                let entry = NSMenuItem(title: "\(URL(fileURLWithPath: path).lastPathComponent) を候補から外す",
                    action: #selector(removeFolder(_:)), keyEquivalent: "")
                entry.target = self; entry.representedObject = path; sub.addItem(entry)
            }
            item.submenu = sub; menu.addItem(item)
        }
        action("壁紙画像の保存先を開く", #selector(openImages), menu)
        menu.addItem(.separator())
        let login = action("ログイン時に起動", #selector(toggleLogin), menu)
        login.state = LoginAgent.enabled ? .on : .off
        action("状態・ログを開く", #selector(openLogs), menu)
        action("使い方", #selector(help), menu)
        menu.addItem(.separator())
        action("SpacePaperを終了", #selector(quit), menu)
    }

    private func add(_ title: String, to menu: NSMenu) { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); menu.addItem(item) }
    @discardableResult private func action(_ title: String, _ selector: Selector, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self; menu.addItem(item); return item
    }

    @objc func reconcile() { controller?.reload() }
    @objc func togglePause() { if let controller = controller { perform { try controller.setPaused(!controller.store.state.paused) } } }
    @objc func toggleBuiltIns() { perform { try controller?.toggleBuiltIns() } }
    @objc func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "壁紙に使う画像フォルダを選択"
        panel.message = "選択したフォルダ内の画像だけを候補にします。サブフォルダも読み込みます。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { perform { try controller?.useFolder(url.path) } }
    }
    @objc func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "壁紙に使う画像フォルダを選択"
        panel.message = "サブフォルダの画像も候補に追加します。元の画像は変更しません。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { for url in panel.urls { perform { try controller?.addFolder(url.path) } } }
    }
    @objc func removeFolder(_ item: NSMenuItem) { if let path = item.representedObject as? String { perform { try controller?.removeFolder(path) } } }
    @objc func openImages() { NSWorkspace.shared.open(AppPaths.library) }
    @objc func openLogs() { NSWorkspace.shared.open(AppPaths.root) }
    @objc func toggleLogin() {
        do { try setStartAtLogin(!LoginAgent.enabled) }
        catch { alert(error.localizedDescription) }
    }
    func setStartAtLogin(_ enabled: Bool) throws {
        let old = controller?.store.state.startAtLogin ?? LoginAgent.enabled
        try LoginAgent.setEnabled(enabled)
        do { try controller?.store.update { $0.startAtLogin = enabled } }
        catch { try? LoginAgent.setEnabled(old); throw error }
    }
    @objc func help() {
        alert("各モニター・各デスクトップに異なる壁紙を割り当てます。新しいデスクトップは初めて開いたときに反映します。\n\n画像フォルダはメニューから追加でき、追加した画像も約2分以内に読み込みます。画像不足の場合はメニューに表示します。\n\n一時停止・終了すると、その時点の壁紙が残ります。ログイン時に起動のチェックを外すと、次回ログインから自動起動しません。\n\nフルスクリーンのアプリ専用Spaceは対象外です。")
    }
    func alert(_ text: String) { let alert = NSAlert(); alert.messageText = "SpacePaper"; alert.informativeText = text; alert.runModal() }
    @objc func quit() { NSApplication.shared.terminate(nil) }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
