import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

// Users may replace the example daily schedule with comma-separated HH:MM times.
func breakTimes(_ value: String?) -> [(Int, Int)] {
    let demo = [(10, 0), (15, 0)]
    guard let value else { return demo }
    let fields = value.split(separator: ",", omittingEmptySubsequences: false)
    var times: [(Int, Int)] = []
    for field in fields {
        let parts = field.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return demo }
        times.append((h, m))
    }
    return times.isEmpty ? demo : times.sorted { $0 < $1 }
}

let breakSchedule = breakTimes(ProcessInfo.processInfo.environment["BREAK_TIMES"])
var customNext: Date?

func todayAt(_ hm: (Int,Int), base: Date = Date()) -> Date {
    Calendar.current.date(bySettingHour: hm.0, minute: hm.1, second: 0, of: base)!
}

func nextBreakTime(from now: Date) -> Date {
    if let c = customNext, c > now { return c }
    for hm in breakSchedule {
        let t = todayAt(hm, base: now)
        if t > now { return t }
    }
    // 今天的都过了 → 明天第一个
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
    return todayAt(breakSchedule[0], base: tomorrow)
}

func fmt(_ s: Int) -> String {
    let h = s/3600, m = (s%3600)/60, sec = s%60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                 : String(format: "%02d:%02d", m, sec)
}

func tick() {
    let now = Date()
    if let c = customNext, c <= now { customNext = nil }
    let t = nextBreakTime(from: now)
    let remain = max(0, Int(t.timeIntervalSince(now)))
    statusItem.button?.title = "⏱ \(fmt(remain))"
}

class Handler: NSObject {
    @objc func onClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        // 左键：重置为 一小时
        customNext = Date().addingTimeInterval(60 * 60)
        tick()
    }
    @objc func quit() { NSApp.terminate(nil) }
}
let handler = Handler()

func buildMenu() -> NSMenu {
    let m = NSMenu()
    let item = NSMenuItem(title: "退出", action: #selector(Handler.quit), keyEquivalent: "q")
    item.target = handler
    m.addItem(item)
    return m
}

if let btn = statusItem.button {
    btn.target = handler
    btn.action = #selector(Handler.onClick)
    btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
}

tick()
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in tick() }
app.run()
