// Pulse for Claude — a native macOS menu-bar app that tracks your Claude usage.
//
// A circular ring gauge + % lives in the menu bar; clicking it drops a native
// menu with every quota bucket (5-hour, weekly, Sonnet, usage credits) as a
// percentage-used bar with a reset countdown, plus actions (Icon Style, Icon
// Shows, Launch at Login, Refresh Now, Open Usage Settings, About, Quit).
// Refreshes every minute.
//
// Data source: the same undocumented endpoint Claude Code itself uses —
//   GET https://api.anthropic.com/api/oauth/usage
// authenticated with your local Claude Code OAuth token (~/.claude/.credentials
// .json, or the login Keychain). Nothing leaves your Mac but that request.
//
// Build it yourself with ./build.command — you compile it, nothing is downloaded.

import Cocoa
import ServiceManagement

// MARK: - Theme ---------------------------------------------------------------

enum Theme {
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
    }
    static let accent = rgb(0xD9, 0x77, 0x57)
    static let green  = rgb(0x5B, 0xB9, 0x8C)
    static let amber  = rgb(0xE5, 0xB8, 0x4B)
    static let red    = rgb(0xF0, 0x59, 0x4C)
    static func color(_ pct: Int) -> NSColor {
        if pct >= 80 { return red }
        if pct >= 50 { return amber }
        return green
    }
}

// MARK: - Model ---------------------------------------------------------------

struct Quota: Codable { let utilization: Double?; let resets_at: String? }
struct Extra: Codable {
    let is_enabled: Bool?
    let used_credits: Double?
    let monthly_limit: Double?
    let currency: String?
    let utilization: Double?
}
struct Usage: Codable {
    let five_hour: Quota?
    let seven_day: Quota?
    let seven_day_opus: Quota?
    let seven_day_sonnet: Quota?
    let extra_usage: Extra?

    // True only if the payload carries real quota numbers. An error/empty body
    // (e.g. a 429 rate-limit response) decodes to all-nil and must NOT be
    // treated as data, cached, or allowed to blank the menu bar.
    var hasData: Bool {
        five_hour?.utilization != nil
            || seven_day?.utilization != nil
            || seven_day_sonnet?.utilization != nil
            || seven_day_opus?.utilization != nil
    }
}

func pctOf(_ q: Quota?) -> Int? {
    guard let u = q?.utilization, !u.isNaN else { return nil }
    return max(0, min(100, Int(u.rounded())))
}

// MARK: - Time helpers --------------------------------------------------------

enum Clock {
    static func parse(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: iso) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: iso)
    }
    // "resets in 3h 33m", "resets in 3d 3h", "resets now", or "".
    static func resetsIn(_ iso: String?) -> String {
        guard let t = parse(iso) else { return "" }
        var s = Int(t.timeIntervalSinceNow)
        if s <= 0 { return "resets now" }
        let d = s/86400; s -= d*86400
        let h = s/3600;  s -= h*3600
        let m = s/60
        let r = d > 0 ? "\(d)d \(h)h" : (h > 0 ? "\(h)h \(m)m" : (m > 0 ? "\(m)m" : "<1m"))
        return "resets in \(r)"
    }
    static func clockString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: date)
    }
}

// MARK: - Token + fetch -------------------------------------------------------

enum Net {
    static func loadToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cred = home.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: cred),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = obj["claudeAiOauth"] as? [String: Any],
           let t = oauth["accessToken"] as? String, !t.isEmpty { return t }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        // Watchdog: if `security` blocks (e.g. an unanswered Keychain prompt),
        // don't wedge this worker thread forever — give up after 4s.
        let deadline = Date().addingTimeInterval(4)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return nil }
        if let d = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let oauth = obj["claudeAiOauth"] as? [String: Any], let t = oauth["accessToken"] as? String { return t }
            if let t = obj["accessToken"] as? String { return t }
        }
        return raw
    }

    static func fetchUsage() -> Usage? {
        guard let tok = loadToken() else { return nil }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var result: Usage? = nil
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, let data else { return }
            if let u = try? JSONDecoder().decode(Usage.self, from: data), u.hasData { result = u }
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        return result   // nil on non-200 / empty / timeout → caller keeps last good values
    }
}

// MARK: - Custom views (shared by menu rows and the preview render) ------------

