import XCTest
@testable import CodexTouchCore

final class DomainTests: XCTestCase {
    func testQuotaParserAcceptsOnlyFiveHourAndSevenDayWindows() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = QuotaParser.parse(windows: [
            WireQuotaWindow(windowDurationMins: 300, usedPercent: 28, resetsAt: 1_700_001_000),
            WireQuotaWindow(windowDurationMins: 10_080, usedPercent: 46, resetsAt: 1_700_002_000),
            WireQuotaWindow(windowDurationMins: 60, usedPercent: 99, resetsAt: 1_700_003_000)
        ], fetchedAt: now)
        XCTAssertEqual(snapshot.lastKnown(.fiveHour)?.remainingPercent, 72)
        XCTAssertEqual(snapshot.lastKnown(.sevenDay)?.remainingPercent, 54)
        XCTAssertEqual(snapshot.lastKnown(.fiveHour)?.resetsAt?.timeIntervalSince1970, 1_700_001_000)
        XCTAssertEqual(snapshot.windows.count, 2)
    }

    func testQuotaClampAndStaleCurrentValue() {
        let fetched = Date(timeIntervalSince1970: 100)
        let snapshot = QuotaParser.parse(windows: [WireQuotaWindow(windowDurationMins: 300, usedPercent: 140, resetsAt: nil)], fetchedAt: fetched)
        XCTAssertEqual(snapshot.lastKnown(.fiveHour)?.remainingPercent, 0)
        XCTAssertNil(snapshot.current(.fiveHour, now: Date(timeIntervalSince1970: 701)))
        XCTAssertEqual(snapshot.freshness(now: Date(timeIntervalSince1970: 701)), .unavailable)
    }

    func testUsageSelectsServiceDateBucketAndKeepsTimezoneMetadata() {
        let zone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let date = ISO8601DateFormatter().date(from: "2026-09-01T00:10:00Z")!
        let usage = UsageSnapshot.fromBuckets([
            DailyUsageBucket(startDate: "2026-09-01", tokens: 12_400),
            DailyUsageBucket(startDate: "2026-08-31", tokens: 9_800)
        ], now: date, timeZone: zone, fetchedAt: date)
        XCTAssertEqual(usage.todayTokens, 12_400)
        XCTAssertEqual(usage.serviceDate, "2026-09-01")
        XCTAssertEqual(usage.serviceTimeZoneIdentifier, zone.identifier)
    }

    func testUsageUsesVisibleUTCFallbackWhenServerOmitsDateMetadata() {
        let date = ISO8601DateFormatter().date(from: "2026-09-01T12:00:00Z")!
        let usage = UsageSnapshot.fromServerBuckets([
            DailyUsageBucket(startDate: "2026-09-01", tokens: 12_400),
            DailyUsageBucket(startDate: "2026-08-31", tokens: 9_800)
        ], serviceDate: nil, serviceTimeZoneIdentifier: nil, now: date, fetchedAt: date)
        XCTAssertEqual(usage.todayTokens, 12_400)
        XCTAssertEqual(usage.serviceDate, "2026-09-01")
        XCTAssertEqual(usage.serviceTimeZoneIdentifier, "UTC (assumed; API omits timezone)")
    }

    func testEffortFallsBackToModelDefault() {
        let model = ModelOption(id: "a", model: "a", displayName: "A", defaultReasoningEffort: "medium", supportedReasoningEfforts: [ReasoningEffortOption(value: "medium", description: "")])
        XCTAssertEqual(model.compatibleEffort(preferred: "high"), "medium")
        XCTAssertEqual(model.compatibleEffort(preferred: "medium"), "medium")
    }

    func testStatusAggregationIsFailClosed() {
        let signals = StatusSignals(connection: .connected, authentication: .authenticated, quotaFreshness: .fresh, usageFreshness: .fresh, pluginTurnInProgress: false, pendingWrite: true)
        XCTAssertEqual(StatusAggregator.severity(signals), .attention)
        XCTAssertEqual(StatusAggregator.severity(StatusSignals(connection: .disconnected, authentication: .authenticated, quotaFreshness: .fresh, usageFreshness: .fresh, pluginTurnInProgress: false, pendingWrite: false)), .offline)
        XCTAssertEqual(StatusAggregator.severity(StatusSignals(connection: .connecting, authentication: .unknown, quotaFreshness: .unavailable, usageFreshness: .unavailable, pluginTurnInProgress: false, pendingWrite: false)), .working)
    }

    @MainActor
    func testRefreshCannotOverwriteSwitchedProfileOrClearPendingWrite() {
        let old = AccountProfile(id: UUID(), alias: "Old", codexHome: URL(fileURLWithPath: "/tmp/old"))
        let target = AccountProfile(id: UUID(), alias: "Target", codexHome: URL(fileURLWithPath: "/tmp/target"))
        let store = DashboardStore(profile: old)
        store.beginConfigurationWrite()
        store.applyRefresh(AppSnapshot(profile: old, connection: .connected), expectedProfileID: old.id)
        XCTAssertTrue(store.snapshot.pendingWrite)

        store.replace(AppSnapshot(profile: target, connection: .connected))
        store.applyRefresh(AppSnapshot(profile: old, connection: .disconnected), expectedProfileID: old.id)
        XCTAssertEqual(store.snapshot.profile.id, target.id)
        XCTAssertEqual(store.snapshot.connection, .connected)
    }
}
