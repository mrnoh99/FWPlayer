import SwiftUI

/// On iOS/iPadOS a single tap plays. On Mac Catalyst a single click selects
/// via `List(selection:)` and a double click plays or opens.
struct PlaybackRowInteraction<Content: View>: View {
    let isHighlighted: Bool
    let onSelect: () -> Void
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
                #if targetEnvironment(macCatalyst)
                content()
                #else
                Button(action: onPlay) {
                    content()
                }
                .buttonStyle(.plain)
                #endif
            }
        }
        .listRowBackground(isHighlighted && !isEditing ? Color.accentColor.opacity(0.15) : nil)
        .contentShape(Rectangle())
    }
}
