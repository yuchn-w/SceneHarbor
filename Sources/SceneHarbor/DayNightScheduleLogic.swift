import Foundation

enum DayNightScheduleLogic {
    static let defaultDayStartMinute = 6 * 60
    static let defaultNightStartMinute = 18 * 60

    static func period(
        at date: Date,
        dayStartMinute: Int = defaultDayStartMinute,
        nightStartMinute: Int = defaultNightStartMinute,
        calendar: Calendar = .autoupdatingCurrent
    ) -> WallpaperSchedulePeriod {
        HarborPlaylistScheduleResolver.period(at: date, dayStartMinute: dayStartMinute,
                                              nightStartMinute: nightStartMinute, calendar: calendar)
    }

    static func nextTransition(
        after date: Date,
        dayStartMinute: Int = defaultDayStartMinute,
        nightStartMinute: Int = defaultNightStartMinute,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        HarborPlaylistScheduleResolver.nextTransition(after: date, dayStartMinute: dayStartMinute,
                                                       nightStartMinute: nightStartMinute, calendar: calendar)
    }

    static func dailyRotationIndex(
        at date: Date,
        period: WallpaperSchedulePeriod,
        itemCount: Int,
        dayStartMinute: Int = defaultDayStartMinute,
        nightStartMinute: Int = defaultNightStartMinute,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int {
        guard itemCount > 1 else { return 0 }
        let active = Self.period(at: date, dayStartMinute: dayStartMinute,
                                nightStartMinute: nightStartMinute, calendar: calendar)
        guard active == period else { return 0 }
        let startMinute = period == .day ? dayStartMinute : nightStartMinute
        let startOfDay = calendar.startOfDay(for: date)
        let boundaryToday = HarborPlaylistScheduleResolver.boundaryDate(
            minute: startMinute, on: startOfDay, calendar: calendar
        ) ?? date
        let anchorDate = boundaryToday <= date ? boundaryToday : (calendar.date(byAdding: .day, value: -1, to: boundaryToday) ?? date)
        let dayNumber = calendar.ordinality(of: .day, in: .era, for: anchorDate) ?? 1
        return (dayNumber - 1) % itemCount
    }
}
