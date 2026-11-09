import XCTest
@testable import CoreModel

final class BotScheduleSpecNextOccurrenceTests: XCTestCase {
    /// WHY: Schedule Tasks showed no Next run for Bot schedules because nothing computed one;
    /// the label must be the real next slot, for JSON specs and for notes written by older versions.
    func test_nextOccurrenceFollowsTheSavedTimeInItsTimeZone() throws {
        var spec = BotScheduleSpec(frequency: .daily, timeZoneIdentifier: "UTC")
        spec.localTimeHour = 7
        spec.localTimeMinute = 0
        let after = Date(timeIntervalSince1970: 1_800_000_000)
        let next = try XCTUnwrap(spec.nextOccurrence(after: after))
        XCTAssertGreaterThan(next, after)
        XCTAssertLessThanOrEqual(next.timeIntervalSince(after), 24 * 3600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(calendar.component(.hour, from: next), 7)
        XCTAssertEqual(calendar.component(.minute, from: next), 0)
    }

    func test_nextOccurrenceExistsForNoteOnlySchedules() throws {
        let spec = try XCTUnwrap(BotScheduleSpec.parseDisplayNote("Weekdays 18:00"))
        XCTAssertNotNil(spec.nextOccurrence(after: Date()))
    }

    func test_spentOneTimeScheduleHasNoNextOccurrence() {
        let spec = BotScheduleSpec(frequency: .once, scheduledDate: Date(timeIntervalSince1970: 1_000), timeZoneIdentifier: "UTC")
        XCTAssertNil(spec.nextOccurrence(after: Date(timeIntervalSince1970: 2_000)))
    }
}
