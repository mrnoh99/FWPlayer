import SwiftUI

/// Shows the PIN remotes must enter to connect to this FWPlayer instance.
struct RemotePairingBanner: View {
    @EnvironmentObject private var remoteServer: RemoteControlServer

    var body: some View {
        #if targetEnvironment(macCatalyst)
        macLayout
        #else
        defaultLayout
        #endif
    }

    private var defaultLayout: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.and.hand.point.up.left.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote PIN")
                    .font(.caption.weight(.semibold))
                Text(remoteServer.displayPIN)
                    .font(.title3.monospacedDigit().weight(.bold))
            }
            Spacer()
            Text("Enter this PIN in FWPlayer Remote")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var macLayout: some View {
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
