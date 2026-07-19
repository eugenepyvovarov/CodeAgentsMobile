import XCTest
@testable import CodeAgentsMobile

final class AuthorSupportPromptScheduleTests: XCTestCase {
    private var suiteName = ""
    private var userDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "AuthorSupportPromptScheduleTests.\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        try super.tearDownWithError()
    }

    func testPresentsImmediatelyWithoutPreviousPresentation() {
        let schedule = AuthorSupportPromptSchedule(userDefaults: userDefaults)

        XCTAssertTrue(schedule.shouldPresent(at: referenceDate))
    }

    func testDoesNotPresentBeforeFourteenDays() {
        let schedule = AuthorSupportPromptSchedule(userDefaults: userDefaults)
        schedule.recordPresentation(at: referenceDate)

        let almostFourteenDays = referenceDate.addingTimeInterval(
            AuthorSupportPromptSchedule.recurrenceInterval - 1
        )

        XCTAssertFalse(schedule.shouldPresent(at: almostFourteenDays))
    }

    func testPresentsAtFourteenDayBoundary() {
        let schedule = AuthorSupportPromptSchedule(userDefaults: userDefaults)
        schedule.recordPresentation(at: referenceDate)

        let fourteenDaysLater = referenceDate.addingTimeInterval(
            AuthorSupportPromptSchedule.recurrenceInterval
        )

        XCTAssertTrue(schedule.shouldPresent(at: fourteenDaysLater))
    }

    func testPermanentOptOutSuppressesFuturePrompts() {
        let schedule = AuthorSupportPromptSchedule(userDefaults: userDefaults)
        schedule.recordPresentation(at: referenceDate)
        schedule.optOutPermanently()

        let muchLater = referenceDate.addingTimeInterval(
            AuthorSupportPromptSchedule.recurrenceInterval * 20
        )

        XCTAssertFalse(schedule.shouldPresent(at: muchLater))
    }

    func testInvalidStoredDatePresentsImmediately() {
        userDefaults.set("not-a-date", forKey: AuthorSupportPromptSchedule.StorageKey.lastPresentedAt)
        let schedule = AuthorSupportPromptSchedule(userDefaults: userDefaults)

        XCTAssertTrue(schedule.shouldPresent(at: referenceDate))
    }

    func testRecordPresentationPersistsDate() {
        let schedule = AuthorSupportPromptSchedule(userDefaults: userDefaults)

        schedule.recordPresentation(at: referenceDate)

        XCTAssertEqual(
            userDefaults.object(forKey: AuthorSupportPromptSchedule.StorageKey.lastPresentedAt) as? Date,
            referenceDate
        )
    }

    private var referenceDate: Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }
}
