import Foundation
import XCTest
@testable import CodexWindowKickerCore

final class ControllerTests: XCTestCase {
    func testEnableAndDisableUseOnlyControlCommand() throws {
        let runner = MockRunner()
        let paths = RuntimePaths(runtimeDirectory: URL(fileURLWithPath: "/runtime"))
        let controller = KickerController(paths: paths, runner: runner)

        _ = try controller.perform(.enable)
        _ = try controller.perform(.disable)

        XCTAssertEqual(runner.calls.map(\.executable.lastPathComponent), ["codex-window-kicker-control.zsh", "codex-window-kicker-control.zsh"])
        XCTAssertEqual(runner.calls.map(\.arguments), [["on"], ["off"]])
    }

    func testDryCheckUsesWorkerWithDryRunAndNeverBuildsPromptArguments() throws {
        let runner = MockRunner()
        let paths = RuntimePaths(runtimeDirectory: URL(fileURLWithPath: "/runtime"))
        let controller = KickerController(paths: paths, runner: runner)

        _ = try controller.perform(.dryCheck)

        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.executable.lastPathComponent, "codex-window-kicker.zsh")
        XCTAssertEqual(call.arguments, [])
        XCTAssertEqual(call.environment, ["DRY_RUN": "1"])
        XCTAssertFalse(call.arguments.joined(separator: " ").contains("pong"))
        XCTAssertFalse(call.arguments.joined(separator: " ").contains("codex"))
    }

    func testPropagatesControlFailure() throws {
        let runner = MockRunner(result: CommandResult(exitCode: 1, standardError: "launchctl failed"))
        let controller = KickerController(paths: RuntimePaths(runtimeDirectory: URL(fileURLWithPath: "/runtime")), runner: runner)
        let result = try controller.perform(.enable)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.message, "launchctl failed")
    }

    func testQueriesLaunchAgentStateThroughControlCommand() throws {
        let runner = MockRunner(result: CommandResult(exitCode: 0, standardOutput: "Codex Window Kicker is enabled.\n"))
        let controller = KickerController(paths: RuntimePaths(runtimeDirectory: URL(fileURLWithPath: "/runtime")), runner: runner)
        XCTAssertEqual(try controller.launchAgentEnabled(), true)
        XCTAssertEqual(runner.calls.first?.arguments, ["status"])
    }

    func testUnreadableLaunchAgentStateIsAnError() throws {
        let runner = MockRunner(result: CommandResult(exitCode: 1, standardError: "launchctl unavailable"))
        let controller = KickerController(paths: RuntimePaths(runtimeDirectory: URL(fileURLWithPath: "/runtime")), runner: runner)
        XCTAssertThrowsError(try controller.launchAgentEnabled()) { error in
            XCTAssertEqual(error.localizedDescription, "launchctl unavailable")
        }
    }
}

private final class MockRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable { let executable: URL; let arguments: [String]; let environment: [String: String] }
    private let result: CommandResult
    private(set) var calls: [Call] = []

    init(result: CommandResult = CommandResult(exitCode: 0)) { self.result = result }

    func run(executable: URL, arguments: [String], environment: [String: String]) throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments, environment: environment))
        return result
    }
}
