import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Solar")
struct SolarTests {
  private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day))!
  }

  /// Minutes past midnight UTC, which is what published tables give.
  private func minutesUTC(_ instant: Date) -> Double {
    let components = utc.dateComponents([.hour, .minute], from: instant)
    return Double(components.hour ?? 0) * 60 + Double(components.minute ?? 0)
  }

  /// Checked against published times rather than against itself. Berlin on the
  /// solstice: sunrise 02:43 UTC, sunset 19:33 UTC.
  @Test("Berlin at the summer solstice matches published times")
  func berlinSolstice() throws {
    let times = Solar.times(
      date: date(2024, 6, 21), latitude: 52.52, longitude: 13.40, calendar: utc
    )
    let sunrise = try #require(times.sunrise)
    let sunset = try #require(times.sunset)

    #expect(abs(minutesUTC(sunrise) - (2 * 60 + 43)) <= 3)
    #expect(abs(minutesUTC(sunset) - (19 * 60 + 33)) <= 3)
  }

  /// A second place, in the other hemisphere and on the other side of the
  /// prime meridian, so a sign error cannot pass both.
  @Test("Sydney in midwinter matches published times")
  func sydneyMidwinter() throws {
    // Sunrise 21:00 UTC on the 20th, sunset 06:54 UTC — Sydney is UTC+10.
    let times = Solar.times(
      date: date(2024, 6, 21), latitude: -33.87, longitude: 151.21, calendar: utc
    )
    let sunrise = try #require(times.sunrise)
    let sunset = try #require(times.sunset)

    #expect(abs(minutesUTC(sunrise) - 21 * 60) <= 4)
    #expect(abs(minutesUTC(sunset) - (6 * 60 + 54)) <= 4)
  }

  /// The case a schedule must survive rather than crash on. Above the Arctic
  /// Circle in June the sun does not set at all, and there is no time to
  /// schedule anything for.
  @Test("Polar day has neither a sunrise nor a sunset")
  func polarDay() {
    let times = Solar.times(
      date: date(2024, 6, 21), latitude: 78.22, longitude: 15.63, calendar: utc
    )
    #expect(times.isPolar)
  }

  @Test("Polar night has neither either")
  func polarNight() {
    let times = Solar.times(
      date: date(2024, 12, 21), latitude: 78.22, longitude: 15.63, calendar: utc
    )
    #expect(times.isPolar)
  }

  @Test("The sun always rises before it sets, all year, at a mid latitude")
  func orderIsSane() throws {
    for month in 1 ... 12 {
      let times = Solar.times(
        date: date(2024, month, 15), latitude: 52.52, longitude: 13.40, calendar: utc
      )
      let sunrise = try #require(times.sunrise, "no sunrise in month \(month)")
      let sunset = try #require(times.sunset, "no sunset in month \(month)")
      #expect(sunrise < sunset, "sunrise came after sunset in month \(month)")
    }
  }

  /// Days are longer in summer than in winter, north of the equator, and the
  /// other way round south of it. A sign error survives every single-place test
  /// and dies here.
  @Test("Day length follows the season, in both hemispheres")
  func seasonalDayLength() throws {
    func dayLength(latitude: Double, month: Int) throws -> TimeInterval {
      let times = Solar.times(
        date: date(2024, month, 21), latitude: latitude, longitude: 0, calendar: utc
      )
      let sunrise = try #require(times.sunrise)
      let sunset = try #require(times.sunset)
      return sunset.timeIntervalSince(sunrise)
    }

    #expect(try dayLength(latitude: 52, month: 6) > dayLength(latitude: 52, month: 12))
    #expect(try dayLength(latitude: -33, month: 6) < dayLength(latitude: -33, month: 12))
  }
}