let ROW_W: CGFloat = 340

// When rendering the offscreen preview we can't rely on the menu's adaptive
// (dark/light) appearance, so swap semantic colors for explicit light ones.
var PREVIEW = false
func inkColor()       -> NSColor { PREVIEW ? .white : .labelColor }
func secondaryInk()   -> NSColor { PREVIEW ? NSColor.white.withAlphaComponent(0.50) : .secondaryLabelColor }
func tertiaryInk()    -> NSColor { PREVIEW ? NSColor.white.withAlphaComponent(0.32) : .tertiaryLabelColor }

final class BarView: NSView {
    var pct: Int = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        let r = bounds.height/2
        let track = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
        NSColor.white.withAlphaComponent(0.16).setFill(); track.fill()
        let p = max(0, min(100, pct))
        guard p > 0 else { return }
        let w = max(bounds.height, bounds.width * CGFloat(p)/100)
        let fp = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: r, yRadius: r)
        Theme.color(pct).setFill(); fp.fill()
    }
}

func makeLabel(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, align: NSTextAlignment = .left) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = NSFont.systemFont(ofSize: size, weight: weight)
    t.textColor = color
    t.alignment = align
    t.backgroundColor = .clear
    t.isBordered = false
    return t
}

final class QuotaRowView: NSView {
    override var isFlipped: Bool { true }
    init(title: String, pct: Int?, sub: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: ROW_W, height: 58))
        let lp: CGFloat = 20, rp: CGFloat = 16
        let titleL = makeLabel(title, size: 13, weight: .regular, color: inkColor())
        titleL.frame = NSRect(x: lp, y: 7, width: ROW_W - lp - rp - 70, height: 18)
        addSubview(titleL)

        let pctL = makeLabel(pct.map { "\($0)%" } ?? "—", size: 13, weight: .bold, color: inkColor(), align: .right)
        pctL.frame = NSRect(x: ROW_W - rp - 70, y: 7, width: 70, height: 18)
        addSubview(pctL)

        let bar = BarView(frame: NSRect(x: lp, y: 30, width: ROW_W - lp - rp, height: 6))
        bar.pct = pct ?? 0
        addSubview(bar)

        if !sub.isEmpty {
            let subL = makeLabel(sub, size: 11, weight: .regular, color: secondaryInk())
            subL.frame = NSRect(x: lp, y: 40, width: ROW_W - lp - rp, height: 15)
            addSubview(subL)
        }
    }
    required init?(coder: NSCoder) { nil }
}

final class HeaderView: NSView {
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: ROW_W, height: 30))
        let l = makeLabel("Pulse for Claude · by Dexter", size: 13, weight: .semibold, color: secondaryInk())
        l.frame = NSRect(x: 20, y: 8, width: ROW_W - 36, height: 18)
        addSubview(l)
    }
    required init?(coder: NSCoder) { nil }
}

// MARK: - App delegate --------------------------------------------------------

