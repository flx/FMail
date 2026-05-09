import Foundation

extension Date {
    /// Compact format used in the threads list and search results: time-only
    /// for today, month+day for this year, year+month+day for older dates.
    func listFormat(now: Date = .now) -> Date.FormatStyle {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return .dateTime.hour().minute() }
        if cal.isDate(self, equalTo: now, toGranularity: .year) {
            return .dateTime.month(.abbreviated).day()
        }
        return .dateTime.year().month(.abbreviated).day()
    }
}
