import SwiftUI

/// A row whose content plays/opens on a single tap (a plain SwiftUI Button on
/// every platform). In edit mode it renders the content without the button so
/// reorder/delete controls work.
struct PlaybackRowInteraction<Content: View>: View {
    let isHighlighted: Bool
    let onPlay: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.editMode) private var editMode

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    var body: some View {
        Group {
            if isEditing {
                content()
            } else {
                // A native SwiftUI Button on every platform — including Catalyst,
                // which previously used a UIKit tap-recognizer overlay that the
                // List's own gestures intermittently swallowed (a single click
                // would only sometimes open/play). A Button is as reliable as the
                // Return key. The embedded favorite star and ••• menu still work
                // as higher-priority nested controls.
                Button(action: onPlay) {
                    content()
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(isHighlighted && !isEditing ? Color.accentColor.opacity(0.15) : nil)
        .contentShape(Rectangle())
    }
}
