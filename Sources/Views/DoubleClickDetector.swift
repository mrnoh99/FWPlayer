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
        singleTap.delaysTouchesBegan = false
        singleTap.delegate = context.coordinator
        view.addGestureRecognizer(singleTap)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.doubleTapped)
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delaysTouchesBegan = false
        doubleTap.delegate = context.coordinator
        view.addGestureRecognizer(doubleTap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSingleClick = onSingleClick
        context.coordinator.onDoubleClick = onDoubleClick
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
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

        // The row lives inside a UIKit-backed SwiftUI List, which installs its
        // own selection/scroll gesture recognizers. Without this the List often
        // wins the gesture and our double-tap is silently dropped — so a folder
        // would intermittently fail to open, especially right after navigating
        // back (when the List rebuilds its recognizers). Allowing simultaneous
        // recognition lets our taps fire reliably alongside the List's.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
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
