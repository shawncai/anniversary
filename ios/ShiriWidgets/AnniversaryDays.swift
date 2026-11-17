import Foundation

struct ShiriAnniversaryDays {
    let remaining: Int
    let elapsed: Int
    let nextDate: Date

    init?(start: String, today: Date, calendar: Calendar = Calendar(identifier: .gregorian), repeatYearly: Bool = true) {
        let components = start.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3,
              let first = calendar.date(from: DateComponents(year: components[0], month: components[1], day: components[2])),
              calendar.component(.year, from: first) == components[0],
              calendar.component(.month, from: first) == components[1],
              calendar.component(.day, from: first) == components[2] else { return nil }
        let day = calendar.startOfDay(for: today)
        let startDay = calendar.startOfDay(for: first)
        elapsed = max(0, calendar.dateComponents([.day], from: startDay, to: day).day ?? 0)
        if !repeatYearly || startDay > day {
            nextDate = startDay
        } else {
            let year = calendar.component(.year, from: day)
            func anniversary(_ targetYear: Int) -> Date? {
                guard let month = calendar.date(from: DateComponents(year: targetYear, month: components[1], day: 1)),
                      let range = calendar.range(of: .day, in: .month, for: month) else { return nil }
                return calendar.date(from: DateComponents(year: targetYear, month: components[1], day: min(components[2], range.count)))
            }
            guard let thisYear = anniversary(year), let nextYear = anniversary(year + 1) else { return nil }
            nextDate = thisYear >= day ? thisYear : nextYear
        }
        remaining = max(0, calendar.dateComponents([.day], from: day, to: nextDate).day ?? 0)
    }
}

