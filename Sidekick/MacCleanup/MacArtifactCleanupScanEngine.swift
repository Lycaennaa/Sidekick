import CoreServices
import Foundation

@MainActor
final class MacArtifactCleanupScanEngine {
    private struct InspectionRequest: Sendable {
        let root: MacArtifactCleanupRoot
        let url: URL
    }

    private struct InspectionOutcome: Sendable {
        let request: InspectionRequest
        let match: MacArtifactMatch?
        let failure: String?
    }

    var onScanResult: ((MacArtifactCleanupRoot, MacArtifactScanResult) -> Void)?
    var onScanFailure: ((MacArtifactCleanupRoot, String) -> Void)?
    var onMatch: ((MacArtifactCleanupRoot, MacArtifactMatch) -> Void)?
    var onInspectionFailure: ((MacArtifactCleanupRoot, URL, String) -> Void)?
    var onRootChanged: (() -> Void)?

    private var running = false
    private var generation: UInt64 = 0
    private var roots: [UUID: MacArtifactCleanupRoot] = [:]
    private var scanTasks: [UUID: Task<MacArtifactScanResult, Error>] = [:]
    private var scanCompletionTasks: [UUID: Task<Void, Never>] = [:]
    private var scanTokens: [UUID: UUID] = [:]
    private var dirtyRoots: Set<UUID> = []
    private var inspections: [String: InspectionRequest] = [:]
    private var inspectionToken: UUID?
    private var inspectionTask: Task<Void, Never>?
    private var inspectionWorker: Task<[InspectionOutcome], Never>?

    func start(roots: [MacArtifactCleanupRoot]) {
        guard !running else { return }
        running = true
        updateRoots(roots)
    }

    func updateRoots(_ newRoots: [MacArtifactCleanupRoot]) {
        guard running else { return }
        generation &+= 1
        for task in scanTasks.values { task.cancel() }
        cancelInspection()
        roots = Dictionary(uniqueKeysWithValues: newRoots.map { ($0.id, $0) })
        dirtyRoots = Set(roots.keys.filter { scanTasks[$0] != nil })
        for root in newRoots where scanTasks[root.id] == nil { scan(root) }
    }

    func stop() {
        guard running else { return }
        running = false
        generation &+= 1
        for task in scanTasks.values { task.cancel() }
        for task in scanCompletionTasks.values { task.cancel() }
        dirtyRoots.removeAll()
        cancelInspection()
    }
    func waitForBackgroundScans() async {
        while !scanCompletionTasks.isEmpty {
            let tasks = Array(scanCompletionTasks.values)
            for task in tasks { await task.value }
        }
        if let inspectionTask { await inspectionTask.value }
    }

    func preview(rootID: UUID) async throws -> MacArtifactScanResult {
        guard running, let root = roots[rootID] else { throw CancellationError() }
        let expectedGeneration = generation
        let worker = Task.detached(priority: .utility) {
            try MacArtifactScanner.scan(root: root.url)
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard running,
              !Task.isCancelled,
              generation == expectedGeneration,
              roots[rootID]?.path == root.path else {
            throw CancellationError()
        }
        return result
    }

    func receive(_ events: [MacArtifactFileEvent]) {
        guard running else { return }
        var fullScanRoots: Set<UUID> = []
        var candidatePaths: [String: InspectionRequest] = [:]
        for event in events {
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                onRootChanged?()
                continue
            }
            guard let root = MacArtifactCleanupRoot.containing(path: event.path, in: roots.values) else { continue }
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                fullScanRoots.insert(root.id)
                continue
            }
            let path = URL(fileURLWithPath: event.path).standardizedFileURL
            guard MacArtifactScanner.mayMatch(path.lastPathComponent) else { continue }
            candidatePaths["\(root.id.uuidString):\(path.path)"] = InspectionRequest(root: root, url: path)
        }
        for rootID in fullScanRoots {
            if let root = roots[rootID] { scan(root) }
        }
        for request in candidatePaths.values { queueInspection(request) }
    }

    private func scan(_ root: MacArtifactCleanupRoot) {
        guard running else { return }
        if scanTasks[root.id] != nil {
            dirtyRoots.insert(root.id)
            return
        }
        let token = UUID()
        let expectedGeneration = generation
        scanTokens[root.id] = token
        let worker = Task.detached(priority: .utility) {
            try MacArtifactScanner.scan(root: root.url)
        }
        scanTasks[root.id] = worker
        let completion = Task { @MainActor [weak self] in
            let result = await worker.result
            guard let self, self.scanTokens[root.id] == token else { return }
            self.scanTasks.removeValue(forKey: root.id)
            self.scanTokens.removeValue(forKey: root.id)
            self.scanCompletionTasks.removeValue(forKey: root.id)
            if self.running,
               !Task.isCancelled,
               self.generation == expectedGeneration,
               self.roots[root.id]?.path == root.path {
                switch result {
                case .success(let scan): self.onScanResult?(root, scan)
                case .failure(let error):
                    if !(error is CancellationError) {
                        self.onScanFailure?(root, error.localizedDescription)
                    }
                }
            }
            if self.running,
               self.dirtyRoots.remove(root.id) != nil,
               let currentRoot = self.roots[root.id] {
                self.scan(currentRoot)
            }
        }
        scanCompletionTasks[root.id] = completion
    }

    private func queueInspection(_ request: InspectionRequest) {
        let key = "\(request.root.id.uuidString):\(request.url.path)"
        inspections[key] = request
        guard inspectionTask == nil else { return }
        let token = UUID()
        let expectedGeneration = generation
        inspectionToken = token
        inspectionTask = Task { @MainActor [weak self] in
            await self?.processInspections(token: token, generation: expectedGeneration)
        }
    }

    private func processInspections(token: UUID, generation expectedGeneration: UInt64) async {
        while !Task.isCancelled, !inspections.isEmpty {
            let batch = Array(inspections.prefix(64))
            for (key, _) in batch { inspections.removeValue(forKey: key) }
            let requests = batch.map(\.value)
            let worker = Task.detached(priority: .utility) {
                requests.map { request in
                    do {
                        return InspectionOutcome(
                            request: request,
                            match: try MacArtifactScanner.match(at: request.url, within: request.root.url),
                            failure: nil
                        )
                    } catch {
                        return InspectionOutcome(request: request, match: nil, failure: error.localizedDescription)
                    }
                }
            }
            inspectionWorker = worker
            let results = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard running,
                  !Task.isCancelled,
                  generation == expectedGeneration,
                  inspectionToken == token else {
                finishInspections(token: token)
                return
            }
            inspectionWorker = nil
            for result in results {
                guard roots[result.request.root.id]?.path == result.request.root.path else { continue }
                if let match = result.match {
                    onMatch?(result.request.root, match)
                } else if let failure = result.failure {
                    onInspectionFailure?(result.request.root, result.request.url, failure)
                }
            }
        }
        finishInspections(token: token)
    }

    private func finishInspections(token: UUID) {
        guard inspectionToken == token else { return }
        inspectionToken = nil
        inspectionTask = nil
        inspectionWorker = nil
    }

    private func cancelInspection() {
        inspectionTask?.cancel()
        inspectionTask = nil
        inspectionWorker?.cancel()
        inspectionWorker = nil
        inspectionToken = nil
        inspections.removeAll()
    }

}
