import Foundation
import Observation

/// Keep the latest user choice selected while hardware finishes a transition.
/// Serialize commands and ignore inventory reads started before a newer choice.
@Observable @MainActor final class FoldController {
    private(set) var confirmed: FoldState?
    private(set) var requested: FoldState?
    private(set) var isBusy = false
    private(set) var revision = 0
    var failure: String?
    var selected: FoldState? { requested ?? confirmed }
    private var pending: FoldState?
    private var worker: Task<Void, Never>?

    init(initial: FoldState? = nil) { confirmed = initial }

    func synchronize(_ state: FoldState?, revision: Int) {
        guard !isBusy, revision == self.revision else { return }
        confirmed = state
    }

    func select(_ state: FoldState, apply: @escaping @MainActor (FoldState) async throws -> Void) {
        guard selected != state else { return }
        requested = state; pending = state; revision += 1; failure = nil
        guard worker == nil else { return }
        isBusy = true
        worker = Task { @MainActor in
            defer { worker = nil; isBusy = false; requested = nil }
            while let target = pending {
                pending = nil
                do {
                    if confirmed != target { try await apply(target) }
                    confirmed = target
                } catch {
                    if pending == nil, !(error is CancellationError) { failure = String(describing: error) }
                }
            }
        }
    }

    func waitUntilIdle() async { while let worker { await worker.value } }
}

enum FoldState: String, CaseIterable {
    case opened, closed
    var title: String { self == .opened ? "Opened" : "Closed" }
}
