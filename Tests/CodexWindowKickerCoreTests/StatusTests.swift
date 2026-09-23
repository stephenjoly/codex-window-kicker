import Foundation
import XCTest
@testable import CodexWindowKickerCore

final class StatusTests: XCTestCase {
    func testDecodesCompleteVersionedStatus() throws {
        let data = Data("""
        {"schemaVersion":1,"enabled":true,"lastPollAt":"2026-09-23T10:00:00Z","usagePercent":12.5,"resetAt":"2026-09-23T15:00:00Z","lastKickoffAt":"2026-09-23T09:59:00Z","lastError":null}
        """.utf8)

        let status = try JSONDecoder().decode(KickerStatus.self, from: data)
        XCTAssertEqual(status.schemaVersion, 1)
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.usagePercent, 12.5)
        XCTAssertNil(status.lastError)
        XCTAssertEqual(StatusDateCodec.string(from: try XCTUnwrap(status.lastPollAt)), "2026-09-23T10:00:00Z")
    }

    func testDecodesNullFieldsAndIgnoresFutureFields() throws {
        let data = Data("""
        {"schemaVersion":2,"enabled":false,"lastPollAt":null,"usagePercent":null,"resetAt":null,"lastKickoffAt":null,"lastError":null,"futureWorkerField":"safe"}
        """.utf8)
        let status = try JSONDecoder().decode(KickerStatus.self, from: data)
        XCTAssertEqual(status.schemaVersion, 2)
        XCTAssertFalse(status.enabled)
        XCTAssertNil(status.lastPollAt)
        XCTAssertNil(status.usagePercent)
    }

    func testRejectsMalformedTimestamp() {
        let data = Data(#"{"schemaVersion":1,"enabled":true,"lastPollAt":"later","usagePercent":null,"resetAt":null,"lastKickoffAt":null,"lastError":null}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KickerStatus.self, from: data))
    }

    func testDerivesMenuBarStates() {
        let now = Date(timeIntervalSince1970: 10_000)
        let healthy = KickerStatus(enabled: true, lastPollAt: now.addingTimeInterval(-60))
        XCTAssertEqual(MenuBarState.derive(status: healthy, now: now), .enabled)
        XCTAssertEqual(MenuBarState.derive(status: KickerStatus(enabled: false), now: now), .paused)
        XCTAssertEqual(MenuBarState.derive(status: healthy, now: now.addingTimeInterval(901)), .warning)
        XCTAssertEqual(MenuBarState.derive(status: KickerStatus(enabled: true, lastPollAt: now, lastError: "codexbar missing"), now: now), .warning)
    }

    func testFormatsUsageAndUnavailableValues() {
        XCTAssertEqual(StatusPresentation.usage(23.46), "23.5%")
        XCTAssertEqual(StatusPresentation.usage(nil), "Unavailable")
        XCTAssertEqual(StatusPresentation.timestamp(nil), "Unavailable")
    }
}
