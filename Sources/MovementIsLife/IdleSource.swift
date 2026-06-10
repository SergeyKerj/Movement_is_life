import CoreGraphics
import Foundation

/// Сколько секунд система не получала ни клавы, ни мыши/тачпада.
/// Системный idle-таймер: без перехвата нажатий и без Accessibility-разрешений.
enum IdleSource {
    private static let anyInputEvent = CGEventType(rawValue: ~0)!

    static func seconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)
    }
}
