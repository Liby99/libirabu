// A single scalar tween driven by wall-clock time. The animation system rides on
// these instead of nested rAF callbacks — a tween is data, evaluated per frame.

import CalendarGeometry
import CoreGraphics
import Foundation

struct Tween {
    var from: CGFloat
    var to: CGFloat
    var start: Date
    var duration: TimeInterval
    var ease: (CGFloat) -> CGFloat

    func progress(at date: Date) -> CGFloat {
        guard duration > 0 else { return 1 }
        return CGFloat(min(1, max(0, date.timeIntervalSince(start) / duration)))
    }

    func value(at date: Date) -> CGFloat {
        from + (to - from) * ease(progress(at: date))
    }

    func isComplete(at date: Date) -> Bool {
        date.timeIntervalSince(start) >= duration
    }
}
