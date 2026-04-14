import Foundation

func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds) / 60
    if minutes < 1 { return "<1m" }
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let mins = minutes % 60
    if hours >= 24 {
        let days = hours / 24
        let hrs = hours % 24
        if hrs > 0 { return "\(days)d\(hrs)h" }
        return "\(days)d"
    }
    if mins > 0 { return "\(hours)h\(mins)m" }
    return "\(hours)h"
}
