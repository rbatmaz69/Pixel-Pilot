import Foundation

/// When the sun rises and sets at a place, on a day.
///
/// The NOAA sunrise/sunset algorithm, which is the standard one and is accurate
/// to about a minute — far better than a brightness schedule needs, and its
/// error is dwarfed by the difference between sunset and when it actually gets
/// dark indoors.
///
/// Pure arithmetic, so it can be checked against published times instead of
/// waited for. Both results are optional, and that is not defensive coding: at
/// high latitudes there are days with no sunrise and no sunset at all, and a
/// schedule that assumed otherwise would either crash or silently stop firing
/// for half the winter.
public enum Solar {
  public struct Times: Sendable, Equatable {
    public let sunrise: Date?
    public let sunset: Date?

    /// True during polar day or polar night, when neither event happens.
    public var isPolar: Bool { sunrise == nil && sunset == nil }
  }

  /// The sun's centre at this angle below the horizon. The conventional value
  /// for sunrise and sunset, allowing for refraction and the sun's radius.
  private static let zenith: Double = 90.833

  public static func times(
    date: Date, latitude: Double, longitude: Double, calendar: Calendar = .current
  ) -> Times {
    let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
    return Times(
      sunrise: event(
        rising: true, date: date, dayOfYear: dayOfYear,
        latitude: latitude, longitude: longitude, calendar: calendar
      ),
      sunset: event(
        rising: false, date: date, dayOfYear: dayOfYear,
        latitude: latitude, longitude: longitude, calendar: calendar
      )
    )
  }

  // swiftlint:disable:next function_parameter_count
  private static func event(
    rising: Bool, date: Date, dayOfYear: Int,
    latitude: Double, longitude: Double, calendar: Calendar
  ) -> Date? {
    let longitudeHour = longitude / 15
    let approximate = Double(dayOfYear) + ((rising ? 6.0 : 18.0) - longitudeHour) / 24

    // The sun's mean anomaly, then its true longitude.
    let meanAnomaly = 0.9856 * approximate - 3.289
    var trueLongitude = meanAnomaly
      + 1.916 * sin(radians(meanAnomaly))
      + 0.020 * sin(radians(2 * meanAnomaly))
      + 282.634
    trueLongitude = wrap(trueLongitude, to: 360)

    // Right ascension, put into the same quadrant as the true longitude —
    // omitting that step is the classic way this algorithm comes out twelve
    // hours wrong for part of the year.
    var rightAscension = degrees(atan(0.91764 * tan(radians(trueLongitude))))
    rightAscension = wrap(rightAscension, to: 360)
    let longitudeQuadrant = floor(trueLongitude / 90) * 90
    let ascensionQuadrant = floor(rightAscension / 90) * 90
    rightAscension = (rightAscension + (longitudeQuadrant - ascensionQuadrant)) / 15

    let sinDeclination = 0.39782 * sin(radians(trueLongitude))
    let cosDeclination = cos(asin(sinDeclination))

    let cosHourAngle = (cos(radians(zenith)) - sinDeclination * sin(radians(latitude)))
      / (cosDeclination * cos(radians(latitude)))

    // Out of range means the sun never reaches the horizon that day: polar day
    // if it never sets, polar night if it never rises.
    guard cosHourAngle >= -1, cosHourAngle <= 1 else { return nil }

    let hourAngle = rising
      ? (360 - degrees(acos(cosHourAngle))) / 15
      : degrees(acos(cosHourAngle)) / 15

    let localMeanTime = hourAngle + rightAscension - 0.06571 * approximate - 6.622
    let utcHours = wrap(localMeanTime - longitudeHour, to: 24)

    // Placed against the *start of the day in UTC*, then handed back as an
    // absolute instant. Building it in local time instead would go wrong on the
    // days a time zone changes.
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    guard let midnightUTC = utc.date(from: components) else { return nil }
    return midnightUTC.addingTimeInterval(utcHours * 3600)
  }

  private static func radians(_ value: Double) -> Double { value * .pi / 180 }
  private static func degrees(_ value: Double) -> Double { value * 180 / .pi }

  private static func wrap(_ value: Double, to limit: Double) -> Double {
    let result = value.truncatingRemainder(dividingBy: limit)
    return result < 0 ? result + limit : result
  }
}
