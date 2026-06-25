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

/// Зачем промигнуть иконкой.
enum BlinkKind {
    case standUp      // просидел больше лимита — пора встать
    case stayActive   // вот-вот сброс по отлучке: «ещё тут? шевельни мышь»
}

/// Результат одного тика — что должен сделать UI.
struct TickResult {
    var state: SitState
    var continuousSitting: TimeInterval
    var todayTotal: TimeInterval
    var overLimit: Bool
    var blink: BlinkKind?          // если не nil — промигнуть иконкой (и с какой причиной)
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

    // Предупреждение присутствия: за сколько секунд до порога отлучки промигнуть.
    private let presenceWarnings: [Int] = [60, 30]
    private let presenceFloor: TimeInterval = 60  // не дёргать, если сидим меньше минуты
    private var warned: Set<Int> = []
    private var lastIdle: TimeInterval = 0

    // Память о последнем сбросе по отлучке — для кнопки «Вернуть таймер».
    private let undoWindow: TimeInterval = 2 * 3600   // отменять можно в течение 2 часов
    private var resetSaved: TimeInterval = 0          // сколько было непрерывно сидения на момент сброса
    private var resetAt: Date?                        // когда случился сброс
    private var resetSubtracted: TimeInterval = 0     // что вычли из «за сегодня» при сбросе

    /// Аномально большой интервал между тиками = сон/заморозка системы → трактуем как отлучку.
    private let suspendCutoff: TimeInterval

    init(settings: Settings, tickInterval: TimeInterval) {
        self.settings = settings
        self.suspendCutoff = max(60, tickInterval * 4)
    }

    /// Главный шаг. `now` и `idle` приходят снаружи (idle — секунды без ввода от системы).
    func tick(now: Date, idle: TimeInterval, calendar: Calendar = .current) -> TickResult {
        defer { lastTick = now; lastIdle = idle }

        // Сброс «за сегодня» при смене календарного дня.
        let day = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        if let last = lastDay, last != day { todayTotal = 0 }
        lastDay = day

        if paused {
            state = .away
            continuousSitting = 0
            overLimit = false
            lastBlink = nil
            warned.removeAll()
            return result(blink: nil)
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
                // Запоминаем сброс — вдруг ты на самом деле сидел (Zoom) и захочешь вернуть.
                resetSaved = continuousSitting
                resetAt = now
                resetSubtracted = idle
            }
            state = .away
            continuousSitting = 0
            overLimit = false
            lastBlink = nil
            warned.removeAll()
            return result(blink: nil, endedSit: endedSit)
        }

        // СИЖУ.
        state = .sitting
        continuousSitting += elapsed
        todayTotal += elapsed

        // Свежий ввод (idle упал) — начинаем новый цикл предупреждений присутствия.
        if idle < lastIdle { warned.removeAll() }

        var blink: BlinkKind? = nil

        // Предупреждение присутствия: idle подбирается к порогу отлучки, а мы ещё «сидим».
        // Каждое окно (60/30 с до порога) срабатывает один раз за цикл бездействия.
        if continuousSitting >= presenceFloor {
            for w in presenceWarnings {
                let trigger = settings.idleThreshold - TimeInterval(w)
                if trigger > 0, idle >= trigger, !warned.contains(w) {
                    warned.insert(w)
                    blink = .stayActive
                }
            }
        }

        // Лимит «пора встать» — важнее, перебивает предупреждение присутствия.
        if continuousSitting >= settings.sitLimit {
            if !overLimit {
                overLimit = true
                lastBlink = now
                blink = .standUp
            } else if let lb = lastBlink, now.timeIntervalSince(lb) >= settings.remindInterval {
                lastBlink = now
                blink = .standUp
            }
        }
        return result(blink: blink)
    }

    func resetCounters() {
        continuousSitting = 0
        todayTotal = 0
        overLimit = false
        lastBlink = nil
        resetAt = nil
    }

    /// Доступна ли отмена последнего сброса (в пределах окна).
    func undoAvailable(now: Date) -> Bool {
        guard let at = resetAt else { return false }
        return now.timeIntervalSince(at) <= undoWindow
    }

    /// Сколько было непрерывного сидения на момент сброса (для подписи кнопки).
    var undoSavedValue: TimeInterval { resetSaved }

    /// Отменить сброс: вернуть таймер так, будто всё это время ты сидел.
    /// Возвращает восстановленное значение непрерывного сидения, или nil если отмена недоступна.
    @discardableResult
    func undoReset(now: Date) -> TimeInterval? {
        guard let at = resetAt, now.timeIntervalSince(at) <= undoWindow else { return nil }
        let gap = max(0, now.timeIntervalSince(at))
        let restored = resetSaved + gap
        // Возвращаем «за сегодня»: вычтенное при сбросе + не учтённую часть простоя.
        todayTotal += resetSubtracted + max(0, gap - continuousSitting)
        continuousSitting = restored
        state = .sitting
        overLimit = restored >= settings.sitLimit
        lastBlink = overLimit ? now : nil   // если уже за лимитом — напомним «встать» через интервал
        warned.removeAll()
        resetAt = nil
        return restored
    }

    /// Восстановление «за сегодня» после перезапуска в тот же день.
    func restoreToday(_ total: TimeInterval, day: Int) {
        todayTotal = total
        lastDay = day
    }

    var currentDay: Int { lastDay ?? 0 }

    private func result(blink: BlinkKind?, endedSit: TimeInterval? = nil) -> TickResult {
        TickResult(
            state: state,
            continuousSitting: continuousSitting,
            todayTotal: todayTotal,
            overLimit: overLimit,
            blink: blink,
            endedSit: endedSit
        )
    }
}
