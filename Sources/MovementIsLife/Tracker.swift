import Foundation

/// Настройки трекера. Хранятся в UserDefaults, минуты — единица для UI.
struct Settings {
    var idleThreshold: TimeInterval   // пауза без ввода = «встал/отошёл»
    var sitLimit: TimeInterval        // непрерывное сидение = «пора вставать»
    var remindInterval: TimeInterval  // как часто промигивать после лимита

    static let defaults = Settings(
        idleThreshold: 5 * 60,
        sitLimit: 50 * 60,
        remindInterval: 5 * 60
    )
}

/// Два состояния. Напоминание — не состояние, а событие внутри `.sitting`.
enum SitState {
    case sitting
    case away
}

/// Результат одного тика — что должен сделать UI.
struct TickResult {
    var state: SitState
    var continuousSitting: TimeInterval
    var todayTotal: TimeInterval
    var overLimit: Bool
    var shouldBlink: Bool          // пора промигнуть иконкой прямо сейчас
    var endedSit: TimeInterval?    // если на этом тике закончилось сидение — его длина (для истории)
}

/// Машина состояний. Не знает ни про таймеры, ни про UI —
/// ей скармливают (сейчас, idle-секунды), она возвращает что показать.
final class SittingTracker {
    var settings: Settings

    private(set) var state: SitState = .away
    private(set) var continuousSitting: TimeInterval = 0
    private(set) var todayTotal: TimeInterval = 0
    var paused: Bool = false

    private var overLimit = false
    private var lastBlink: Date?
    private var lastTick: Date?
    private var lastDay: Int?

    /// Аномально большой интервал между тиками = сон/заморозка системы → трактуем как отлучку.
    private let suspendCutoff: TimeInterval

    init(settings: Settings, tickInterval: TimeInterval) {
        self.settings = settings
        self.suspendCutoff = max(60, tickInterval * 4)
    }

    /// Главный шаг. `now` и `idle` приходят снаружи (idle — секунды без ввода от системы).
    func tick(now: Date, idle: TimeInterval, calendar: Calendar = .current) -> TickResult {
        defer { lastTick = now }

        // Сброс «за сегодня» при смене календарного дня.
        let day = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        if let last = lastDay, last != day { todayTotal = 0 }
        lastDay = day

        if paused {
            state = .away
            continuousSitting = 0
            overLimit = false
            lastBlink = nil
            return result(shouldBlink: false)
        }

        let elapsed = lastTick.map { now.timeIntervalSince($0) } ?? 0
        let suspended = elapsed > suspendCutoff
        let activeNow = idle < settings.idleThreshold

        if suspended || !activeNow {
            // ОТОШЁЛ. Ретро-коррекция: idle-период ошибочно копился как сидение — вычесть.
            var endedSit: TimeInterval? = nil
            if state == .sitting && !suspended {
                endedSit = continuousSitting
                todayTotal = max(0, todayTotal - idle)
            }
            state = .away
            continuousSitting = 0
            overLimit = false
            lastBlink = nil
            return result(shouldBlink: false, endedSit: endedSit)
        }

        // СИЖУ.
        state = .sitting
        continuousSitting += elapsed
        todayTotal += elapsed

        var blink = false
        if continuousSitting >= settings.sitLimit {
            if !overLimit {
                overLimit = true
                lastBlink = now
                blink = true
            } else if let lb = lastBlink, now.timeIntervalSince(lb) >= settings.remindInterval {
                lastBlink = now
                blink = true
            }
        }
        return result(shouldBlink: blink)
    }

    func resetCounters() {
        continuousSitting = 0
        todayTotal = 0
        overLimit = false
        lastBlink = nil
    }

    /// Восстановление «за сегодня» после перезапуска в тот же день.
    func restoreToday(_ total: TimeInterval, day: Int) {
        todayTotal = total
        lastDay = day
    }

    var currentDay: Int { lastDay ?? 0 }

    private func result(shouldBlink: Bool, endedSit: TimeInterval? = nil) -> TickResult {
        TickResult(
            state: state,
            continuousSitting: continuousSitting,
            todayTotal: todayTotal,
            overLimit: overLimit,
            shouldBlink: shouldBlink,
            endedSit: endedSit
        )
    }
}
