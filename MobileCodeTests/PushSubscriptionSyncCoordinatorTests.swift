import XCTest
@testable import CodeAgentsMobile

final class PushSubscriptionSyncCoordinatorTests: XCTestCase {
    func testConcurrentRequestsAreSerializedAndCoalesced() async {
        let coordinator = PushSubscriptionSyncCoordinator()
        let probe = PushSubscriptionSyncProbe()

        let firstRequest = Task {
            await coordinator.request {
                await probe.runPass()
            }
        }

        await probe.waitUntilFirstPassStarts()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    await coordinator.request {
                        await probe.runPass()
                    }
                }
            }
        }

        await probe.releaseFirstPass()
        await firstRequest.value

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.passCount, 2)
        XCTAssertEqual(snapshot.maximumConcurrentPasses, 1)
    }

    func testLaterRequestStartsANewPassAfterCoordinatorBecomesIdle() async {
        let coordinator = PushSubscriptionSyncCoordinator()
        let counter = PushSubscriptionSyncCounter()

        await coordinator.request {
            await counter.increment()
        }
        await coordinator.request {
            await counter.increment()
        }

        let value = await counter.value
        XCTAssertEqual(value, 2)
    }
}

private actor PushSubscriptionSyncProbe {
    private var passCount = 0
    private var activePasses = 0
    private var maximumConcurrentPasses = 0
    private var firstPassStarted = false
    private var firstPassStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstPassRelease: CheckedContinuation<Void, Never>?

    func runPass() async {
        passCount += 1
        activePasses += 1
        maximumConcurrentPasses = max(maximumConcurrentPasses, activePasses)

        if passCount == 1 {
            firstPassStarted = true
            let waiters = firstPassStartWaiters
            firstPassStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                firstPassRelease = continuation
            }
        }

        activePasses -= 1
    }

    func waitUntilFirstPassStarts() async {
        guard !firstPassStarted else { return }
        await withCheckedContinuation { continuation in
            firstPassStartWaiters.append(continuation)
        }
    }

    func releaseFirstPass() {
        firstPassRelease?.resume()
        firstPassRelease = nil
    }

    func snapshot() -> (passCount: Int, maximumConcurrentPasses: Int) {
        (passCount, maximumConcurrentPasses)
    }
}

private actor PushSubscriptionSyncCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
