import Cocoa

// Defaults are demonstration times. Configuration is local to this process.
func clockSetting(_ value: String?, fallback: (Int, Int)) -> (Int, Int) {
    guard let value else { return fallback }
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
          (0..<24).contains(h), (0..<60).contains(m) else { return fallback }
    return (h, m)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.update() }
    }

    func secondsTo(_ hour: Int, _ minute: Int) -> Int {
        let cal = Calendar.current
        var comp = cal.dateComponents([.year, .month, .day], from: Date())
        comp.hour = hour; comp.minute = minute
        guard let target = cal.date(from: comp) else { return 0 }
        return Int(target.timeIntervalSinceNow)
    }

    func format(_ s: Int) -> String {
        if s <= 0 { return "已开干" }
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h\(m)m" : "\(m)m"
    }

    // 根据剩余时间挑一个应景表情
    // 每档表情越来越夸张，越接近越嚣张
    func eatIcon(_ s: Int) -> String {
        if s <= 0   { return "😋🍗🎊" }   // 已到饭点
        if s < 300  { return "🤤🤤🍗" }   // <5m
        if s < 900  { return "🔥🍗" }     // <15m
        if s < 1800 { return "🍗" }       // <30m
        if s < 3600 { return "🍜" }       // <1h
        if s < 7200 { return "🍱" }       // <2h
        return "😪"                       // 还早
    }
    func offIcon(_ s: Int) -> String {
        if s <= 0   { return "🎉🏖️🍹" }  // 已下班
        if s < 300  { return "🚀🎉" }     // <5m
        if s < 900  { return "🎊🏃" }     // <15m
        if s < 1800 { return "🏃💨" }     // <30m
        if s < 7200 { return "☕" }       // <2h
        if s < 14400 { return "💻" }      // <4h
        return "⛓️"                       // 还早
    }

    @objc func update() {
        let lunch = clockSetting(ProcessInfo.processInfo.environment["LUNCH_AT"], fallback: (12, 0))
        let e = secondsTo(lunch.0, lunch.1)
        let end = clockSetting(ProcessInfo.processInfo.environment["WORK_END_AT"], fallback: (18, 0))
        let o = secondsTo(end.0, end.1)
        let text = "\(eatIcon(e))\(format(e))  \(offIcon(o))\(format(o))"
        let para = NSMutableParagraphStyle()
        para.maximumLineHeight = 18
        para.minimumLineHeight = 18
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuBarFont(ofSize: 13),
            .baselineOffset: 1,
            .paragraphStyle: para
        ])
        statusItem.button?.attributedTitle = attr
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
