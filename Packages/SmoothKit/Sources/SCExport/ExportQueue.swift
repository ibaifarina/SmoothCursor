import Foundation
import Observation
import SCCore
import Synchronization

/// Exports run one at a time in the background; the UI observes their progress.
@MainActor
@Observable
public final class ExportQueue {
    public enum State: Equatable, Sendable {
        case queued
        case running(Double)
        case done
        case failed(String)
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: true
            default: false
            }
        }
    }

    public struct Job: Identifiable, Sendable {
        public let id = UUID()
        public let name: String
        public let destination: URL
        public let projectID: UUID
        public var state: State = .queued
        public var startedAt: Date?
        public var finishedAt: Date?

        /// Seconds left, from the average speed so far.
        public var remaining: TimeInterval? {
            guard case let .running(p) = state, p > 0.02, let startedAt else { return nil }
            return Date().timeIntervalSince(startedAt) * (1 - p) / p
        }
    }

    public private(set) var jobs: [Job] = []
    @ObservationIgnored private var requests: [UUID: ExportRequest] = [:]
    @ObservationIgnored private var running: (id: UUID, session: ExportSession)?

    public init() {}

    public var isBusy: Bool { jobs.contains { !$0.state.isFinished } }

    public func activeJob(for projectID: UUID) -> Job? {
        jobs.last { $0.projectID == projectID && !$0.state.isFinished }
    }

    @discardableResult
    public func enqueue(_ request: ExportRequest, name: String) -> UUID {
        let job = Job(name: name, destination: request.destination, projectID: request.project.id)
        jobs.append(job)
        requests[job.id] = request
        startNext()
        return job.id
    }

    public func cancel(_ id: UUID) {
        if running?.id == id {
            running?.session.cancel()
        } else if let i = jobs.firstIndex(where: { $0.id == id }), !jobs[i].state.isFinished {
            jobs[i].state = .cancelled
            requests[id] = nil
        }
    }

    public func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    private func startNext() {
        guard running == nil, let index = jobs.firstIndex(where: { $0.state == .queued }),
              let request = requests[jobs[index].id] else { return }
        let id = jobs[index].id
        let session = ExportSession(request: request)
        running = (id, session)
        jobs[index].state = .running(0)
        jobs[index].startedAt = .now

        Task.detached(priority: .userInitiated) { [weak self] in
            let lastReport = Mutex(Date.distantPast)
            let result: State
            do {
                try await session.run { p in
                    // ~10 UI updates per second is plenty.
                    let now = Date()
                    let due = lastReport.withLock { last in
                        guard now.timeIntervalSince(last) > 0.1 || p.framesRendered == p.totalFrames else { return false }
                        last = now
                        return true
                    }
                    guard due else { return }
                    Task { @MainActor in self?.update(id, .running(p.fraction)) }
                }
                result = .done
            } catch ExportError.cancelled {
                result = .cancelled
            } catch {
                result = .failed(error.localizedDescription)
            }
            await self?.finish(id, result)
        }
    }

    private func update(_ id: UUID, _ state: State) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), !jobs[i].state.isFinished else { return }
        jobs[i].state = state
    }

    private func finish(_ id: UUID, _ state: State) {
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].state = state
            jobs[i].finishedAt = .now
        }
        requests[id] = nil
        running = nil
        startNext()
    }
}
