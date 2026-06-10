import AppKit

/// Снимок данных для отрисовки графика.
struct ChartData {
    var segments: [Seg]            // отрезки сидения за сегодня (epoch-секунды)
    var now: Double                // текущий момент (epoch)
    var sitLimit: TimeInterval     // порог «встать» — для красной зоны на ленте
    var bars: [WeekBar]            // 7 дней, старые → новые
    var breaksToday: Int
    var longestToday: TimeInterval
}

/// Лента сегодняшнего дня + столбики тренда за 7 дней + строка-мотиватор.
/// При наведении на сегмент/столбик внизу показывается детальный ридаут.
/// Встраивается как view в пункт меню — без отдельного окна.
final class ChartView: NSView {
    var data = ChartData(segments: [], now: 0, sitLimit: 3000, bars: [], breaksToday: 0, longestToday: 0) {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false } // координаты снизу вверх

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 232))
    }
    required init?(coder: NSCoder) { fatalError() }

    private let pad: CGFloat = 16

    // Зоны для hit-test при наведении (заполняются при отрисовке).
    private var segHit: [(rect: NSRect, seg: Seg)] = []
    private var barHit: [(rect: NSRect, bar: WeekBar)] = []
    private var hoverText: String?

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var text: String? = nil
        if let hit = segHit.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }) {
            let s = hit.seg
            let dur = s.end - s.start
            text = "\(timeString(s.start))–\(timeString(s.end)) · \(durString(dur))"
        } else if let hit = barHit.first(where: { $0.rect.insetBy(dx: -3, dy: 0).contains(p) }) {
            let b = hit.bar
            text = "\(b.label.capitalized) · \(oneDp(b.hours)) ч" + (b.isToday ? " (сегодня)" : "")
        }
        if text != hoverText { hoverText = text; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverText != nil { hoverText = nil; needsDisplay = true }
    }

    // MARK: - Отрисовка

    override func draw(_ dirtyRect: NSRect) {
        segHit.removeAll(); barHit.removeAll()
        let W = bounds.width
        let left = pad, right = W - pad
        let innerW = right - left

        drawCaption("Сегодня · ритм дня", at: NSPoint(x: left, y: 208))
        drawStrip(x0: left, x1: right, y: 186, h: 16)

        drawCaption("За неделю · часов в день", at: NSPoint(x: left, y: 150))
        drawBars(x0: left, width: innerW, baseline: 66, maxH: 60)

        drawBottom(x0: left, width: innerW, y: 16)
    }

    // MARK: - Лента дня

    private func drawStrip(x0: CGFloat, x1: CGFloat, y: CGFloat, h: CGFloat) {
        let segs = data.segments
        let dayStart = segs.map { $0.start }.min() ?? (data.now - 3600)
        let dayEnd = max(data.now, segs.map { $0.end }.max() ?? data.now)
        let span = max(dayEnd - dayStart, 1)
        let w = x1 - x0

        func xOf(_ t: Double) -> CGFloat { x0 + CGFloat((t - dayStart) / span) * w }

        let track = NSBezierPath(roundedRect: NSRect(x: x0, y: y, width: w, height: h), xRadius: h/2, yRadius: h/2)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()

        for s in segs {
            let sx = xOf(s.start), ex = xOf(s.end)
            guard ex > sx else { continue }
            let rect = NSRect(x: sx, y: y, width: max(ex - sx, 1.5), height: h)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()

            let overStart = s.start + data.sitLimit
            if overStart < s.end {
                let ox = xOf(overStart)
                let orect = NSRect(x: ox, y: y, width: max(ex - ox, 1.5), height: h)
                NSColor.systemRed.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: orect, xRadius: 3, yRadius: 3).fill()
            }
            segHit.append((rect, s))
        }

        drawSmall(timeString(dayStart), at: NSPoint(x: x0, y: y - 15), align: .left)
        drawSmall(timeString(dayEnd),   at: NSPoint(x: x1, y: y - 15), align: .right)
    }

    // MARK: - Столбики недели

    private func drawBars(x0: CGFloat, width: CGFloat, baseline: CGFloat, maxH: CGFloat) {
        let bars = data.bars
        guard !bars.isEmpty else { return }

        let nonZero = bars.filter { $0.hours > 0 }.map { $0.hours }
        let avg = nonZero.isEmpty ? 0 : nonZero.reduce(0, +) / Double(nonZero.count)
        // Запас сверху 25 %, чтобы подписи над столбиком не упирались в заголовок.
        let peak = max(max(bars.map { $0.hours }.max() ?? 1, avg), 0.1) * 1.25

        let slot = width / CGFloat(bars.count)
        let bw = slot * 0.56

        if avg > 0 {
            let ay = baseline + CGFloat(avg / peak) * maxH
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x0, y: ay))
            line.line(to: NSPoint(x: x0 + width, y: ay))
            line.lineWidth = 1
            line.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            line.stroke()
            drawSmall("ср. \(oneDp(avg)) ч", at: NSPoint(x: x0, y: ay + 3), align: .left)
        }

        for (i, bar) in bars.enumerated() {
            let cx = x0 + slot * CGFloat(i) + slot / 2
            let bh = CGFloat(bar.hours / peak) * maxH
            let rect = NSRect(x: cx - bw/2, y: baseline, width: bw, height: max(bh, bar.hours > 0 ? 2 : 0))
            if bar.hours > 0 {
                (bar.isToday ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()
            }
            drawSmall(bar.label, at: NSPoint(x: cx, y: baseline - 15), align: .center,
                      color: bar.isToday ? .labelColor : .secondaryLabelColor)
            if bar.isToday && bar.hours > 0 {
                drawSmall(oneDp(bar.hours), at: NSPoint(x: cx, y: baseline + bh + 2), align: .center,
                          color: .labelColor)
            }
            // Зона наведения — на всю высоту слота, чтобы попасть было легко.
            barHit.append((NSRect(x: cx - slot/2, y: baseline - 4, width: slot, height: maxH + 8), bar))
        }
    }

    // MARK: - Нижняя строка: при наведении — детали, иначе — мотиватор

    private func drawBottom(x0: CGFloat, width: CGFloat, y: CGFloat) {
        if let hover = hoverText {
            drawSmall(hover, at: NSPoint(x: x0 + width/2, y: y), align: .center,
                      color: .controlAccentColor, size: 11)
        } else {
            let text = "Перерывов: \(data.breaksToday)   ·   макс. сидение \(durString(data.longestToday))"
            drawSmall(text, at: NSPoint(x: x0 + width/2, y: y), align: .center,
                      color: .secondaryLabelColor, size: 11)
        }
    }

    // MARK: - Текст-хелперы

    private enum Align { case left, center, right }

    private func drawCaption(_ s: String, at p: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }

    private func drawSmall(_ s: String, at p: NSPoint, align: Align = .left,
                           color: NSColor = .tertiaryLabelColor, size: CGFloat = 9) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: color
        ]
        let str = s as NSString
        let w = str.size(withAttributes: attrs).width
        var x = p.x
        switch align {
        case .left:   x = p.x
        case .center: x = p.x - w/2
        case .right:  x = p.x - w
        }
        str.draw(at: NSPoint(x: x, y: p.y), withAttributes: attrs)
    }

    // MARK: - Формат

    private func timeString(_ epoch: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "H:mm"
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }

    private func oneDp(_ h: Double) -> String { String(format: "%.1f", h) }

    private func durString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        if m < 60 { return "\(m) мин" }
        return "\(m / 60) ч \(m % 60) мин"
    }
}
