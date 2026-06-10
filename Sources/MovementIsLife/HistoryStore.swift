import Foundation

/// Отрезок сидения за сегодня (для ленты дня). Время — epoch-секунды.
struct Seg: Codable {
    var start: Double
    var end: Double
}

/// Детали текущего дня: сегменты ленты + мотиваторы.
struct TodayDetail: Codable {
    var day: Int = 0
    var segments: [Seg] = []
    var breaks: Int = 0
    var longest: TimeInterval = 0
}

/// Агрегат за прошлый день — для столбиков тренда.
struct DayStat: Codable {
    var day: Int          // порядковый номер дня (ordinality .day in .era)
    var sitting: TimeInterval
}

/// Одна строка недельного графика.
struct WeekBar {
    var label: String     // Пн/Вт…
    var hours: Double
    var isToday: Bool
}

/// Хранилище истории: дневные агрегаты (тренд) + детали сегодня (лента).
/// JSON в ~/Library/Application Support/MovementIsLife/history.json
final class HistoryStore {
    private struct Disk: Codable {
        var days: [DayStat] = []
        var today: TodayDetail = TodayDetail()
    }

    private var disk = Disk()
    private let url: URL
    private let calendar = Calendar.current
    private let weekdaySymbols: [String]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MovementIsLife", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("history.json")

        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        weekdaySymbols = df.shortStandaloneWeekdaySymbols ?? ["вс","пн","вт","ср","чт","пт","сб"]

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Disk.self, from: data) {
            disk = decoded
        }
    }

    var today: TodayDetail { disk.today }

    /// Восстановить детали сегодня после перезапуска, если день совпал.
    func restoredToday(for day: Int) -> TodayDetail? {
        disk.today.day == day ? disk.today : nil
    }

    /// Записать снимок текущего дня и слить его в дневные агрегаты.
    func update(day: Int, sitting: TimeInterval, detail: TodayDetail) {
        disk.today = detail
        if let i = disk.days.firstIndex(where: { $0.day == day }) {
            disk.days[i].sitting = sitting
        } else {
            disk.days.append(DayStat(day: day, sitting: sitting))
        }
        // Держим ~30 дней.
        disk.days.sort { $0.day < $1.day }
        if disk.days.count > 30 { disk.days.removeFirst(disk.days.count - 30) }
        save()
    }

    func save() {
        if let data = try? JSONEncoder().encode(disk) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Последние 7 дней (старые → новые), час сидения по дням, с пометкой «сегодня».
    func weeklyBars(now: Date) -> [WeekBar] {
        let map = Dictionary(uniqueKeysWithValues: disk.days.map { ($0.day, $0.sitting) })
        var bars: [WeekBar] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
            let weekdayIdx = calendar.component(.weekday, from: date) - 1
            let hours = (map[day] ?? 0) / 3600
            bars.append(WeekBar(label: weekdaySymbols[weekdayIdx],
                                hours: hours,
                                isToday: offset == 0))
        }
        return bars
    }
}
