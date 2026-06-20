import SwiftUI

/// Shows the PIN remotes must enter to connect to this FWPlayer instance.
/// A compact single-line bar, identical on iPhone, iPad, and Mac Catalyst.
struct RemotePairingBanner: View {
    @EnvironmentObject private var remoteServer: RemoteControlServer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.and.hand.point.up.left.fill")
                .foregroundStyle(.tint)
            Text("Remote PIN")
                .font(.caption.weight(.semibold))
            Text(remoteServer.displayPIN)
                .font(.body.monospacedDigit().weight(.bold))
            Text("Enter in FWPlayer Remote")
                .font(.caption)
                .foregroundStyle(.secondary)
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
