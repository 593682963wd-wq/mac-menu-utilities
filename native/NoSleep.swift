import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation

private let appBundleID = "org.example.nosleep-toggle"
private let runtimeDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("org.example.nosleep-toggle-\(getuid())", isDirectory: true)
private let pidFileURL = runtimeDirectoryURL.appendingPathComponent("caffeinate.pid")
private let logFileURL = runtimeDirectoryURL.appendingPathComponent("activity.log")
private let hotKeySignature = fourCharCode("WDNS")
private let hotKeyIDValue: UInt32 = 1

private weak var currentDelegate: AppDelegate?

private func fourCharCode(_ text: String) -> OSType {
    var result: OSType = 0
    for scalar in text.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}

private func ensureRuntimeDirectory() -> Bool {
    let result = mkdir(runtimeDirectoryURL.path, mode_t(0o700))
    guard result == 0 || errno == EEXIST else { return false }
    var info = stat()
    guard lstat(runtimeDirectoryURL.path, &info) == 0,
          info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return false }
    return true
}

private func appendLog(_ message: String) {
    guard ensureRuntimeDirectory() else { return }
    let formatter = ISO8601DateFormatter()
    let line = "[\(formatter.string(from: Date()))] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let descriptor = open(logFileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { return }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == getuid(), info.st_nlink == 1 else {
        close(descriptor)
        return
    }
    guard fchmod(descriptor, mode_t(0o600)) == 0 else { close(descriptor); return }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    handle.write(data)
    try? handle.close()
}

private func processOutput(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return ""
    }
}

private func readManagedPid() -> pid_t? {
    guard ensureRuntimeDirectory() else { return nil }
    guard let raw = try? String(contentsOf: pidFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          let intValue = Int32(raw) else {
        return nil
    }
    return pid_t(intValue)
}

private func writeManagedPid(_ pid: pid_t) {
    guard ensureRuntimeDirectory() else { return }
    try? "\(pid)\n".write(to: pidFileURL, atomically: true, encoding: .utf8)
}

private func clearManagedPid() {
    guard ensureRuntimeDirectory() else { return }
    try? FileManager.default.removeItem(at: pidFileURL)
}

private func processIsAlive(_ pid: pid_t?) -> Bool {
    guard let pid else { return false }
    if Darwin.kill(pid, 0) == 0 {
        return true
    }
    return errno == EPERM
}

private func isManagedCaffeinatePid(_ pid: pid_t) -> Bool {
    let command = processOutput("/bin/ps", ["-p", "\(pid)", "-o", "command="])
    return command.contains("/usr/bin/caffeinate") || command.contains("caffeinate -d -i -m -s")
}

private func terminateManagedPid(_ pid: pid_t) {
    guard processIsAlive(pid), isManagedCaffeinatePid(pid) else { return }
    Darwin.kill(pid, SIGTERM)
    usleep(250_000)
    if processIsAlive(pid) {
        Darwin.kill(pid, SIGKILL)
    }
}

private func hotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ eventRef: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let eventRef else { return noErr }
    var hotKeyID = EventHotKeyID(signature: 0, id: 0)
    let status = withUnsafeMutablePointer(to: &hotKeyID) { pointer in
        GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            pointer
        )
    }
    if status == noErr,
       hotKeyID.signature == hotKeySignature,
       hotKeyID.id == hotKeyIDValue {
        DispatchQueue.main.async {
            currentDelegate?.toggleNoSleep(source: "hotkey")
        }
    }
    return noErr
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var caffeinateProcess: Process?
    private var monitorTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var noSleepEnabled = true
    private var managesAssertion = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        currentDelegate = self

        if anotherInstanceIsRunning() {
            appendLog("Another instance is already running; exiting pid=\(ProcessInfo.processInfo.processIdentifier)")
            NSApp.terminate(nil)
            return
        }

        managesAssertion = true
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        registerHotKey()
        startNoSleep()
        render()

        monitorTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.keepAssertionHealthy()
        }

        appendLog("Launched pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard managesAssertion else { return }
        monitorTimer?.invalidate()
        monitorTimer = nil
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        stopNoSleep()
        appendLog("Terminated")
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            toggleNoSleep(source: "status")
            return
        }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            toggleNoSleep(source: "status")
        }
    }

    @objc private func toggleFromMenu() {
        toggleNoSleep(source: "menu")
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    func toggleNoSleep(source: String) {
        if noSleepEnabled {
            stopNoSleep()
        } else {
            startNoSleep()
        }
        appendLog("Toggle source=\(source) enabled=\(noSleepEnabled)")
        render()
    }

    private func startNoSleep() {
        noSleepEnabled = true
        if managedCaffeinateIsRunning() {
            render()
            return
        }

        if let stalePid = readManagedPid(), processIsAlive(stalePid), isManagedCaffeinatePid(stalePid) {
            terminateManagedPid(stalePid)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-d", "-i", "-m", "-s"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.terminationHandler = { [weak self, weak process] finishedProcess in
            DispatchQueue.main.async {
                guard let self else { return }
                if let process, self.caffeinateProcess === process {
                    self.caffeinateProcess = nil
                }
                appendLog("caffeinate exited status=\(finishedProcess.terminationStatus)")
                self.render()
            }
        }

        do {
            try process.run()
            caffeinateProcess = process
            writeManagedPid(process.processIdentifier)
            appendLog("Started caffeinate pid=\(process.processIdentifier)")
        } catch {
            noSleepEnabled = false
            appendLog("Failed to start caffeinate: \(error.localizedDescription)")
        }
        render()
    }

    private func stopNoSleep() {
        noSleepEnabled = false

        if let process = caffeinateProcess, process.isRunning {
            process.terminate()
            usleep(250_000)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        caffeinateProcess = nil

        if let pid = readManagedPid() {
            terminateManagedPid(pid)
        }
        clearManagedPid()
        render()
    }

    private func keepAssertionHealthy() {
        guard noSleepEnabled else { return }
        if !managedCaffeinateIsRunning() {
            appendLog("caffeinate missing; restarting")
            startNoSleep()
        }
    }

    private func managedCaffeinateIsRunning() -> Bool {
        if let process = caffeinateProcess, process.isRunning {
            return true
        }
        if let pid = readManagedPid(), processIsAlive(pid), isManagedCaffeinatePid(pid) {
            return true
        }
        clearManagedPid()
        return false
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        button.title = noSleepEnabled ? "不休眠" : "可休眠"
        button.toolTip = noSleepEnabled
            ? "正在阻止系统休眠；左键点击关闭，快捷键 Control+Option+Command+N"
            : "已允许系统休眠；左键点击开启，快捷键 Control+Option+Command+N"
    }

    private func showMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(
            title: noSleepEnabled ? "状态：正在不休眠" : "状态：允许休眠",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

        let toggle = NSMenuItem(
            title: noSleepEnabled ? "关闭不休眠" : "开启不休眠",
            action: #selector(toggleFromMenu),
            keyEquivalent: "n"
        )
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let hint = NSMenuItem(
            title: "快捷键：⌃⌥⌘N",
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)

        let log = NSMenuItem(
            title: "日志：\(logFileURL.path)",
            action: nil,
            keyEquivalent: ""
        )
        log.isEnabled = false
        menu.addItem(log)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func registerHotKey() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventSpec,
            nil,
            nil
        )

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyIDValue)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_N),
            UInt32(cmdKey | optionKey | controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        appendLog("Hotkey handler=\(handlerStatus) register=\(registerStatus)")
    }

    private func anotherInstanceIsRunning() -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? appBundleID
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != pid }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
