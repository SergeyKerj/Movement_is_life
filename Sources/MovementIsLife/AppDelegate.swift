import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var tracker: SittingTracker!
    private var history: HistoryStore!
    private var timer: Timer?
    private var blinkTimer: Timer?

    private let tickInterval: TimeInterval = 5

    // Пункты меню, обновляемые на каждом тике.
    private let nowItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let todayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Пауза трекинга", action: #selector(togglePause), keyEquivalent: "p")
    private let undoItem = NSMenuItem(title: "↩︎ Вернуть таймер", action: #selector(undoReset), keyEquivalent: "z")
    private let chartView = ChartView()

    // Учёт сессий сидения за сегодня (для ленты и мотиваторов).
    private var lastState: SitState = .away
    private var sessionStart: Date?
    private var lastTickAt: Date?
    private var todaySegments: [Seg] = []
    private var breaksToday = 0
    private var longestToday: TimeInterval = 0
    private var lastDayUI = -1
    private var lastResult: TickResult?

    // Пресеты подменю настроек (минуты).
    private let idlePresets = [1, 2, 3, 5, 7, 10, 15]
    private let limitPresets = [20, 30, 40, 50, 60, 90]
    private let remindPresets = [3, 5, 10, 15]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Persistence.loadSettings()
        tracker = SittingTracker(settings: settings, tickInterval: tickInterval)
        history = HistoryStore()
        restoreToday()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🪑 —"
        buildMenu()

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
        history.save()
    }

    // MARK: - Тик

    @objc private func tick() {
        let now = Date()
        let r = tracker.tick(now: now, idle: IdleSource.seconds())
        lastResult = r

        bookkeep(r: r, now: now)
        render(r)
        updateChart(now: now)

        Persistence.saveToday(total: tracker.todayTotal, day: tracker.currentDay)
        if let kind = r.blink { blink(kind: kind) }
    }

    @objc private func systemWake() { tick() }

    /// Учёт сессий, перерывов и смены дня.
    private func bookkeep(r: TickResult, now: Date) {
        let day = tracker.currentDay
        if day != lastDayUI {
            todaySegments = []
            breaksToday = 0
            longestToday = 0
            sessionStart = nil
            lastState = .away
            lastDayUI = day
        }

        if lastState == .away && r.state == .sitting {
            sessionStart = now
        }
        if lastState == .sitting && r.state == .away {
            if let s = sessionStart {
                let end = lastTickAt ?? now
                if end.timeIntervalSince(s) > 1 {
                    todaySegments.append(Seg(start: s.timeIntervalSince1970, end: end.timeIntervalSince1970))
                }
            }
            sessionStart = nil
            if let ended = r.endedSit, ended >= 60 {   // сидение ≥1 мин = «реальный» перерыв
                breaksToday += 1
                longestToday = max(longestToday, ended)
            }
        }
        lastState = r.state
        lastTickAt = now

        history.update(day: day, sitting: r.todayTotal, detail: currentDetail(r: r, now: now))
    }

    /// Сегменты с учётом текущего незакрытого сидения.
    private func liveSegments(now: Date) -> [Seg] {
        var segs = todaySegments
        if lastState == .sitting, let s = sessionStart, now.timeIntervalSince(s) > 1 {
            segs.append(Seg(start: s.timeIntervalSince1970, end: now.timeIntervalSince1970))
        }
        return segs
    }

    private func currentDetail(r: TickResult, now: Date) -> TodayDetail {
        TodayDetail(day: tracker.currentDay,
                    segments: liveSegments(now: now),
                    breaks: breaksToday,
                    longest: max(longestToday, r.continuousSitting))
    }

    // MARK: - Отрисовка

    private func render(_ r: TickResult) {
        let icon: String
        switch r.state {
        case .away:    icon = "🚶"
        case .sitting: icon = r.overLimit ? "⚠️" : "🪑"
        }
        statusItem.button?.title = tracker.paused ? "⏸" : "\(icon) \(short(r.continuousSitting))"

        nowItem.title   = "Сейчас непрерывно: \(long(r.continuousSitting))"
        todayItem.title = "Всего за сегодня: \(long(r.todayTotal))"
        pauseItem.title = tracker.paused ? "Возобновить трекинг" : "Пауза трекинга"
        refreshUndoItem()
    }

    /// Кнопка «Вернуть таймер» видна только пока отмена сброса доступна (окно 2 ч).
    private func refreshUndoItem() {
        let avail = tracker.undoAvailable(now: Date())
        undoItem.isHidden = !avail
        if avail {
            undoItem.title = "↩︎ Вернуть таймер (был \(long(tracker.undoSavedValue)))"
        }
    }

    private func updateChart(now: Date) {
        guard let r = lastResult else { return }
        chartView.data = ChartData(
            segments: liveSegments(now: now),
            now: now.timeIntervalSince1970,
            sitLimit: tracker.settings.sitLimit,
            bars: history.weeklyBars(now: now),
            breaksToday: breaksToday,
            longestToday: max(longestToday, r.continuousSitting)
        )
    }

    private func blink(kind: BlinkKind) {
        blinkTimer?.invalidate()
        let normal = statusItem.button?.title ?? "⚠️"
        let flash: String
        switch kind {
        case .standUp:    flash = "‼️ ВСТАНЬ"
        case .stayActive: flash = "🖱 ещё тут?"
        }
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
        menu.delegate = self
        nowItem.isEnabled = false
        todayItem.isEnabled = false
        menu.addItem(nowItem)
        menu.addItem(todayItem)
        undoItem.isHidden = true
        menu.addItem(undoItem)
        menu.addItem(.separator())

        let chartItem = NSMenuItem()
        chartItem.view = chartView
        menu.addItem(chartItem)
        menu.addItem(.separator())

        menu.addItem(submenu(title: "Порог отлучки", presets: idlePresets,
                             current: Int(tracker.settings.idleThreshold / 60), action: #selector(setIdle(_:))))
        menu.addItem(submenu(title: "Порог «встать»", presets: limitPresets,
                             current: Int(tracker.settings.sitLimit / 60), action: #selector(setLimit(_:))))
        menu.addItem(submenu(title: "Промигивать каждые", presets: remindPresets,
                             current: Int(tracker.settings.remindInterval / 60), action: #selector(setRemind(_:))))
        menu.addItem(.separator())

        menu.addItem(withTitle: "Сбросить счётчики", action: #selector(resetCounters), keyEquivalent: "r")
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    /// Перед раскрытием — освежить график (растёт текущая сессия).
    func menuWillOpen(_ menu: NSMenu) {
        updateChart(now: Date())
        refreshUndoItem()
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

    private func refreshChecks(for menu: NSMenu?, current: Int) {
        guard let sub = menu else { return }
        for item in sub.items { item.state = (item.tag == current) ? .on : .off }
    }

    // MARK: - Действия

    @objc private func setIdle(_ sender: NSMenuItem) {
        tracker.settings.idleThreshold = TimeInterval(sender.tag * 60)
        Persistence.saveSettings(tracker.settings)
        refreshChecks(for: sender.menu, current: sender.tag)
    }

    @objc private func setLimit(_ sender: NSMenuItem) {
        tracker.settings.sitLimit = TimeInterval(sender.tag * 60)
        Persistence.saveSettings(tracker.settings)
        refreshChecks(for: sender.menu, current: sender.tag)
    }

    @objc private func setRemind(_ sender: NSMenuItem) {
        tracker.settings.remindInterval = TimeInterval(sender.tag * 60)
        Persistence.saveSettings(tracker.settings)
        refreshChecks(for: sender.menu, current: sender.tag)
    }

    @objc private func resetCounters() {
        tracker.resetCounters()
        todaySegments = []
        breaksToday = 0
        longestToday = 0
        sessionStart = nil
        tick()
    }

    @objc private func undoReset() {
        let now = Date()
        guard let restored = tracker.undoReset(now: now) else { return }
        // Склеиваем разрыв: всё, что попало в восстановленное окно, становится одним сидением.
        let mergeStart = now.addingTimeInterval(-restored).timeIntervalSince1970
        let dropped = todaySegments.filter { $0.start >= mergeStart - 1 }.count
        todaySegments.removeAll { $0.start >= mergeStart - 1 }
        breaksToday = max(0, breaksToday - dropped)
        longestToday = max(longestToday, restored)
        sessionStart = Date(timeIntervalSince1970: mergeStart)
        lastState = .sitting
        tick()
    }

    @objc private func togglePause() {
        tracker.paused.toggle()
        tick()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Восстановление

    private func restoreToday() {
        let today = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let (total, day) = Persistence.loadToday()
        if day == today { tracker.restoreToday(total, day: day) }
        if let d = history.restoredToday(for: today) {
            todaySegments = d.segments
            breaksToday = d.breaks
            longestToday = d.longest
        }
        lastDayUI = today
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
