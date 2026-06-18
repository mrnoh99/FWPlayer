#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Detects single and double clicks on Mac Catalyst for list rows.
struct DoubleClickDetector: UIViewRepresentable {
    var onSingleClick: () -> Void
    var onDoubleClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleClick: onSingleClick, onDoubleClick: onDoubleClick)
    }

    func makeUIView(context: Context) -> UIView {
        let view = PassThroughView()

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.singleTapped)
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(singleTap)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.doubleTapped)
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(doubleTap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSingleClick = onSingleClick
        context.coordinator.onDoubleClick = onDoubleClick
    }

    final class Coordinator: NSObject {
        var onSingleClick: () -> Void
        var onDoubleClick: () -> Void

        init(onSingleClick: @escaping () -> Void, onDoubleClick: @escaping () -> Void) {
            self.onSingleClick = onSingleClick
            self.onDoubleClick = onDoubleClick
        }

        @objc func singleTapped() {
            onSingleClick()
        }

        @objc func doubleTapped() {
            onDoubleClick()
        }
    }

    final class PassThroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard bounds.contains(point) else { return nil }
            return self
        }
    }
}
#endif
