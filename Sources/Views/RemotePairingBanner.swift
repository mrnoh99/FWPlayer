import SwiftUI

/// A compact single-line bar noting that FWPlayer Remote connects automatically
/// (no PIN). Identical on iPhone, iPad, and Mac Catalyst.
struct RemotePairingBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.and.hand.point.up.left.fill")
                .foregroundStyle(.tint)
            Text("FWPlayer Remote connects automatically")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            Text("Developed by JaiSung NOH MD 2026")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
