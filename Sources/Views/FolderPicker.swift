import SwiftUI
import UniformTypeIdentifiers

/// Bridges `UIDocumentPickerViewController` (folder mode) into SwiftUI. Lets the
/// user pick any folder visible in the Files app — including SMB or other
/// network shares they have connected there — and returns its URL.
struct FolderPicker: UIViewControllerRepresentable {
    var onPick: @MainActor (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: @MainActor (URL) -> Void
        init(onPick: @escaping @MainActor (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            // Document-picker delegate callbacks are delivered on the main thread.
            MainActor.assumeIsolated { onPick(url) }
        }
    }
}
