// extdisplay — 外部ディスプレイだけをソフト的に無効化／復帰する小さなユーティリティ
//
// ケーブルは挿したままなので、USB-C 給電（充電）は維持される。
// macOS の非公開 API `CGSConfigureDisplayEnabled`（SkyLight / CoreGraphics）を使う。
//
// ビルド:  swiftc -O extdisplay.swift -o extdisplay
// 使い方:  extdisplay status | off | on | toggle | menubar

import Cocoa
import CoreGraphics
import Carbon.HIToolbox
import IOKit

// MARK: - ログ（画面出力に加えて ~/Library/Logs/extdisplay.log に追記）

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/extdisplay.log")

func logLine(_ message: String, error: Bool = false) {
    if error { fputs(message + "\n", stderr) } else { print(message) }
    let stamp = ISO8601DateFormatter().string(from: Date())
    let entry = "\(stamp) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
    guard let data = entry.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

// MARK: - 非公開 API の読み込み

typealias ConfigureDisplayEnabledFn =
    @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

/// CoreGraphics の CGS 名 → SkyLight の SLS 名の順に探す
func loadConfigureDisplayEnabled() -> (fn: ConfigureDisplayEnabledFn, name: String)? {
    let candidates = [
        ("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "CGSConfigureDisplayEnabled"),
        ("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", "SLSConfigureDisplayEnabled"),
    ]
    for (path, name) in candidates {
        if let handle = dlopen(path, RTLD_LAZY), let sym = dlsym(handle, name) {
            return (unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self), name)
        }
    }
    return nil
}

// MARK: - ディスプレイ列挙

func displayList(online: Bool) -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    let first = online ? CGGetOnlineDisplayList(0, nil, &count)
                       : CGGetActiveDisplayList(0, nil, &count)
    guard first == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    let second = online ? CGGetOnlineDisplayList(count, &ids, &count)
                        : CGGetActiveDisplayList(count, &ids, &count)
    guard second == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

func isBuiltin(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsBuiltin(id) != 0 }
func isActive(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsActive(id) != 0 }
func isInMirrorSet(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsInMirrorSet(id) != 0 }

/// 画面が映っているか。ミラー先のディスプレイは CGDisplayIsActive が 0 になる
/// （アクティブ一覧にも出ない）ので、ミラーセットに入っていれば表示中とみなす。
func isShowing(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayIsOnline(id) != 0 && (isActive(id) || isInMirrorSet(id))
}

/// 映っている外部ディスプレイ（ミラー先も含む）
func visibleExternals() -> [CGDirectDisplayID] {
    var ids = displayList(online: true)
    for id in displayList(online: false) where !ids.contains(id) { ids.append(id) }
    return ids.filter { !isBuiltin($0) && isShowing($0) }
}

/// 蓋が閉じているか（IOPMrootDomain の AppleClamshellState）。プロパティが無い機種では nil
func clamshellClosed() -> Bool? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    let prop = IORegistryEntryCreateCFProperty(
        service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    return prop?.takeRetainedValue() as? Bool
}

/// 内蔵ディスプレイに画面が映っているか（蓋が開いていて、表示中またはミラー中）
func builtinIsVisible() -> Bool {
    if clamshellClosed() == true { return false }
    return displayList(online: true).contains { isBuiltin($0) && isShowing($0) }
}

func builtinIsActive() -> Bool {
    displayList(online: false).contains { isBuiltin($0) }
}

func describe(_ id: CGDirectDisplayID) -> String {
    let kind = isBuiltin(id) ? "内蔵" : "外部"
    let state = isActive(id) ? "表示中" : (isShowing(id) ? "ミラー表示中" : "無効")
    let vendor = String(format: "0x%04X", CGDisplayVendorNumber(id))
    let model = String(format: "0x%04X", CGDisplayModelNumber(id))
    var extra = ""
    if isShowing(id) {
        extra += " \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))"
    }
    if CGDisplayIsMain(id) != 0 { extra += " main" }
    let master = CGDisplayMirrorsDisplay(id)
    if master != kCGNullDirectDisplay {
        extra += " mirror-of=\(master)"
    } else if isInMirrorSet(id) {
        extra += " mirror-master"
    }
    if CGDisplayIsInHWMirrorSet(id) != 0 { extra += " hw-mirror" }
    return "id=\(id)  \(kind)  \(state)  vendor=\(vendor) model=\(model)\(extra)"
}

/// status 用の詳細（各 CGDisplay* の生の値）
func describeFlags(_ id: CGDirectDisplayID) -> String {
    "online=\(CGDisplayIsOnline(id)) active=\(CGDisplayIsActive(id)) asleep=\(CGDisplayIsAsleep(id))"
        + " main=\(CGDisplayIsMain(id)) inMirrorSet=\(CGDisplayIsInMirrorSet(id))"
        + " mirrorsDisplay=\(CGDisplayMirrorsDisplay(id)) primary=\(CGDisplayPrimaryDisplay(id))"
        + " inHWMirrorSet=\(CGDisplayIsInHWMirrorSet(id))"
}

func describeClamshell() -> String {
    switch clamshellClosed() {
    case true?: return "蓋: 閉じている"
    case false?: return "蓋: 開いている"
    case nil: return "蓋: 不明（AppleClamshellState なし）"
    }
}

// MARK: - 状態ファイル（無効化したディスプレイ ID と元のミラー構成を覚えておく）
//
// 無効化したディスプレイはオンライン一覧から消える場合があるため、
// 復帰に必要な ID をファイルに保存しておく。
// 書式: 数字だけの行 = 無効化した ID、"mirror <id> <master>" = 元のミラー構成

let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".extdisplay-disabled")

