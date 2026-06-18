import SwiftUI

/// Keeps list focus on a user click, then returns it to the playing row after idle time.
@MainActor
enum ListFocusBehavior {
    static let revertDelay: Duration = .seconds(3)

    static func scheduleRevert(
        task: inout Task<Void, Never>?,
        to playingID: String?,
        isPlaybackActive: Bool,
        currentFocusID: String?,
        apply: @escaping (String) -> Void
    ) {
        task?.cancel()
        guard isPlaybackActive, let playingID, playingID != currentFocusID else { return }
        task = Task {
            try? await Task.sleep(for: revertDelay)
            guard !Task.isCancelled else { return }
            apply(playingID)
        }
    }

    static func cancelRevert(task: inout Task<Void, Never>?) {
        task?.cancel()
        task = nil
    }
}
