// ClashQuickToggle v8
// 菜单栏单个 status item，里面两枚药丸：左 VPN（系统代理）右 TUN（虚拟网卡）。
//
// 写入路径（最终方案）：
//   1. 用户在 Clash Verge 自身的"全局快捷键"设置里给 toggle_system_proxy 和 toggle_tun_mode
//      绑定快捷键（任意组合，例如 ⌃⌥⌘V / ⌃⌥⌘T）。配置存在 verge.yaml 的 hotkeys 字段里。
//   2. ClashQuickToggle 启动时（以及 verge.yaml 变化时）解析这些快捷键。
//   3. 按钮点击 → 通过 CGEvent 模拟一次键盘按键 → Clash 自身的全局快捷键监听器收到 →
//      调用 Clash 内部的 toggle 函数 → Clash UI / verge.yaml / 底层代理状态全部同步切换。
//
// 读取路径：FSEvents 监听 verge.yaml + 1s 兜底轮询 → render 永远反映真实状态。
// 乐观更新：点击立即变色；多次 readState 校验；如果没真切到，按钮自动回滚。
//
// 不再依赖 AX press（Tauri 不响应），不再依赖鼠标模拟。

import AppKit
import ApplicationServices
import Foundation
import Carbon.HIToolbox  // for kVK_* constants

// 仅显式参数/环境配置；不扫描用户应用目录，不默认生成诊断日志。
private let kVergeYaml: String = {
    let args=CommandLine.arguments
    if let index=args.firstIndex(of:"--config"), index+1<args.count {return args[index+1]}
    return ProcessInfo.processInfo.environment["PROXY_CONFIG_PATH"] ?? ""
}()
private func qlog(_ msg: String) {
    guard let path=ProcessInfo.processInfo.environment["PROXY_LOG_PATH"], !path.isEmpty else {return}
    let line="[\(Date())] \(msg)\n"
    guard let data=line.data(using:.utf8) else {return}
    if let handle=FileHandle(forWritingAtPath:path) {
        handle.seekToEndOfFile();handle.write(data);try? handle.close()
    } else {try? data.write(to:URL(fileURLWithPath:path))}
}

private let kVPNColor = NSColor.systemBlue
private let kTUNColor = NSColor.systemIndigo

struct Hotkey {
    var modifiers: CGEventFlags
    var virtualKey: CGKeyCode
    var raw: String
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var pollTimer: Timer?
    var fileWatcher: DispatchSourceFileSystemObject?
    var fileWatchFD: CInt = -1
    var splitX: CGFloat = 0
    var clickMonitor: Any?

    var sysProxy: Bool = false { didSet { if oldValue != sysProxy { render() } } }
    var tun: Bool = false { didSet { if oldValue != tun { render() } } }

    var vpnHotkey: Hotkey?
    var tunHotkey: Hotkey?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        qlog("App launched v8 hotkey, pid=\(ProcessInfo.processInfo.processIdentifier)")
        guard !kVergeYaml.isEmpty, (kVergeYaml as NSString).isAbsolutePath else {
            // 缺显式配置即退出；不读取设置、不创建菜单、不申请辅助功能权限。
            NSApp.terminate(nil); return
        }
        ensureAccessibilityPermission()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let original = statusItem.button {
            original.imagePosition = .imageOnly
            original.target = self
            original.action = #selector(handleStatusItemClick(_:))
            original.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self,
                  let button = self.statusItem.button,
                  let bw = button.window else { return event }
            if event.window === bw {
                self.dispatchClick(event)
                return nil
            }
            return event
        }

        readState()
        loadHotkeys()
        render()

