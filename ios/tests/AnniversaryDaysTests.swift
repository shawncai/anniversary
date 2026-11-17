import Foundation

@main
struct AnniversaryDaysTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ value: String) -> Date {
            let parts = value.split(separator: "-").map { Int($0)! }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
        }
        func expect(_ start: String, _ today: String, remaining: Int, elapsed: Int? = nil, next: String? = nil) {
            guard let days = ShiriAnniversaryDays(start: start, today: date(today), calendar: calendar) else { fatalError("Unexpected invalid date") }
            precondition(days.remaining == remaining, "\(start) at \(today): \(days.remaining) != \(remaining)")
            if let elapsed { precondition(days.elapsed == elapsed) }
            if let next { precondition(calendar.isDate(days.nextDate, inSameDayAs: date(next))) }
        }
        expect("2022-11-20", "2026-11-13", remaining: 7, elapsed: 1454, next: "2026-11-20")
        expect("2022-11-20", "2026-11-20", remaining: 0, elapsed: 1461)
        expect("2022-11-20", "2026-11-21", remaining: 364, next: "2027-11-20")
        expect("2026-11-20", "2026-11-13", remaining: 7, elapsed: 0)
        expect("2028-02-29", "2026-11-13", remaining: 473, elapsed: 0, next: "2028-02-29")
        expect("2020-02-29", "2025-02-28", remaining: 0, next: "2025-02-28")
        expect("2020-02-29", "2024-02-28", remaining: 1, next: "2024-02-29")
        expect("2020-02-29", "2025-03-01", remaining: 364, next: "2026-02-28")
        expect("2020-01-01", "2026-12-31", remaining: 1, next: "2027-01-01")
        precondition(ShiriAnniversaryDays(start: "2023-02-29", today: date("2026-11-13"), calendar: calendar) == nil)
        precondition(ShiriAnniversaryDays(start: "invalid", today: Date(), calendar: calendar) == nil)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        expect("2024-03-10", "2024-03-11", remaining: 364, elapsed: 1)
        expect("2024-11-03", "2024-11-04", remaining: 364, elapsed: 1)
        print("13 iOS anniversary date checks passed (including leap day, future dates and DST).")
    }
}