enum IconStyle: String { case ring, dot, number }
enum IconShows: String { case fiveHour, weekly }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var usage: Usage?
    var lastUpdated: Date?
    var timer: Timer?
    private var isRefreshing = false   // main-thread only; prevents overlapping fetches

    var iconStyle: IconStyle {
        get { IconStyle(rawValue: UserDefaults.standard.string(forKey: "iconStyle") ?? "") ?? .ring }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "iconStyle"); rebuildIcon() }
    }
    var iconShows: IconShows {
        get { IconShows(rawValue: UserDefaults.standard.string(forKey: "iconShows") ?? "") ?? .fiveHour }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "iconShows"); rebuildIcon() }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        loadCache()        // render last-known values instantly so it's never blank
        rebuildIcon()
        refresh()
        // Use a common-mode timer so refreshes keep firing even while the menu
        // is open (a .default-mode scheduledTimer pauses during menu tracking).
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: data
    func refresh() {
        if isRefreshing { return }   // never stack overlapping network calls
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let u = Net.fetchUsage()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                if let u {                       // only replace on success — never blank
                    self.usage = u
                    self.lastUpdated = Date()
                    self.saveCache(u)
                }
                self.rebuildIcon()
            }
        }
    }

    // MARK: cache — survives quits/relaunches so the menu bar shows instantly
    private func loadCache() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "cachedUsage"),
           let u = try? JSONDecoder().decode(Usage.self, from: data), u.hasData {
            usage = u
            lastUpdated = d.object(forKey: "cachedAt") as? Date
        }
    }
    private func saveCache(_ u: Usage) {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(u) {
            d.set(data, forKey: "cachedUsage")
            d.set(Date(), forKey: "cachedAt")
        }
    }

    // MARK: menu-bar icon
    func rebuildIcon() {
        guard let btn = statusItem.button else { return }
        let q = (iconShows == .fiveHour) ? usage?.five_hour : usage?.seven_day
        let pct = pctOf(q)
        let p = pct ?? 0
        btn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        switch iconStyle {
        case .number:
            btn.image = nil
            btn.imagePosition = .noImage
            btn.title = pct.map { " \($0)%" } ?? " …"
        case .dot:
            btn.image = dotImage(Theme.color(p))
            btn.imagePosition = .imageLeft
            btn.title = pct.map { " \($0)%" } ?? " …"
        case .ring:
            btn.image = ringImage(pct: p, color: Theme.color(p))
            btn.imagePosition = .imageLeft
            btn.title = pct.map { " \($0)%" } ?? " …"
        }
    }

    func ringImage(pct: Int, color: NSColor) -> NSImage {
        let s: CGFloat = 16
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        let lw: CGFloat = 2.4
        let center = NSPoint(x: s/2, y: s/2)
        let radius = s/2 - lw/2 - 0.5
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lw
        NSColor.tertiaryLabelColor.setStroke(); track.stroke()
        if pct > 0 {
            let start: CGFloat = 90
            let end = 90 - 360 * CGFloat(min(100, pct)) / 100
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            arc.lineWidth = lw
            arc.lineCapStyle = .round
            color.setStroke(); arc.stroke()
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    func dotImage(_ color: NSColor) -> NSImage {
        let s: CGFloat = 12
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: s-2, height: s-2)).fill()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    // Kick a background refresh when the menu opens, so the next glance is fresh.
    func menuWillOpen(_ menu: NSMenu) { refresh() }

    // MARK: menu construction
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(); header.view = HeaderView(); menu.addItem(header)

        addQuota(menu, "5-hour limit", usage?.five_hour)
        addQuota(menu, "Weekly · all models", usage?.seven_day)
        if let opus = usage?.seven_day_opus, opus.utilization != nil {
            addQuota(menu, "Weekly · Opus only", opus)
        }
        addQuota(menu, "Weekly · Sonnet only", usage?.seven_day_sonnet)
        addCredits(menu, usage?.extra_usage)

        menu.addItem(.separator())
        menu.addItem(action("Track API Spend (optional)…", #selector(trackSpend)))
        menu.addItem(.separator())
        menu.addItem(iconStyleMenu())
        menu.addItem(iconShowsMenu())
        let login = action("Launch at Login", #selector(toggleLogin))
        login.state = loginEnabled() ? .on : .off
        menu.addItem(login)
        let refreshItem = action("Refresh Now", #selector(refreshNow)); refreshItem.keyEquivalent = "r"
        menu.addItem(refreshItem)
        menu.addItem(action("Open Usage Settings on claude.ai", #selector(openUsage)))
        menu.addItem(.separator())
        let updated = NSMenuItem(title: updatedString(), action: nil, keyEquivalent: "")
        updated.isEnabled = false
        menu.addItem(updated)
        menu.addItem(action("About Pulse for Claude by Dexter", #selector(about)))
        let quit = action("Quit Pulse for Claude by Dexter", #selector(quitApp)); quit.keyEquivalent = "q"
        quit.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    func addQuota(_ menu: NSMenu, _ title: String, _ q: Quota?) {
        let item = NSMenuItem()
        item.view = QuotaRowView(title: title, pct: pctOf(q), sub: Clock.resetsIn(q?.resets_at))
        menu.addItem(item)
    }

    func addCredits(_ menu: NSMenu, _ e: Extra?) {
        // Only show real numbers when extra usage is actually enabled AND the
        // API gives a real monthly limit. Otherwise say so — never invent a cap.
        let sub: String
        let pct: Int?
        if (e?.is_enabled ?? false), let limit = e?.monthly_limit {
            let used = e?.used_credits ?? 0
            let sym = (e?.currency ?? "USD") == "USD" ? "$" : ""
            sub = String(format: "%@%.2f of %@%.2f extra usage", sym, used, sym, limit)
            pct = (e?.utilization).flatMap { $0.isNaN ? nil : max(0, min(100, Int($0.rounded()))) } ?? 0
        } else {
            sub = "not enabled"
            pct = nil
        }
        let item = NSMenuItem()
        item.view = QuotaRowView(title: "Usage credits", pct: pct, sub: sub)
        menu.addItem(item)
    }

    func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self; i.isEnabled = true
        return i
    }

    func iconStyleMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Icon Style", action: nil, keyEquivalent: ""); parent.isEnabled = true
        let sub = NSMenu()
        for (t, v) in [("Ring", IconStyle.ring), ("Dot", .dot), ("Number only", .number)] {
            let mi = NSMenuItem(title: t, action: #selector(setStyle(_:)), keyEquivalent: "")
            mi.target = self; mi.isEnabled = true; mi.representedObject = v.rawValue
            mi.state = (iconStyle == v) ? .on : .off
            sub.addItem(mi)
        }
        parent.submenu = sub
        return parent
    }

    func iconShowsMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Icon Shows", action: nil, keyEquivalent: ""); parent.isEnabled = true
        let sub = NSMenu()
        for (t, v) in [("5-hour limit", IconShows.fiveHour), ("Weekly · all models", .weekly)] {
            let mi = NSMenuItem(title: t, action: #selector(setShows(_:)), keyEquivalent: "")
            mi.target = self; mi.isEnabled = true; mi.representedObject = v.rawValue
            mi.state = (iconShows == v) ? .on : .off
            sub.addItem(mi)
        }
        parent.submenu = sub
        return parent
    }

    func updatedString() -> String {
        if let u = lastUpdated { return "Updated \(Clock.clockString(u)) · refreshes every minute" }
        return "Updating… · refreshes every minute"
    }

    // MARK: actions
    @objc func setStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let v = IconStyle(rawValue: raw) { iconStyle = v }
    }
    @objc func setShows(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let v = IconShows(rawValue: raw) { iconShows = v }
    }
    @objc func refreshNow() { refresh() }
    @objc func openUsage() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    @objc func trackSpend() { NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/usage")!) }
    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Pulse for Claude by Dexter",
            .applicationVersion: "1.0",
            .credits: NSAttributedString(string: "Claude usage limits in your menu bar.\nData from your local Claude Code login.\nOpen source · MIT.")
        ])
    }
    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: Launch at login
    func loginEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch { NSSound.beep() }
        }
    }
}

// MARK: - Preview renderer (offscreen → PNG, no Screen Recording needed) -------
// Run with:  Pulse --shot <path.png>   — composes the dropdown look into an image.

final class PreviewContainer: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirty: NSRect) {
        Theme.rgb(0x1C, 0x1C, 0x1E).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 13, yRadius: 13).fill()
    }
}