        startVergeYamlWatcher()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshConfiguration()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        pollTimer?.invalidate(); pollTimer = nil
        fileWatcher?.cancel(); fileWatcher = nil
        if fileWatchFD >= 0 { close(fileWatchFD); fileWatchFD = -1 }
    }

    private func ensureAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        qlog("AX trusted=\(trusted)")
    }

    // MARK: - 状态读取

    func readState() {
        guard let txt = try? String(contentsOfFile: kVergeYaml, encoding: .utf8) else { return }
        var sp: Bool? = nil
        var t: Bool? = nil
        for raw in txt.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = parts[1].lowercased()
            guard value == "true" || value == "false" else { continue }
            if parts[0] == "enable_system_proxy" {
                sp = value == "true"
            } else if parts[0] == "enable_tun_mode" {
                t = value == "true"
            }
        }
        let oldSp = sysProxy, oldT = tun
        if let sp { sysProxy = sp }
        if let t { tun = t }
        if oldSp != sysProxy || oldT != tun {
            qlog("readState changed: VPN \(oldSp)->\(sysProxy)  TUN \(oldT)->\(tun)")
        }
    }

    func refreshConfiguration() {
        let oldVPN = vpnHotkey?.raw, oldTUN = tunHotkey?.raw
        readState()
        loadHotkeys()
        if oldVPN != vpnHotkey?.raw || oldTUN != tunHotkey?.raw { render() }
    }

    // MARK: - 解析 verge.yaml 的 hotkeys 字段

    /// hotkeys 字段示例（Clash Verge Rev 标准格式）：
    /// hotkeys:
    ///   - toggle_system_proxy,Ctrl+Shift+P
    ///   - toggle_tun_mode,Ctrl+Shift+T
    func loadHotkeys() {
        vpnHotkey = nil
        tunHotkey = nil
        guard let txt = try? String(contentsOfFile: kVergeYaml, encoding: .utf8) else { return }
        var inHotkeys = false
        for raw in txt.split(separator: "\n", omittingEmptySubsequences: false) {
            let rawLine = String(raw)
            let leading = rawLine.prefix(while: { $0 == " " || $0 == "\t" })
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // YAML 允许 list items 与父 key 同列缩进（无前导空格的 "- xxx"），
            // 因此判断是否退出 hotkeys 段时，要把 "- xxx" 也当作仍在列表内。
            if leading.isEmpty && !trimmed.hasPrefix("-") {
                if trimmed.hasPrefix("hotkeys:") {
                    inHotkeys = true
                } else if !trimmed.isEmpty {
                    inHotkeys = false
                }
                continue
            }
            guard inHotkeys, trimmed.hasPrefix("-") else { continue }
            // 取 - 后内容，去掉可能的引号
            var entry = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if entry.hasPrefix("\"") && entry.hasSuffix("\"") { entry = String(entry.dropFirst().dropLast()) }
            if entry.hasPrefix("'") && entry.hasSuffix("'") { entry = String(entry.dropFirst().dropLast()) }
            let pieces = entry.split(separator: ",", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2 else { continue }
            let action = pieces[0]
            let accel = pieces[1]
            if action == "toggle_system_proxy" {
                vpnHotkey = parseAccelerator(accel)
                qlog("hotkey VPN action='\(action)' accel='\(accel)' parsed=\(vpnHotkey != nil)")
            } else if action == "toggle_tun_mode" {
                tunHotkey = parseAccelerator(accel)
                qlog("hotkey TUN action='\(action)' accel='\(accel)' parsed=\(tunHotkey != nil)")
            }
        }
        if vpnHotkey == nil { qlog("hotkey VPN not configured in verge.yaml") }
        if tunHotkey == nil { qlog("hotkey TUN not configured in verge.yaml") }
    }

    private func parseAccelerator(_ accel: String) -> Hotkey? {
        let parts = accel.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        var mods: CGEventFlags = []
        var keyName: String? = nil
        for p in parts {
            switch p.lowercased() {
            case "cmd", "command", "meta", "super", "commandorcontrol":
                mods.insert(.maskCommand)
            case "ctrl", "control":
                mods.insert(.maskControl)
            case "alt", "option", "opt":
                mods.insert(.maskAlternate)
            case "shift":
                mods.insert(.maskShift)
            default:
                keyName = p
            }
        }
        guard let n = keyName, let vk = virtualKeyForName(n) else { return nil }
        return Hotkey(modifiers: mods, virtualKey: vk, raw: accel)
    }

    private func virtualKeyForName(_ name: String) -> CGKeyCode? {
        let map: [String: Int] = [
            "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
            "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
            "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
            "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
            "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
            "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
            "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4,
            "F5": kVK_F5, "F6": kVK_F6, "F7": kVK_F7, "F8": kVK_F8,
            "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12,
            "SPACE": kVK_Space, "ENTER": kVK_Return, "RETURN": kVK_Return,
            "TAB": kVK_Tab, "ESC": kVK_Escape, "ESCAPE": kVK_Escape,
            "MINUS": kVK_ANSI_Minus, "EQUAL": kVK_ANSI_Equal,
            "LEFTBRACKET": kVK_ANSI_LeftBracket, "RIGHTBRACKET": kVK_ANSI_RightBracket,
            "SEMICOLON": kVK_ANSI_Semicolon, "QUOTE": kVK_ANSI_Quote,
            "COMMA": kVK_ANSI_Comma, "PERIOD": kVK_ANSI_Period, "SLASH": kVK_ANSI_Slash,
            "BACKSLASH": kVK_ANSI_Backslash, "GRAVE": kVK_ANSI_Grave,
        ]
        if let v = map[name.uppercased()] { return CGKeyCode(v) }
        return nil
    }

    private func sendHotkey(_ hk: Hotkey, kind: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: hk.virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: hk.virtualKey, keyDown: false) else {
            qlog("HK[\(kind)] event create failed")
            return
        }
        down.flags = hk.modifiers
        up.flags = hk.modifiers
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        qlog("HK[\(kind)] sent '\(hk.raw)'")
    }

    // MARK: - FSEvents 监听

    private func startVergeYamlWatcher() {
        let dir = (kVergeYaml as NSString).deletingLastPathComponent
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { qlog("FSWATCH ERR open dir=\(dir)"); return }
        fileWatchFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: DispatchQueue.main
        )
        src.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.readState()
                self?.loadHotkeys()
            }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fileWatchFD, fd >= 0 { close(fd); self?.fileWatchFD = -1 }
        }
        src.resume()
        fileWatcher = src
        qlog("FSWATCH on \(dir)")
    }

    // MARK: - 渲染

    func render() {
        let pillFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let labelL = "VPN"
        let labelR = "TUN"
        let attrsL: [NSAttributedString.Key: Any] = [
            .font: pillFont,
            .foregroundColor: sysProxy ? NSColor.white : NSColor.secondaryLabelColor,
            .kern: 0.4,
        ]
        let attrsR: [NSAttributedString.Key: Any] = [
            .font: pillFont,
            .foregroundColor: tun ? NSColor.white : NSColor.secondaryLabelColor,
            .kern: 0.4,
        ]
        let szL = (labelL as NSString).size(withAttributes: attrsL)
        let szR = (labelR as NSString).size(withAttributes: attrsR)

        let hPad: CGFloat = 7
        let vPad: CGFloat = 2.5
        let pillH = ceil(max(szL.height, szR.height)) + vPad * 2
        let pillWL = ceil(szL.width) + hPad * 2
        let pillWR = ceil(szR.width) + hPad * 2

        let gap: CGFloat = 1.5
        let outerPad: CGFloat = 2
        let totalW = outerPad + pillWL + gap + pillWR + outerPad
        let totalH = outerPad + pillH + outerPad
        splitX = outerPad + pillWL + gap / 2

        let img = NSImage(size: NSSize(width: totalW, height: totalH), flipped: false) { rect in
            let containerInset = rect.insetBy(dx: 0.5, dy: 0.5)
            let containerRadius = containerInset.height / 2
            let container = NSBezierPath(roundedRect: containerInset, xRadius: containerRadius, yRadius: containerRadius)
            NSColor.tertiaryLabelColor.withAlphaComponent(0.16).setFill()
            container.fill()
            NSColor.tertiaryLabelColor.withAlphaComponent(0.32).setStroke()
            container.lineWidth = 0.6
            container.stroke()

            let leftRect = NSRect(x: outerPad, y: outerPad, width: pillWL, height: pillH)
            self.drawPill(in: leftRect, on: self.sysProxy, color: kVPNColor)
            (labelL as NSString).draw(at: NSPoint(x: leftRect.minX + hPad, y: leftRect.minY + vPad), withAttributes: attrsL)

            let rightRect = NSRect(x: outerPad + pillWL + gap, y: outerPad, width: pillWR, height: pillH)
            self.drawPill(in: rightRect, on: self.tun, color: kTUNColor)
            (labelR as NSString).draw(at: NSPoint(x: rightRect.minX + hPad, y: rightRect.minY + vPad), withAttributes: attrsR)
            return true
        }

        img.isTemplate = false
        statusItem.button?.image = img
        statusItem.length = totalW + 2

        let vpnTip = vpnHotkey?.raw ?? "未配置"
        let tunTip = tunHotkey?.raw ?? "未配置"
        statusItem.button?.toolTip =
            "VPN(系统代理): \(sysProxy ? "开" : "关")  TUN(虚拟网卡): \(tun ? "开" : "关")\n"
            + "快捷键 VPN=\(vpnTip)  TUN=\(tunTip)\n"
            + "（在 Clash Verge → 设置 → 快捷键 里配置 toggle_system_proxy / toggle_tun_mode）"
    }

    private func drawPill(in rect: NSRect, on: Bool, color: NSColor) {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        let radius = r.height / 2
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        if on {
            let grad = NSGradient(colors: [
                color.blended(withFraction: 0.14, of: .white) ?? color,
                color,
            ])
            grad?.draw(in: path, angle: -90)
            NSColor.white.withAlphaComponent(0.28).setStroke()
            path.lineWidth = 0.8
            path.stroke()
        }
    }

    // MARK: - 切换

    @objc func toggleVPN() {
        qlog("toggleVPN tap (current sysProxy=\(sysProxy))")
        guard let hk = vpnHotkey else {
            qlog("toggleVPN ABORT: no hotkey configured")
            notifyMissingHotkey(which: "VPN(系统代理)")
            return
        }
        sysProxy.toggle()  // 乐观更新
        sendHotkey(hk, kind: "vpn")
        scheduleRecheck()
    }

    @objc func toggleTUN() {
        qlog("toggleTUN tap (current tun=\(tun))")
        guard let hk = tunHotkey else {
            qlog("toggleTUN ABORT: no hotkey configured")
            notifyMissingHotkey(which: "TUN(虚拟网卡)")
            return
        }
        tun.toggle()
        sendHotkey(hk, kind: "tun")
        scheduleRecheck()
    }

    private func notifyMissingHotkey(which: String) {
        statusItem.button?.toolTip =
            "未配置\(which)的全局快捷键。\n请打开 Clash Verge → 设置 → 快捷键，\n"
            + "给 toggle_system_proxy 和 toggle_tun_mode 各分配一个。"
        readState()
    }

    private func scheduleRecheck() {
        for delay: TimeInterval in [0.4, 0.9, 1.6, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.readState()
            }
        }
    }

    // MARK: - 上下文菜单

    func showContextMenu() {
        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "刷新状态 / 重读快捷键", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "打开 Clash Verge", action: #selector(openClash), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let info = NSMenuItem(
            title: "VPN=\(vpnHotkey?.raw ?? "未配置")  TUN=\(tunHotkey?.raw ?? "未配置")",
            action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 ClashQuickToggle", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func refresh() { readState(); loadHotkeys(); render() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func openClash() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "Clash Verge"]
        try? task.run()
    }

    // MARK: - 点击分发

    @objc func handleStatusItemClick(_ sender: Any?) {
        if let e = NSApp.currentEvent { dispatchClick(e); return }
        if let button = statusItem.button, let win = button.window {
            let g = NSEvent.mouseLocation
            let p = button.convert(win.convertPoint(fromScreen: g), from: nil)
            if p.x <= splitX { toggleVPN() } else { toggleTUN() }
        }
    }

    func dispatchClick(_ event: NSEvent) {
        let isRight = event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if isRight { showContextMenu(); return }
        guard let button = statusItem.button else { return }
        let p = button.convert(event.locationInWindow, from: nil)
        if p.x <= splitX { toggleVPN() } else { toggleTUN() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
