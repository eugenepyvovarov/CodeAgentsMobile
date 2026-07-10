import XCTest
@testable import CodeAgentsMobile

final class TaskScheduleFormatterOnceTests: XCTestCase {
    func testOnceSummaryIncludesDateAndTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let runAt = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 9, minute: 30))!

        let task = AgentScheduledTask(
            projectId: UUID(),
            title: "Once",
            prompt: "hello",
            isEnabled: true,
            timeZoneId: "UTC",
            frequency: .once,
            interval: 1,
            dayOfMonth: 15,
            monthOfYear: 3,
            timeOfDayMinutes: 9 * 60 + 30,
            nextRunAt: runAt
        )

        let summary = TaskScheduleFormatter.summary(for: task, calendar: calendar)
        XCTAssertTrue(summary.hasPrefix("Once on"), "summary should start with Once on: \(summary)")
        XCTAssertTrue(summary.contains("at"), "summary should include time: \(summary)")
    }

    func testOnceIsOneShot() {
        XCTAssertTrue(TaskFrequency.once.isOneShot)
        XCTAssertFalse(TaskFrequency.daily.isOneShot)
    }
}
