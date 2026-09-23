import Foundation

public struct RuntimePaths: Equatable, Sendable {
    public let runtimeDirectory: URL
    public let workerURL: URL
    public let controlURL: URL
    public let statusURL: URL
    public let logURL: URL

    public init(runtimeDirectory: URL) {
        self.runtimeDirectory = runtimeDirectory
        workerURL = runtimeDirectory.appending(path: "codex-window-kicker.zsh")
        controlURL = runtimeDirectory.appending(path: "codex-window-kicker-control.zsh")
        statusURL = runtimeDirectory.appending(path: "state/status.json")
        logURL = runtimeDirectory.appending(path: "codex-window-kicker.log")
    }

    public static var `default`: RuntimePaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return RuntimePaths(runtimeDirectory: home.appending(path: "Library/Application Support/CodexWindowKicker"))
    }
}

public protocol StatusReading: Sendable {
    func readStatus() throws -> KickerStatus?
}

public struct FileStatusReader: StatusReading {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func readStatus() throws -> KickerStatus? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(KickerStatus.self, from: Data(contentsOf: fileURL))
    }
}

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitCode == 0 }
    public var message: String {
        let candidate = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty { return candidate }
        return standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String]) throws -> CommandResult
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], environment: [String: String] = [:]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, requested in requested }
        }
        // Files avoid a deadlock when a command writes more than a pipe buffer
        // before it exits (notably `launchctl print` from the status command).
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let outputURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let errorURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        try output.close()
        try errors.close()
        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
        )
    }
}

public enum KickerAction: Sendable {
    case enable
    case disable
    case dryCheck
}

public enum KickerControllerError: LocalizedError, Sendable {
    case unavailableLaunchAgentState(String)

    public var errorDescription: String? {
        switch self {
        case .unavailableLaunchAgentState(let message):
            return message.isEmpty ? "The control command did not report a LaunchAgent state." : message
        }
    }
}

public struct KickerController: Sendable {
    public let paths: RuntimePaths
    private let runner: any CommandRunning

    public init(paths: RuntimePaths = .default, runner: any CommandRunning = ProcessRunner()) {
        self.paths = paths
        self.runner = runner
    }

    public func perform(_ action: KickerAction) throws -> CommandResult {
        switch action {
        case .enable:
            return try runner.run(executable: paths.controlURL, arguments: ["on"], environment: [:])
        case .disable:
            return try runner.run(executable: paths.controlURL, arguments: ["off"], environment: [:])
        case .dryCheck:
            // The worker owns every prompt; DRY_RUN keeps this invocation observational.
            return try runner.run(executable: paths.workerURL, arguments: [], environment: ["DRY_RUN": "1"])
        }
    }

    /// Reads launchd's state through the supported control command.
    /// A missing or unparseable state is surfaced as an error so the UI can
    /// show its warning icon instead of trusting stale status JSON.
    public func launchAgentEnabled() throws -> Bool? {
        let result = try runner.run(executable: paths.controlURL, arguments: ["status"], environment: [:])
        guard result.succeeded else { throw KickerControllerError.unavailableLaunchAgentState(result.message) }
        let message = result.standardOutput.lowercased()
        if message.contains("is enabled") { return true }
        if message.contains("is disabled") { return false }
        throw KickerControllerError.unavailableLaunchAgentState(result.message)
    }
}