struct MirrorPair: Equatable {
    var display: CGDirectDisplayID
    var master: CGDirectDisplayID
}

struct SavedState {
    var disabled: [CGDirectDisplayID] = []
    var mirrors: [MirrorPair] = []
}

func loadState() -> SavedState {
    var state = SavedState()
    guard let text = try? String(contentsOf: stateURL, encoding: .utf8) else { return state }
    for line in text.split(whereSeparator: \.isNewline) {
        let fields = line.split(separator: " ")
        if fields.count == 1, let id = CGDirectDisplayID(fields[0]) {
            state.disabled.append(id)
        } else if fields.count == 3, fields[0] == "mirror",
                  let display = CGDirectDisplayID(fields[1]), let master = CGDirectDisplayID(fields[2]) {
            state.mirrors.append(MirrorPair(display: display, master: master))
        }
    }
    return state
}

func saveState(_ state: SavedState) {
    if state.disabled.isEmpty && state.mirrors.isEmpty {
        try? FileManager.default.removeItem(at: stateURL)
        return
    }
    let lines = state.disabled.map { String($0) }
        + state.mirrors.map { "mirror \($0.display) \($0.master)" }
    try? (lines.joined(separator: "\n") + "\n").write(to: stateURL, atomically: true, encoding: .utf8)
}

// MARK: - 有効化／無効化

/// 1 回の構成トランザクション。body が false を返したら取り消す。
/// .forSession: ログアウトすると元に戻る（万一のときの安全弁）
func transaction(_ body: (CGDisplayConfigRef) -> Bool) -> Bool {
    var config: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&config)
    guard begin == .success, let cfg = config else {
        logLine("エラー: CGBeginDisplayConfiguration 失敗 (CGError \(begin.rawValue))", error: true)
        return false
    }
    guard body(cfg) else {
        CGCancelDisplayConfiguration(cfg)
        return false
    }
    let done = CGCompleteDisplayConfiguration(cfg, .forSession)
    logLine("  CGCompleteDisplayConfiguration(.forSession) -> CGError \(done.rawValue)")
    if done != .success {
        logLine("エラー: CGCompleteDisplayConfiguration に失敗しました", error: true)
        return false
    }
    return true
}

/// 1 台ずつ個別の構成トランザクションで切り替える（1 台の失敗が他に波及しないように）。
@discardableResult
func configure(_ id: CGDirectDisplayID, enabled: Bool) -> Bool {
    guard let api = loadConfigureDisplayEnabled() else {
        logLine("エラー: CGSConfigureDisplayEnabled / SLSConfigureDisplayEnabled のどちらも見つかりません", error: true)
        return false
    }
    return transaction { cfg in
        let err = api.fn(cfg, id, enabled)
        logLine("  \(api.name)(id=\(id), enabled=\(enabled)) -> CGError \(err.rawValue)")
        if err != .success {
            logLine("エラー: id=\(id) の切り替えに失敗しました", error: true)
        }
        return err == .success
    }
}

/// ミラーを設定する（master が kCGNullDirectDisplay なら解除）
func configureMirrors(_ pairs: [MirrorPair]) -> Bool {
    transaction { cfg in
        for pair in pairs {
            let err = CGConfigureDisplayMirrorOfDisplay(cfg, pair.display, pair.master)
            logLine("  CGConfigureDisplayMirrorOfDisplay(id=\(pair.display), master=\(pair.master)) -> CGError \(err.rawValue)")
            if err != .success {
                logLine("エラー: id=\(pair.display) のミラー設定に失敗しました", error: true)
                return false
            }
        }
        return true
    }
}

