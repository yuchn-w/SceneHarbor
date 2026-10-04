import Foundation

struct HarborSolarLocation: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var name: String? = nil

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

enum HarborSolarEvent: String, Codable, CaseIterable, Sendable { case sunrise, sunset }

enum HarborSolarTimes {
    /// Approximate apparent sunrise/sunset using the NOAA fractional-year
    /// equations (90.833° zenith). No network or device location is involved.
    /// https://gml.noaa.gov/grad/solcalc/solareqns.PDF
    /// A missing event (polar day/night) is deliberately not replaced by a
    /// guessed clock time. The schedule can explain the unavailable boundary.
    static func date(for event: HarborSolarEvent, on day: Date,
                     location: HarborSolarLocation, timeZone: TimeZone) -> Date? {
        guard location.isValid else { return nil }
        var local = Calendar(identifier: .gregorian); local.timeZone = timeZone
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = local.dateComponents([.year, .month, .day], from: day)
        guard let utcDay = utc.date(from: components) else { return nil }
        for delta in -1...1 {
            guard let candidateDay = utc.date(byAdding: .day, value: delta, to: utcDay),
                  let dayOfYear = utc.ordinality(of: .day, in: .year, for: candidateDay),
                  let yearDays = utc.range(of: .day, in: .year, for: candidateDay)?.count else { continue }
            var minutes = 720.0 - 4 * location.longitude
            var possible = true
            for _ in 0..<3 {
                let gamma = 2 * Double.pi / Double(yearDays) * (Double(dayOfYear - 1) + (minutes / 60 - 12) / 24)
                let equation = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                                        - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
                let declination = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
                    - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
                    - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
                let latitude = location.latitude * .pi / 180
                let cosine = cos(90.833 * .pi / 180) / (cos(latitude) * cos(declination))
                    - tan(latitude) * tan(declination)
                guard cosine.isFinite, (-1...1).contains(cosine) else { possible = false; break }
                let hourAngle = acos(cosine) * 180 / .pi * (event == .sunrise ? 1 : -1)
                minutes = 720 - 4 * (location.longitude + hourAngle) - equation
            }
            guard possible else { continue }
            let result = candidateDay.addingTimeInterval(minutes * 60)
            if local.isDate(result, inSameDayAs: day) { return result }
        }
        return nil
    }
}
