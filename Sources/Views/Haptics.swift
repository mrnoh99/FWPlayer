import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Lightweight tactile feedback for control touches. A no-op on devices without
/// a Taptic Engine (most iPads, Mac Catalyst), real feedback on iPhone.
enum Haptics {
    /// A light tap — for transport and other momentary button presses.
    static func tap() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }

    /// A selection tick — for picking a row or switching context.
    static func selection() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}
