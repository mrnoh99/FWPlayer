import SwiftUI

/// Form for adding an SMB server. Optionally tests the connection before saving.
struct AddSMBServerView: View {
    @EnvironmentObject private var registry: SourceRegistry
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var host = ""
    @State private var port = "445"
    @State private var share = ""
    @State private var isGuest = false
    @State private var username = ""
    @State private var password = ""

    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private var canSave: Bool {
        !host.trimmed.isEmpty && !share.trimmed.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (e.g. Living Room NAS)", text: $displayName)
                    TextField("Host or IP (e.g. 192.168.1.10)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Share name (e.g. Music)", text: $share)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Authentication") {
                    Toggle("Connect as Guest", isOn: $isGuest)
                    if !isGuest {
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                    }
                }

                if let statusMessage {
                    Section {
                        Label(statusMessage, systemImage: statusIsError ? "xmark.octagon" : "checkmark.circle")
                            .foregroundStyle(statusIsError ? .red : .green)
                    }
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            if isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!canSave || isTesting)
                }
            }
            .navigationTitle("Add SMB Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func makeConfig() -> SMBServerConfig {
        SMBServerConfig(
            displayName: displayName.trimmed.isEmpty ? host.trimmed : displayName.trimmed,
            host: host.trimmed,
            port: Int(port.trimmed) ?? 445,
            share: share.trimmed,
            username: username.trimmed,
            isGuest: isGuest
        )
    }

    private func testConnection() async {
        isTesting = true
        statusMessage = nil
        let source = SMBFileSource(config: makeConfig(), password: password)
        do {
            try await source.testConnection()
            statusIsError = false
            statusMessage = "Connected successfully."
        } catch {
            statusIsError = true
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isTesting = false
    }

    private func save() {
        registry.addSMBServer(makeConfig(), password: password)
        dismiss()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
