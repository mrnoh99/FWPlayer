#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Detects single and double clicks on Mac Catalyst for list rows.
///
/// Uses a *single* tap recognizer and measures the gap between clicks in the
/// coordinator, rather than a built-in 2-tap `UITapGestureRecognizer`. Two
/// reasons:
///  * UIKit's 2-tap recognizer uses a fixed ~300 ms threshold and ignores the
///    macOS "double-click speed" setting, so a normal (slightly slower) mouse
///    double-click would intermittently fail — the row simply wouldn't open.
///  * A single recognizer competes far less with the gesture recognizers that
///    the UIKit-backed SwiftUI `List` installs for selection and scrolling.
///
/// A generous manual interval plus simultaneous recognition makes opening a
/// folder reliable on every double-click.
struct DoubleClickDetector: UIViewRepresentable {
    var onSingleClick: () -> Void
    var onDoubleClick: () -> Void
    /// Widths (in points) at the leading/trailing edges where touches should
    /// pass *through* to the controls beneath instead of being captured for
    /// click detection. Track rows put a favorite star at the leading edge and
    /// a ••• menu at the trailing edge; without these gaps the full-row detector
    /// would swallow their taps and they'd be unclickable on Catalyst.
    var leadingPassthrough: CGFloat = 0
    var trailingPassthrough: CGFloat = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleClick: onSingleClick, onDoubleClick: onDoubleClick)
    }

    func makeUIView(context: Context) -> UIView {
        let view = PassThroughView()
        view.leadingPassthrough = leadingPassthrough
        view.trailingPassthrough = trailingPassthrough

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.tapped)
        )
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSingleClick = onSingleClick
        context.coordinator.onDoubleClick = onDoubleClick
        if let view = uiView as? PassThroughView {
            view.leadingPassthrough = leadingPassthrough
            view.trailingPassthrough = trailingPassthrough
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSingleClick: () -> Void
        var onDoubleClick: () -> Void

        private var lastClick: Date?
        /// Two clicks within this window count as a double-click. Deliberately
        /// more generous than UIKit's ~300 ms 2-tap threshold so an ordinary
        /// Mac double-click reliably opens the row.
        private let doubleClickInterval: TimeInterval = 0.5

        init(onSingleClick: @escaping () -> Void, onDoubleClick: @escaping () -> Void) {
            self.onSingleClick = onSingleClick
            self.onDoubleClick = onDoubleClick
        }

        @objc func tapped() {
            let now = Date()
            if let last = lastClick, now.timeIntervalSince(last) <= doubleClickInterval {
                lastClick = nil
                onDoubleClick()
            } else {
                lastClick = now
                onSingleClick()
            }
        }

        // The row lives inside a UIKit-backed SwiftUI List, which installs its
        // own selection/scroll gesture recognizers. Allowing simultaneous
        // recognition keeps the List from swallowing our taps (which would make
        // a folder fail to open, especially right after navigating back).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class PassThroughView: UIView {
        var leadingPassthrough: CGFloat = 0
        var trailingPassthrough: CGFloat = 0

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard bounds.contains(point) else { return nil }
            // Leave the leading (favorite star) and trailing (••• menu) gutters
            // for the controls beneath so they stay tappable.
            if point.x < leadingPassthrough { return nil }
            if point.x > bounds.width - trailingPassthrough { return nil }
            return self
        }
    }
}
#endif
