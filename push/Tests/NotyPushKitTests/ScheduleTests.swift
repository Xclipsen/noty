import Foundation
import XCTest
import NotebookCore
@testable import NotyPushKit

final class ScheduleTests: XCTestCase {
    let config = PollScheduleConfig()

    func testWeekdaysHourlyFiveToTwentyNothingAtNight() {
        // Monday 09.11.2026
        XCTAssertEqual(PollSchedule.next(after: at(2026, 11, 9, 10, 2), minute: 7, config: config, calendar: berlinCalendar), at(2026, 11, 9, 10, 7))
        XCTAssertEqual(PollSchedule.next(after: at(2026, 11, 9, 10, 7), minute: 7, config: config, calendar: berlinCalendar), at(2026, 11, 9, 11, 7))
        XCTAssertEqual(PollSchedule.next(after: at(2026, 11, 9, 20, 30), minute: 7, config: config, calendar: berlinCalendar), at(2026, 11, 10, 5, 7))
        XCTAssertEqual(PollSchedule.next(after: at(2026, 11, 10, 0, 30), minute: 0, config: config, calendar: berlinCalendar), at(2026, 11, 10, 5, 0))
        XCTAssertTrue(PollSchedule.isPollHour(at(2026, 11, 9, 5, 10), config: config, calendar: berlinCalendar))
        XCTAssertTrue(PollSchedule.isPollHour(at(2026, 11, 9, 20, 59), config: config, calendar: berlinCalendar))
        XCTAssertFalse(PollSchedule.isPollHour(at(2026, 11, 9, 21, 0), config: config, calendar: berlinCalendar))
        XCTAssertFalse(PollSchedule.isPollHour(at(2026, 11, 9, 4, 59), config: config, calendar: berlinCalendar))
    }

    func testWeekendEveryTwoHours() {
        // Friday 13.11. evening → Saturday 8:00; Saturday 8:05 → 10:05; Sunday 20:30 → Monday 5:00.
        XCTAssertEqual(PollSchedule.next(after: at(2026, 11, 13, 20, 30), minute: 5, config: config, calendar: berlinCalendar), at(2026, 11, 14, 8, 5))
        XCTAssertEqual(PollSchedule.next(after: at(2026, 11, 14, 8, 5), minute: 5, config: config, calendar: berlinCalendar), at(2026, 11, 14, 10, 5))
        XCTAssertEqual(PollSchedule.next(after: at(2026, 11, 15, 20, 30), minute: 5, config: config, calendar: berlinCalendar), at(2026, 11, 16, 5, 5))
        XCTAssertFalse(PollSchedule.isPollHour(at(2026, 11, 14, 9, 0), config: config, calendar: berlinCalendar))
    }

    func testDaylightSavingChangeKeepsWallClock() {
        // 29.03.2026 is a Sunday with the switch to summer time; Monday 30.03. 5:00 local.
        XCTAssertEqual(PollSchedule.next(after: at(2026, 3, 29, 20, 30), minute: 0, config: config, calendar: berlinCalendar), at(2026, 3, 30, 5, 0))
        XCTAssertEqual(berlinCalendar.component(.hour, from: at(2026, 3, 30, 5, 0)), 5)
    }

    func testBackoffGrowsAndRespectsSchedule() {
        XCTAssertEqual(PollSchedule.backoff(failures: 0), 0)
        XCTAssertEqual(PollSchedule.backoff(failures: 1), 15 * 60)
        XCTAssertEqual(PollSchedule.backoff(failures: 3), 60 * 60)
        XCTAssertEqual(PollSchedule.backoff(failures: 20), 12 * 3600)
        // 5 failures (4 h) at Monday 10:07 → 14:07.
        XCTAssertEqual(PollSchedule.nextAfterAttempt(now: at(2026, 11, 9, 10, 7), failures: 5, minute: 7, config: config, calendar: berlinCalendar),
                       at(2026, 11, 9, 14, 7))
        // No failure: the next hour.
        XCTAssertEqual(PollSchedule.nextAfterAttempt(now: at(2026, 11, 9, 10, 7), failures: 0, minute: 7, config: config, calendar: berlinCalendar),
                       at(2026, 11, 9, 11, 7))
        // A long backoff in the evening lands in the morning window, never at night.
        let late = PollSchedule.nextAfterAttempt(now: at(2026, 11, 9, 19, 7), failures: 6, minute: 7, config: config, calendar: berlinCalendar)
        XCTAssertEqual(late, at(2026, 11, 10, 5, 7))
    }

    func testQuietHoursUseCoreSettings() {
        let settings = DeviceSettings()
        XCTAssertTrue(settings.isQuiet(at(2026, 11, 9, 21, 0), calendar: berlinCalendar))
        XCTAssertTrue(settings.isQuiet(at(2026, 11, 10, 5, 59), calendar: berlinCalendar))
        XCTAssertFalse(settings.isQuiet(at(2026, 11, 10, 6, 0), calendar: berlinCalendar))
        XCTAssertFalse(settings.isQuiet(at(2026, 11, 9, 20, 59), calendar: berlinCalendar))
    }

    func testWindowIsTodayPlusDays() {
        let window = PollSchedule.window(now: at(2026, 11, 9, 23, 30), days: 14, calendar: berlinCalendar)
        XCTAssertEqual(window.start.description, "2026-11-09")
        XCTAssertEqual(window.end.description, "2026-11-23")
    }

    func testConfigValidation() throws {
        XCTAssertEqual(testConfig().problems, [])
        var bad = testConfig(); bad.listenHost = "0.0.0.0"; bad.allowedBundleIDs = []; bad.maxDevices = 0
        XCTAssertEqual(bad.problems.count, 3)
        let decoded = try JSONDecoder().decode(PushConfig.self, from: Data(#"{"apnsKeyID":"ABCDE12345","teamID":"BAFXLQ964V","allowedBundleIDs":["a.b.c"],"schedule":{"weekendHours":[9]}}"#.utf8))
        XCTAssertEqual(decoded.maxDevices, 5)
        XCTAssertEqual(decoded.schedule.weekendHours, [9])
        XCTAssertEqual(decoded.schedule.weekdayHours, Array(5...20))
        XCTAssertEqual(PushConfig.secretPath("data.key", configPath: "/etc/noty-push/config.json", environment: ["CREDENTIALS_DIRECTORY": "/run/credentials/x"]),
                       "/run/credentials/x/data.key")
        XCTAssertEqual(PushConfig.secretPath("data.key", configPath: "/etc/noty-push/config.json", environment: [:]), "/etc/noty-push/data.key")
    }
}
