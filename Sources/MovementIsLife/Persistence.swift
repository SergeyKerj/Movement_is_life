import Foundation

/// Хранение настроек и «за сегодня» в UserDefaults.
enum Persistence {
    private static let d = UserDefaults.standard

    private enum Key {
        static let idle = "idleThresholdMin"
        static let limit = "sitLimitMin"
        static let remind = "remindIntervalMin"
        static let todayTotal = "todayTotal"
        static let todayDay = "todayDay"
    }

    static func loadSettings() -> Settings {
        var s = Settings.defaults
        if d.object(forKey: Key.idle) != nil {
            s.idleThreshold = TimeInterval(d.integer(forKey: Key.idle) * 60)
        }
        if d.object(forKey: Key.limit) != nil {
            s.sitLimit = TimeInterval(d.integer(forKey: Key.limit) * 60)
        }
        if d.object(forKey: Key.remind) != nil {
            s.remindInterval = TimeInterval(d.integer(forKey: Key.remind) * 60)
        }
        return s
    }

    static func saveSettings(_ s: Settings) {
        d.set(Int(s.idleThreshold / 60), forKey: Key.idle)
        d.set(Int(s.sitLimit / 60), forKey: Key.limit)
        d.set(Int(s.remindInterval / 60), forKey: Key.remind)
    }

    static func saveToday(total: TimeInterval, day: Int) {
        d.set(total, forKey: Key.todayTotal)
        d.set(day, forKey: Key.todayDay)
    }

    static func loadToday() -> (total: TimeInterval, day: Int) {
        (d.double(forKey: Key.todayTotal), d.integer(forKey: Key.todayDay))
    }
}
