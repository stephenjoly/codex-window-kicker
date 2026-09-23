import AppKit
import Combine
import CodexWindowKickerCore
import SwiftUI

@main
struct CodexWindowKickerApp: App {
    @StateObject private var model = KickerViewModel()

    var body: some Scene {
        MenuBarExtra("Codex Window Kicker", systemImage: model.menuBarState.symbolName) {
            KickerPopover(model: model)
                .frame(width: 330)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(paths: model.paths)
                .frame(width: 540, height: 210)
        }
    }
}

@MainActor
final class KickerViewModel: ObservableObject {
    let paths: RuntimePaths
    private let statusReader: any StatusReading
    private let controller: KickerController
    private let openURL: (URL) -> Void
    private var refreshTimer: Timer?

    @Published var status: KickerStatus?
    @Published var launchAgentEnabled: Bool?
    @Published var readError: String?
    @Published var controlStateError: String?
    @Published var actionError: String?
    @Published var successMessage: String?
    @Published var isPerformingAction = false

    init(
        paths: RuntimePaths = .default,
        statusReader: (any StatusReading)? = nil,
        controller: KickerController? = nil,
        openURL: @escaping (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        }
    ) {
        self.paths = paths
        self.statusReader = statusReader ?? FileStatusReader(fileURL: paths.statusURL)
        self.controller = controller ?? KickerController(paths: paths)
        self.openURL = openURL
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var menuBarState: MenuBarState {
        if actionError != nil || readError != nil || controlStateError != nil { return .warning }
        if launchAgentEnabled == false { return .paused }
        guard launchAgentEnabled == true,
              let status,
              status.schemaVersion == 1,
              status.lastError?.isEmpty != false,
              let lastPollAt = status.lastPollAt,
              Date.now.timeIntervalSince(lastPollAt) <= 900 else {
            return .warning
        }
        return .enabled
    }

    /// The toggle always reflects launchd, never a possibly old status file.
    var enabled: Bool { launchAgentEnabled == true }

    func refresh() {
        do {
            status = try statusReader.readStatus()
            readError = nil
        } catch {
            status = nil
            readError = "Could not read status: \(error.localizedDescription)"
        }
        do {
            launchAgentEnabled = try controller.launchAgentEnabled()
            controlStateError = nil
        } catch {
            launchAgentEnabled = nil
            controlStateError = "Could not check LaunchAgent: \(error.localizedDescription)"
        }
    }

    func setEnabled(_ enabled: Bool) {
        perform(enabled ? .enable : .disable)
    }

    func dryCheck() { perform(.dryCheck) }

    func showLogs() {
        try? FileManager.default.createDirectory(at: paths.runtimeDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: paths.logURL.path) {
            _ = FileManager.default.createFile(atPath: paths.logURL.path, contents: nil)
        }
        openURL(paths.logURL)
    }

    private func perform(_ action: KickerAction) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        actionError = nil
        successMessage = nil
        let controller = controller
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return CommandOutcome.completed(try controller.perform(action))
                } catch {
                    return CommandOutcome.failed(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            self.isPerformingAction = false
            switch outcome {
            case .completed(let command) where command.succeeded:
                self.successMessage = command.message.isEmpty ? "Command completed." : command.message
                self.refresh()
            case .completed(let command):
                self.actionError = command.message.isEmpty ? "Command failed (exit \(command.exitCode))." : command.message
                self.refresh()
            case .failed(let message):
                self.actionError = message
            }
        }
    }
}

private enum CommandOutcome: Sendable {
    case completed(CommandResult)
    case failed(String)
}

private extension MenuBarState {
    var symbolName: String {
        switch self {
        case .enabled: "bolt.circle.fill"
        case .paused: "pause.circle"
        case .warning: "exclamationmark.triangle.fill"
        }
    }
}

private struct KickerPopover: View {
    @ObservedObject var model: KickerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Codex Window Kicker", systemImage: model.menuBarState.symbolName)
                    .font(.headline)
                Spacer()
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { model.enabled },
                        set: { newValue in model.setEnabled(newValue) }
                    )
                )
                    .labelsHidden()
                    .disabled(model.isPerformingAction)
                    .accessibilityLabel("Enabled")
            }

            Divider()

            DetailRow(label: "Last poll", value: StatusPresentation.timestamp(model.status?.lastPollAt))
            DetailRow(label: "Five-hour usage", value: StatusPresentation.usage(model.status?.usagePercent))
            DetailRow(label: "Resets", value: StatusPresentation.reset(model.status?.resetAt))
            DetailRow(label: "Last kickoff", value: StatusPresentation.timestamp(model.status?.lastKickoffAt))

            if let error = model.readError ?? model.controlStateError ?? model.actionError ?? model.status?.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = model.successMessage, !message.isEmpty {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("View Logs") { model.showLogs() }
                Button("Run Dry Check") { model.dryCheck() }
                    .disabled(model.isPerformingAction)
                Spacer()
                SettingsLink { Text("Settings") }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .onAppear { model.refresh() }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}

private struct SettingsView: View {
    let paths: RuntimePaths

    var body: some View {
        Form {
            LabeledContent("Runtime folder") { Text(paths.runtimeDirectory.path).textSelection(.enabled) }
            LabeledContent("Status file") { Text(paths.statusURL.path).textSelection(.enabled) }
            LabeledContent("Log file") { Text(paths.logURL.path).textSelection(.enabled) }
            LabeledContent("Refresh") { Text("Every 15 seconds and whenever the popover opens") }
        }
        .formStyle(.grouped)
        .padding()
    }
}