/// 現在のミラー構成（ミラー先 → マスター）
func currentMirrors() -> [MirrorPair] {
    displayList(online: true).compactMap { id in
        let master = CGDisplayMirrorsDisplay(id)
        return master == kCGNullDirectDisplay ? nil : MirrorPair(display: id, master: master)
    }
}

/// 反映を最大 2 秒待って、条件が成り立ったか確認する
func waitFor(_ condition: () -> Bool) -> Bool {
    for _ in 0..<20 {
        if condition() { return true }
        usleep(100_000)
    }
    return condition()
}

func waitUntil(_ id: CGDirectDisplayID, active expected: Bool) -> Bool {
    waitFor { isActive(id) == expected }
}

func logDisplays(_ title: String) {
    logLine("\(title): (\(describeClamshell()))")
    var ids = displayList(online: true)
    for id in displayList(online: false) where !ids.contains(id) { ids.append(id) }
    if ids.isEmpty { logLine("  (ディスプレイなし)") }
    for id in ids { logLine("  " + describe(id)) }
}

@discardableResult
func turnOff(force: Bool = false) -> Bool {
    logLine("=== off (macOS \(ProcessInfo.processInfo.operatingSystemVersionString)) ===")
    logDisplays("実行前")
    if visibleExternals().isEmpty {
        logLine("表示中の外部ディスプレイはありません")
        return true
    }
    // 内蔵が映っていない（蓋閉じなど）なら、外部を切ると画面が無くなるので中止
    if !builtinIsVisible() && !force {
        logLine("中止: 内蔵ディスプレイが表示されていません（蓋が閉じている？）。"
            + "外部を切ると表示先が無くなるため実行しません。強行するなら --force", error: true)
        return false
    }
    var state = loadState()

    // ミラー中なら先に解除する（ミラーセット内のディスプレイは個別に無効化できない）
    let mirrors = currentMirrors()
    if !mirrors.isEmpty {
        logLine("ミラーリングを解除します: "
            + mirrors.map { "id=\($0.display)→\($0.master)" }.joined(separator: ", "))
        for pair in mirrors where !state.mirrors.contains(pair) { state.mirrors.append(pair) }
        saveState(state)
        let unmirror = mirrors.map { MirrorPair(display: $0.display, master: kCGNullDirectDisplay) }
        guard configureMirrors(unmirror),
              waitFor({ currentMirrors().isEmpty && (force || builtinIsActive()) }) else {
            logLine("中止: ミラーリングを解除できませんでした（外部ディスプレイはそのまま）", error: true)
            logDisplays("実行後")
            return false
        }
        logDisplays("ミラー解除後")
    }
    // 解除後に内蔵がアクティブになっていなければ、外部は切らない
    if !builtinIsActive() && !force {
        logLine("中止: 内蔵ディスプレイがアクティブになっていません。外部ディスプレイはそのままにします", error: true)
        return false
    }

    // 先に ID を保存してから無効化する
    let externals = visibleExternals()
    for id in externals where !state.disabled.contains(id) { state.disabled.append(id) }
    saveState(state)

    var ok = true
    for id in externals {
        guard configure(id, enabled: false) else { ok = false; continue }
        if waitFor({ !isShowing(id) }) {
            logLine("無効化: id=\(id)")
        } else {
            logLine("エラー: API は成功を返したが id=\(id) はまだ表示中です"
                + "（この macOS ではこの方法が効かない可能性）", error: true)
            ok = false
        }
    }
    logDisplays("実行後")
    return ok
}

@discardableResult
func turnOn() -> Bool {
    logLine("=== on ===")
    logDisplays("実行前")
    var state = loadState()
    var targets = state.disabled
    for id in displayList(online: true) where !isBuiltin(id) && !isShowing(id) && !targets.contains(id) {
        targets.append(id)
    }
    targets.removeAll { isShowing($0) }  // すでに表示中のものは対象外

    var failed: [CGDirectDisplayID] = []
    for id in targets {
        if configure(id, enabled: true), waitUntil(id, active: true) {
            logLine("復帰: id=\(id)")
        } else {
            failed.append(id)
        }
    }
    // 古い ID（再接続やログアウトで無効になったもの）は失敗しても残さない
    let online = Set(displayList(online: true))
    state.disabled = failed.filter { online.contains($0) }

    // off 前のミラー構成に戻す（外部がすべて戻ったときだけ）
    if failed.isEmpty && !state.mirrors.isEmpty {
        let restorable = state.mirrors.filter {
            online.contains($0.display) && online.contains($0.master) && CGDisplayMirrorsDisplay($0.display) != $0.master
        }
        if !restorable.isEmpty {
            logLine("ミラーリングを元に戻します: "
                + restorable.map { "id=\($0.display)→\($0.master)" }.joined(separator: ", "))
            let restored = configureMirrors(restorable)
                && waitFor({ restorable.allSatisfy { CGDisplayMirrorsDisplay($0.display) == $0.master } })
            if !restored {
                logLine("ミラーリングを戻せませんでした（拡張表示のまま）。システム設定で切り替えてください", error: true)
            }
        }
        // 失敗しても毎回再試行しないよう、1 回試したら忘れる
        state.mirrors = []
    }
    saveState(state)

    if targets.isEmpty {
        logLine("無効化中の外部ディスプレイはありません")
    }
    if !failed.isEmpty {
        logLine("一部復帰できませんでした。ケーブルの抜き差し、またはログアウト→ログインで必ず元に戻ります", error: true)
    }
    logDisplays("実行後")
    return failed.isEmpty
}

