import SwiftUI
import AVKit

/// A button that opens the system audio-output (AirPlay) route picker, so the
/// user can choose where sound plays — speakers, AirPods, an AirPlay device, etc.
/// Wraps `AVRoutePickerView`, which shows the standard AirPlay glyph and turns
/// the tint to the accent colour while a remote route is active.
struct AudioRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = UIColor.secondaryLabel
        view.activeTintColor = UIColor.tintColor
        view.backgroundColor = .clear
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
