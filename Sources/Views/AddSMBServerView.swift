import SwiftUI

/// Form for adding *or editing* an SMB server. Optionally tests the connection
/// before saving.
struct AddSMBServerView: View {
    @EnvironmentObject private var registry: SourceRegistry
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, the form edits this existing server instead of adding one.
    private let editing: SMBServerConfig?

    @State private var displayName: String
    @State private var host: String
    @State private var port: String
    @State private var share: String
    @State private var isGuest: Bool
    @State private var username: String
    @State private var password: String

    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    init(editing: SMBServerConfig? = nil) {
        self.editing = editing
        _displayName = State(initialValue: editing?.displayName ?? "")
        _host = State(initialValue: editing?.host ?? "")
        _port = State(initialValue: editing.map { String($0.port) } ?? "445")
        _share = State(initialValue: editing?.share ?? "")
        _isGuest = State(initialValue: editing?.isGuest ?? false)
        _username = State(initialValue: editing?.username ?? "")
        // The password lives in the Keychain; it's loaded in `.onAppear`.
        _password = State(initialValue: "")
    }

    private var canSave: Bool {
        !host.trimmed.isEmpty && !share.trimmed.isEmpty && hasCredentials
    }

    /// Guest needs no credentials; new servers need username + password; edits can
    /// keep the stored Keychain password when the field is left blank.
    private var hasCredentials: Bool {
        if isGuest { return true }
        if !username.trimmed.isEmpty && !password.isEmpty { return true }
        if editing != nil && password.isEmpty { return true }
        return false
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
            .navigationTitle(editing == nil ? "Add SMB Server" : "Edit SMB Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                // Pre-fill the stored password when editing an existing server.
                if let editing, password.isEmpty {
                    password = registry.smbPassword(for: editing)
                }
            }
        }
    }

    private func makeConfig() -> SMBServerConfig {
        SMBServerConfig(
            id: editing?.id ?? UUID(),   // keep the same identity when editing
            displayName: displayName.trimmed.isEmpty ? host.trimmed : displayName.trimmed,
            host: host.trimmed,
            port: Int(port.trimmed) ?? 445,
            share: share.trimmed,
            username: username.trimmed,
            isGuest: isGuest
        )
    }

    private func effectivePassword() -> String {
        if !password.isEmpty { return password }
        if let editing { return registry.smbPassword(for: editing) }
        return password
    }

    private func testConnection() async {
        isTesting = true
        statusMessage = nil
        let source = SMBFileSource(config: makeConfig(), password: effectivePassword())
        do {
            try await source.testConnection()
            statusIsError = false
            statusMessage = "Connected successfully."
        } catch {
            statusIsError = true
            statusMessage = SMBFileSource.userFacingMessage(for: error)
        }
        isTesting = false
    }

    private func save() {
        let config = makeConfig()
        let pwd = effectivePassword()
        if editing == nil {
            registry.addSMBServer(config, password: pwd)
        } else {
            registry.updateSMBServer(config, password: pwd)
        }
        dismiss()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