@discardableResult
func toggle(force: Bool = false) -> Bool {
    visibleExternals().isEmpty ? turnOn() : turnOff(force: force)
}

func printStatus() {
    print(describeClamshell())
    var ids = displayList(online: true)
    for id in displayList(online: false) where !ids.contains(id) { ids.append(id) }
    let state = loadState()
    for id in state.disabled where !ids.contains(id) { ids.append(id) }
    if ids.isEmpty {
        print("ディスプレイが見つかりません")
        return
    }
    for id in ids {
        print(describe(id))
        print("    " + describeFlags(id))
    }
    if !state.disabled.isEmpty || !state.mirrors.isEmpty {
        print("保存済み: 無効化=\(state.disabled) ミラー="
            + state.mirrors.map { "\($0.display)→\($0.master)" }.joined(separator: ","))
    }
}

// MARK: - メニューバー常駐モード（⌃⌥⌘D で切り替え）

let hotKeyNotification = "local.extdisplay.hotkey"

final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "", action: #selector(toggleAction), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "終了",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(toggleAction),
            name: Notification.Name(hotKeyNotification), object: nil)

        registerHotKey()
        refresh()
    }

    @objc func toggleAction() {
        logLine("menubar: 切り替え要求")
        if !toggle() { NSSound.beep() }
        // 画面構成変更の通知でも更新されるが、念のため少し待って再描画
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    @objc func refresh() {
        let showing = !visibleExternals().isEmpty
        let symbol = showing ? "display.2" : "laptopcomputer"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "外部ディスプレイ") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = showing ? "Ext" : "Int"
        }
        toggleItem.title = showing ? "外部ディスプレイをオフ  ⌃⌥⌘D" : "外部ディスプレイをオン  ⌃⌥⌘D"
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // C コールバックからは通知を投げるだけ（UI 処理はメインの observer 側で行う）
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            NotificationCenter.default.post(name: Notification.Name("local.extdisplay.hotkey"),
                                            object: nil)
            return noErr
        }, 1, &spec, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4558_4450), id: 1)  // 'EXDP'
        // ショートカットを変えたい場合はここ（kVK_ANSI_D と修飾キー）を編集
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_D),
                                         UInt32(cmdKey | optionKey | controlKey),
                                         hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            logLine("menubar: 起動、ホットキー ⌃⌥⌘D を登録しました")
        } else {
            logLine("警告: ホットキー ⌃⌥⌘D を登録できませんでした (OSStatus \(status))", error: true)
        }
    }
}

@MainActor
func runMenuBar() {
    let app = NSApplication.shared
    let controller = MenuBarController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)  // Dock にアイコンを出さない
    app.run()
    withExtendedLifetime(controller) {}
}

// MARK: - エントリポイント

let usage = """
使い方: extdisplay <command> [--force]

  status    ディスプレイの一覧と状態（ミラー構成・蓋の開閉を含む）を表示
  off       外部ディスプレイを無効化（ケーブル接続・充電はそのまま）。ミラー中なら先に解除する
  on        無効化した外部ディスプレイを復帰。off 前がミラーならミラーも戻す
  toggle    off / on を切り替え
  menubar   メニューバーに常駐し、⌃⌥⌘D で切り替え

  --force   内蔵ディスプレイが非表示（蓋閉じ）でも off を実行する
"""

let args = Array(CommandLine.arguments.dropFirst())
let force = args.contains("--force")
let command = args.first { !$0.hasPrefix("-") } ?? ""

switch command {
case "status":
    printStatus()
case "off":
    exit(turnOff(force: force) ? 0 : 1)
case "on":
    exit(turnOn() ? 0 : 1)
case "toggle":
    exit(toggle(force: force) ? 0 : 1)
case "menubar":
    // トップレベルコードは nonisolated 扱いだが、実行はメインスレッドなので MainActor とみなしてよい
    MainActor.assumeIsolated { runMenuBar() }
default:
    print(usage)
    exit(command.isEmpty ? 0 : 64)
}
