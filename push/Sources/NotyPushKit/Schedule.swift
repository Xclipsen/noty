import Foundation
import NotebookCore

/// Poll times and quiet hours in the device's wall-clock time.
public enum PollSchedule {
    static func isWeekend(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)  // 1 = Sunday, 7 = Saturday
        return weekday == 1 || weekday == 7
    }

    /// First poll slot strictly after `date`: a listed hour of that day type,
    /// `minute` past the full hour. Nil only for an empty schedule.
    public static func next(after date: Date, minute: Int, config: PollScheduleConfig, calendar: Calendar) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        for dayOffset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else { continue }
            let hours = (isWeekend(day, calendar: calendar) ? config.weekendHours : config.weekdayHours).sorted()
            for hour in hours {
                // DST: a missing local hour moves forward, a doubled one is used once.
                guard let slot = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                      calendar.isDate(slot, inSameDayAs: day) else { continue }
                if slot > date { return slot }
            }
        }
        return nil
    }

    /// Delay after `failures` failed polls in a row: 15 min, doubled, at most 12 h.
    public static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(15 * 60 * pow(2, Double(min(failures, 10) - 1)), 12 * 3600)
    }

    /// Next poll after an attempt at `now`: the next slot, but not before the backoff has passed.
    public static func nextAfterAttempt(now: Date, failures: Int, minute: Int, config: PollScheduleConfig, calendar: Calendar) -> Date {
        let earliest = now.addingTimeInterval(max(60, backoff(failures: failures)))
        return next(after: earliest.addingTimeInterval(-1), minute: minute, config: config, calendar: calendar)
            ?? now.addingTimeInterval(3600)
    }

    /// The days compared: [today, today + windowDays).
    public static func window(now: Date, days: Int, calendar: Calendar) -> (start: CivilDate, end: CivilDate) {
        let today = CivilDate(now, calendar: calendar)
        return (today, today.adding(days: days))
    }
}

extension PollSchedule {
    /// True when `date` lies in a listed hour of its day type (a poll that
    /// was missed, e.g. while the server was down, is not made up at night).
    public static func isPollHour(_ date: Date, config: PollScheduleConfig, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return (isWeekend(date, calendar: calendar) ? config.weekendHours : config.weekdayHours).contains(hour)
    }
}
