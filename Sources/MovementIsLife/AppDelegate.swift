import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var tracker: SittingTracker!
    private var timer: Timer?
    private var blinkTimer: Timer?

    private let tickInterval: TimeInterval = 5

    // Пункты меню, которые обновляются на каждом тике.
    private let nowItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let todayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Пауза трекинга", action: #selector(togglePause), keyEquivalent: "p")

    // Пресеты для подменю настроек (в минутах).
    private let idlePresets = [1, 2, 3, 5, 7, 10, 15]
    private let limitPresets = [20, 30, 40, 50, 60, 90]
    private let remindPresets = [3, 5, 10, 15]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Persistence.loadSettings()
        tracker = SittingTracker(settings: settings, tickInterval: tickInterval)
        restoreToday()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🪑 —"
        buildMenu()

        // Сон / пробуждение → трактуем как отлучку (на тике сработает suspendCutoff,
        // но явная реакция на сон делает поведение предсказуемым).
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(systemWake),
                       name: NSWorkspace.didWakeNotification, object: nil)

        let t = Timer(timeInterval: tickInterval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Persistence.saveToday(total: tracker.todayTotal, day: tracker.currentDay)
    }

    // MARK: - Тик

    @objc private func tick() {
        let r = tracker.tick(now: Date(), idle: IdleSource.seconds())
        render(r)
        Persistence.saveToday(total: tracker.todayTotal, day: tracker.currentDay)
        if r.shouldBlink { blink() }
    }

    @objc private func systemWake() {
        // Длинный простой во сне закроется suspendCutoff на ближайшем тике; форсируем тик сразу.
        tick()
    }

    // MARK: - Отрисовка

    private func render(_ r: TickResult) {
        let icon: String
        switch r.state {
        case .away:    icon = "🚶"
        case .sitting: icon = r.overLimit ? "⚠️" : "🪑"
        }
        let label = tracker.paused ? "⏸" : "\(icon) \(short(r.continuousSitting))"
        statusItem.button?.title = label

        nowItem.title   = "Сейчас непрерывно: \(long(r.continuousSitting))"
        todayItem.title = "Всего за сегодня: \(long(r.todayTotal))"
        pauseItem.title = tracker.paused ? "Возобновить трекинг" : "Пауза трекинга"
    }

    /// Мигание: несколько быстрых смен заголовка, чтобы зацепить взгляд в строке меню.
    private func blink() {
        blinkTimer?.invalidate()
        let normal = statusItem.button?.title ?? "⚠️"
        let flash = "‼️ ВСТАНЬ"
        var count = 0
        let bt = Timer(timeInterval: 0.4, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.statusItem.button?.title = (count % 2 == 0) ? flash : normal
            count += 1
            if count >= 6 {
                t.invalidate()
                self.statusItem.button?.title = normal
            }
        }
        RunLoop.main.add(bt, forMode: .common)
        blinkTimer = bt
    }

    // MARK: - Меню

    private func buildMenu() {
        let menu = NSMenu()
        nowItem.isEnabled = false
        todayItem.isEnabled = false
        menu.addItem(nowItem)
        menu.addItem(todayItem)
        menu.addItem(.separator())

        menu.addItem(submenu(title: "Порог отлучки", presets: idlePresets,
                             current: Int(tracker.settings.idleThreshold / 60),
                             action: #selector(setIdle(_:))))
        menu.addItem(submenu(title: "Порог «встать»", presets: limitPresets,
                             current: Int(tracker.settings.sitLimit / 60),
                             action: #selector(setLimit(_:))))
        menu.addItem(submenu(title: "Промигивать каждые", presets: remindPresets,
                             current: Int(tracker.settings.remindInterval / 60),
                             action: #selector(setRemind(_:))))
        menu.addItem(.separator())

        menu.addItem(withTitle: "Сбросить счётчики", action: #selector(resetCounters), keyEquivalent: "r")
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    private func submenu(title: String, presets: [Int], current: Int, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for m in presets {
            let item = NSMenuItem(title: "\(m) мин", action: action, keyEquivalent: "")
            item.tag = m
            item.target = self
            item.state = (m == current) ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    private func refreshChecks(in menuItem: NSMenuItem?, current: Int) {
        guard let sub = menuItem?.submenu else { return }
        for item in sub.items { item.state = (item.tag == current) ? .on : .off }
    }

    // MARK: - Действия

    @objc private func setIdle(_ sender: NSMenuItem) {
        tracker.settings.idleThreshold = TimeInterval(sender.tag * 60)
        persistSettings()
        refreshChecks(in: sender.menu?.supermenu?.items.first { $0.submenu == sender.menu }, current: sender.tag)
    }

    @objc private func setLimit(_ sender: NSMenuItem) {
        tracker.settings.sitLimit = TimeInterval(sender.tag * 60)
        persistSettings()
        refreshChecks(in: sender.menu?.supermenu?.items.first { $0.submenu == sender.menu }, current: sender.tag)
    }

    @objc private func setRemind(_ sender: NSMenuItem) {
        tracker.settings.remindInterval = TimeInterval(sender.tag * 60)
        persistSettings()
        refreshChecks(in: sender.menu?.supermenu?.items.first { $0.submenu == sender.menu }, current: sender.tag)
    }

    @objc private func resetCounters() {
        tracker.resetCounters()
        tick()
    }

    @objc private func togglePause() {
        tracker.paused.toggle()
        tick()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Персист

    private func persistSettings() {
        Persistence.saveSettings(tracker.settings)
    }

    private func restoreToday() {
        let (total, day) = Persistence.loadToday()
        let today = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        if day == today { tracker.restoreToday(total, day: day) }
    }

    // MARK: - Формат времени

    private func short(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h\(String(format: "%02d", m % 60))"
    }

    private func long(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        if m < 60 { return "\(m) мин" }
        return "\(m / 60) ч \(m % 60) мин"
    }
}
