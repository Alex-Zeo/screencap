import Foundation

/// Resolve the sequence before opening a selector, so a double tap never starts area capture.
@MainActor
final class CaptureGesture {
    enum Action: Int { case area = 1, page = 2, gif = 3 }

    private let interval: TimeInterval
    private let perform: (Action) -> Void
    private var taps = 0
    private var pending: Task<Void, Never>?

    init(interval: TimeInterval = 0.3, perform: @escaping (Action) -> Void) {
        self.interval = interval
        self.perform = perform
    }

    func tap() {
        pending?.cancel()
        taps += 1
        if taps == 3 {
            finish()
            return
        }
        pending = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
            catch { return }
            finish()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        taps = 0
    }

    private func finish() {
        let action = Action(rawValue: taps)
        cancel()
        if let action { perform(action) }
    }
}
