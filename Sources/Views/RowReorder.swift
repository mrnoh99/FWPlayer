import SwiftUI
import UniformTypeIdentifiers

/// Long-press-and-drag reordering for list rows, without switching the list into Edit mode.
///
/// Touch and hold a row (click and drag with a pointer) to lift it, then drag it over other
/// rows; the list reorders live and the row settles where you let go. Edit mode and its
/// handles still work as before — while a list is in Edit mode this stays out of the way.
///
/// `index` is the row's position in the underlying array, and `move(from, toOffset)` moves one
/// element with the same meaning as `Array.move(fromOffsets:toOffset:)`.
private struct RowReorder: ViewModifier {
    let index: Int
    let isEnabled: Bool
    @Binding var dragging: Int?
    let move: (_ from: Int, _ toOffset: Int) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrag {
                    dragging = index
                    // A marker only: the row is identified by `dragging`, not by what's dragged.
                    return NSItemProvider(object: "fwplayer-row-reorder" as NSString)
                }
                .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(index: index, dragging: $dragging, move: move))
        } else {
            content
        }
    }
}

private struct ReorderDropDelegate: DropDelegate {
    let index: Int
    @Binding var dragging: Int?
    let move: (_ from: Int, _ toOffset: Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != index else { return }
        // Dragging down puts the row after the one it's over; dragging up, before it.
        move(from, from < index ? index + 1 : index)
        dragging = index                    // the row now sits where the pointer is
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

extension View {
    /// Makes a list row draggable to reorder (see `RowReorder`).
    func reorderable(index: Int, isEnabled: Bool = true, dragging: Binding<Int?>,
                     move: @escaping (_ from: Int, _ toOffset: Int) -> Void) -> some View {
        modifier(RowReorder(index: index, isEnabled: isEnabled, dragging: dragging, move: move))
    }
}
