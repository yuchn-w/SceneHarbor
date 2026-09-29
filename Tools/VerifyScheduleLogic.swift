import Foundation

@main
struct VerifyScheduleLogic {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        func date(day: Int = 25, hour: Int, minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(
                year: 2026,
                month: 7,
                day: day,
                hour: hour,
                minute: minute
            ))!
        }

        precondition(DayNightScheduleLogic.period(at: date(hour: 5, minute: 59), calendar: calendar) == .night)
        precondition(DayNightScheduleLogic.period(at: date(hour: 6), calendar: calendar) == .day)
        precondition(DayNightScheduleLogic.period(at: date(hour: 17, minute: 59), calendar: calendar) == .day)
        precondition(DayNightScheduleLogic.period(at: date(hour: 18), calendar: calendar) == .night)

        let eveningIndex = DayNightScheduleLogic.dailyRotationIndex(
            at: date(day: 25, hour: 23, minute: 59),
            period: .night,
            itemCount: 7,
            calendar: calendar
        )
        let afterMidnightIndex = DayNightScheduleLogic.dailyRotationIndex(
            at: date(day: 26, hour: 0, minute: 1),
            period: .night,
            itemCount: 7,
            calendar: calendar
        )
        precondition(eveningIndex == afterMidnightIndex)

        let firstDayIndex = DayNightScheduleLogic.dailyRotationIndex(
            at: date(day: 25, hour: 12),
            period: .day,
            itemCount: 5,
            calendar: calendar
        )
        let nextDayIndex = DayNightScheduleLogic.dailyRotationIndex(
            at: date(day: 26, hour: 12),
            period: .day,
            itemCount: 5,
            calendar: calendar
        )
        precondition(nextDayIndex == (firstDayIndex + 1) % 5)
        print("日夜排程自我檢查通過")
    }
}
