import Foundation

@main
struct GestureCheck {
    @MainActor
    static func main() async throws {
        var actions: [CaptureGesture.Action] = []
        let gesture = CaptureGesture(interval: 0.05) { actions.append($0) }
        func settle() async throws { try await Task.sleep(nanoseconds: 150_000_000) }

        gesture.tap()
        assert(actions.isEmpty, "Single tap must wait for additional taps")
        try await settle()
        assert(actions == [.area])

        gesture.tap()
        gesture.tap()
        assert(actions == [.area], "Double tap must not emit a provisional area capture")
        try await settle()
        assert(actions == [.area, .page])

        gesture.tap()
        gesture.tap()
        gesture.tap()
        assert(actions == [.area, .page, .gif], "Triple tap must resolve immediately")
        try await settle()
        assert(actions == [.area, .page, .gif], "Cancelled timers must not emit extra captures")

        gesture.tap()
        gesture.cancel()
        try await settle()
        assert(actions == [.area, .page, .gif], "Cancellation must discard pending capture")

        gesture.tap()
        try await settle()
        assert(actions == [.area, .page, .gif, .area], "A fresh sequence must start at one tap")
        print("Gesture sequence checks passed")
    }
}
