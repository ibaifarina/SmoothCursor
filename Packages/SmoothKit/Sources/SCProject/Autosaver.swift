import Foundation
import Observation
import SCCore

/// Debounced, off-main writes of `project.json`. Call `schedule` on every edit; `flush` on close.
@MainActor
@Observable
public final class Autosaver {
    public enum Status: Equatable { case saved, pending, saving, failed(String) }

    public let packageURL: URL
    public private(set) var status: Status = .saved
    @ObservationIgnored public var delay: Duration = .milliseconds(600)

    @ObservationIgnored private var pending: Project?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(packageURL: URL) {
        self.packageURL = packageURL
    }

    public func schedule(_ project: Project) {
        pending = project
        status = .pending
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    public func flush() async {
        task?.cancel()
        guard var project = pending else { return }
        pending = nil
        status = .saving
        project.modifiedAt = .now
        let url = packageURL
        do {
            try await Task.detached(priority: .utility) { try ProjectPackage.write(project, to: url) }.value
            if pending == nil { status = .saved }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Blocking write for app termination, when there's no time to hop threads.
    public func flushSynchronously() {
        task?.cancel()
        guard var project = pending else { return }
        pending = nil
        project.modifiedAt = .now
        try? ProjectPackage.write(project, to: packageURL)
        status = .saved
    }
}