func renderPreview(to path: String) {
    PREVIEW = true
    let u = Net.fetchUsage() ?? Usage(
        five_hour: Quota(utilization: 45, resets_at: nil),
        seven_day: Quota(utilization: 17, resets_at: nil),
        seven_day_opus: nil,
        seven_day_sonnet: Quota(utilization: 0, resets_at: nil),
        extra_usage: Extra(is_enabled: false, used_credits: 0, monthly_limit: 80, currency: "USD", utilization: 0))

    let pad: CGFloat = 14
    let W = ROW_W + pad*2
    let container = PreviewContainer(frame: NSRect(x: 0, y: 0, width: W, height: 900))

    var y: CGFloat = pad
    func place(_ v: NSView, h: CGFloat) {
        v.setFrameOrigin(NSPoint(x: pad, y: y)); v.setFrameSize(NSSize(width: ROW_W, height: h))
        container.addSubview(v); y += h
    }
    func sep() {
        let line = NSView(frame: NSRect(x: pad+16, y: y+5, width: ROW_W-32, height: 1))
        line.wantsLayer = true; line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        container.addSubview(line); y += 11
    }
    func textRow(_ s: String, color: NSColor? = nil, trailing: String? = nil, chevron: Bool = false) {
        let l = makeLabel(s, size: 13, weight: .regular, color: color ?? inkColor())
        l.frame = NSRect(x: pad+20, y: y+4, width: ROW_W-60, height: 18); container.addSubview(l)
        if let trailing {
            let t = makeLabel(trailing, size: 12, weight: .regular, color: tertiaryInk(), align: .right)
            t.frame = NSRect(x: pad+ROW_W-70, y: y+5, width: 54, height: 16); container.addSubview(t)
        }
        if chevron {
            let c = makeLabel("›", size: 15, weight: .regular, color: tertiaryInk(), align: .right)
            c.frame = NSRect(x: pad+ROW_W-30, y: y+2, width: 16, height: 18); container.addSubview(c)
        }
        y += 28
    }

    place(HeaderView(), h: 30)
    place(QuotaRowView(title: "5-hour limit", pct: pctOf(u.five_hour), sub: "resets in 3h 33m"), h: 58)
    place(QuotaRowView(title: "Weekly · all models", pct: pctOf(u.seven_day), sub: "resets in 3d 3h"), h: 58)
    place(QuotaRowView(title: "Weekly · Sonnet only", pct: pctOf(u.seven_day_sonnet), sub: "resets in 3d 3h"), h: 58)
    place(QuotaRowView(title: "Usage credits", pct: 0, sub: "$0.00 of $80.00 extra usage"), h: 58)
    sep()
    textRow("Track API Spend (optional)…")
    sep()
    textRow("Icon Style", chevron: true)
    textRow("Icon Shows", chevron: true)
    textRow("Launch at Login")
    textRow("Refresh Now", trailing: "⌘R")
    textRow("Open Usage Settings on claude.ai")
    sep()
    textRow("Updated 12:16 PM · refreshes every minute", color: tertiaryInk())
    textRow("About Pulse for Claude by Dexter")
    textRow("Quit Pulse for Claude by Dexter", trailing: "⌘Q")
    y += pad

    container.setFrameSize(NSSize(width: W, height: y))
    container.display()

    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { exit(1) }
    container.cacheDisplay(in: container.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

// MARK: - Entry ---------------------------------------------------------------

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--shot") {
    let path = (i+1 < args.count) ? args[i+1] : "pulse_shot.png"
    let app = NSApplication.shared
    _ = app // ensure AppKit is initialized for offscreen drawing
    renderPreview(to: path)
    exit(0)
}

// Self-test: prove the menu's actions actually do their thing, headless.
if args.contains("--selftest") {
    func line(_ s: String) { print(s) }
    // 1. token discovery
    let tok = Net.loadToken()
    line("token: \(tok != nil ? "found (\(tok!.count) chars)" : "MISSING")")
    // 2. live fetch + parse
    let u = Net.fetchUsage()
    if let u {
        line("fetch: OK  5h=\(pctOf(u.five_hour).map(String.init) ?? "-")%  7d=\(pctOf(u.seven_day).map(String.init) ?? "-")%  sonnet=\(pctOf(u.seven_day_sonnet).map(String.init) ?? "-")%  opus=\(u.seven_day_opus?.utilization != nil ? "present" : "absent")  extra=\(u.extra_usage?.is_enabled.map(String.init) ?? "nil")")
        line("reset 5h: \(Clock.resetsIn(u.five_hour?.resets_at))")
    } else { line("fetch: FAILED") }
    // 3. Launch at Login round-trip (the risky one)
    if #available(macOS 13.0, *) {
        func st() -> String {
            switch SMAppService.mainApp.status {
            case .notRegistered: return "notRegistered"
            case .enabled: return "enabled"
            case .requiresApproval: return "requiresApproval"
            case .notFound: return "notFound"
            @unknown default: return "unknown"
            }
        }
        line("login status before: \(st())")
        do { try SMAppService.mainApp.register(); line("login register: OK -> \(st())") }
        catch { line("login register: ERROR \(error.localizedDescription)") }
        do { try SMAppService.mainApp.unregister(); line("login unregister: OK -> \(st())") }
        catch { line("login unregister: ERROR \(error.localizedDescription)") }
    }
    // 4. URLs the menu opens are well-formed
    for s in ["https://claude.ai/settings/usage", "https://console.anthropic.com/settings/usage"] {
        line("url ok: \(URL(string: s) != nil)  \(s)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
