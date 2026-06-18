import Foundation

/// Persists the list of configured SMB servers. Passwords are kept in the
/// Keychain (see `Keychain`), never in UserDefaults.
struct SMBServerStore {
    private let defaultsKey = "fwplayer.smbServers"
    private var defaults: UserDefaults { .standard }

    func load() -> [SMBServerConfig] {
        guard let data = defaults.data(forKey: defaultsKey),
              let configs = try? JSONDecoder().decode([SMBServerConfig].self, from: data) else {
            return []
        }
        return configs
    }

    private func save(_ configs: [SMBServerConfig]) {
        if let data = try? JSONEncoder().encode(configs) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// Adds a new server or, if one with the same `id` already exists, replaces
    /// it (used for editing). The password moves to/from the Keychain to match
    /// the guest setting.
    func add(_ config: SMBServerConfig, password: String) {
        var configs = load().filter { $0.id != config.id }
        configs.append(config)
        save(configs)
        if config.isGuest {
            Keychain.delete(account: config.id.uuidString)
        } else {
            Keychain.setPassword(password, for: config.id.uuidString)
        }
    }

    func remove(id: UUID) {
        save(load().filter { $0.id != id })
        Keychain.delete(account: id.uuidString)
    }

    func password(for config: SMBServerConfig) -> String {
        Keychain.password(for: config.id.uuidString) ?? ""
    }
}
