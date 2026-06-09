// ProfileRegistry.swift
// Discovers Claude Code profiles from ~/.claude/profiles.json and correlates
// each profile directory to its Keychain service entry via token comparison.
// Watches the registry file for changes and republishes the profile list.
// Based on Claude God (MIT © 2025 Lucas Charvolin).

import Foundation
import Combine
import Security

// MARK: - Discovered profile

struct DiscoveredProfile: Identifiable, Equatable {
    let id: String          // registry key, e.g. "personal"
    let displayName: String // capitalized for display, e.g. "Personal"
    let dir: String         // expanded absolute path, e.g. "/Users/x/.claude-personal"
    let source: AccountSource
}

// MARK: - Registry manager

final class ProfileRegistryManager: ObservableObject {
    @Published private(set) var profiles: [DiscoveredProfile] = []

    static let registryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/profiles.json")

    private var watcher: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    // Cache maps profileDir → AccountSource so the Keychain scan only runs once per dir.
    private static let cacheKey = "profileSourceCache_v1"

    // MARK: - Lifecycle

    func start() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.reloadInternal()
            DispatchQueue.main.async { [weak self] in self?.startWatching() }
        }
    }

    func reload() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.reloadInternal()
        }
    }

    private func reloadInternal() {
        let raw = loadProfiles()
        guard !raw.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.profiles = [] }
            return
        }
        let resolved = resolveSourcesWithCache(raw)
        DispatchQueue.main.async { [weak self] in self?.profiles = resolved }
    }

    // MARK: - Profile discovery

    private func loadProfiles() -> [(id: String, dir: String)] {
        guard let data = try? Data(contentsOf: Self.registryURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return obj.compactMap { key, value in
            guard let entry = value as? [String: Any],
                  let rawDir = entry["dir"] as? String else { return nil }
            return (id: key, dir: (rawDir as NSString).expandingTildeInPath)
        }.sorted { $0.id < $1.id }
    }

    private func resolveSourcesWithCache(_ raw: [(id: String, dir: String)]) -> [DiscoveredProfile] {
        var cache = loadCache()

        // Enumerate Keychain once for the entire batch (one scan, not N scans)
        let keychainTokens = enumerateKeychainServices()

        var changed = false
        let result = raw.map { profile -> DiscoveredProfile in
            // Use cached source if Keychain still has that service
            if let cached = cache[profile.dir],
               case .keychainService(let svc) = cached,
               keychainTokens[svc] != nil {
                return DiscoveredProfile(id: profile.id,
                                         displayName: formatName(profile.id),
                                         dir: profile.dir, source: cached)
            }
            // Token-correlation: find the Keychain entry whose token matches this profile's creds
            let source = resolveSource(profileDir: profile.dir, keychainTokens: keychainTokens)
            if cache[profile.dir] != source { cache[profile.dir] = source; changed = true }
            return DiscoveredProfile(id: profile.id,
                                     displayName: formatName(profile.id),
                                     dir: profile.dir, source: source)
        }
        if changed { saveCache(cache) }
        return result
    }

    private func resolveSource(profileDir: String, keychainTokens: [String: String]) -> AccountSource {
        // Try .claude.json first (official credential file when CLAUDE_CONFIG_DIR is set)
        for credFile in ["\(profileDir)/.claude.json", "\(profileDir)/.credentials.json"] {
            if let token = accessToken(fromFile: credFile),
               let (service, _) = keychainTokens.first(where: { $0.value == token }) {
                return .keychainService(service)
            }
        }
        // Fallback: use the credentials file directly
        let claudeJSON = "\(profileDir)/.claude.json"
        return .credentialsFile(
            FileManager.default.fileExists(atPath: claudeJSON)
                ? claudeJSON
                : "\(profileDir)/.credentials.json"
        )
    }

    private func accessToken(fromFile path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let o = json["claudeAiOauth"] as? [String: Any],
           let t = o["accessToken"] as? String, !t.isEmpty { return t }
        if let o = json["oauthAccount"] as? [String: Any],
           let t = o["accessToken"] as? String, !t.isEmpty { return t }
        return nil
    }

    // MARK: - Keychain enumeration

    /// Returns [serviceName: accessToken] for all "Claude Code-credentials*" Keychain entries.
    /// Reuses the same SecItemCopyMatching pattern as AuthManager.loadBestKeychainEntryWithPrefix.
    private func enumerateKeychainServices() -> [String: String] {
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var listRaw: CFTypeRef?
        guard SecItemCopyMatching(listQuery as CFDictionary, &listRaw) == errSecSuccess,
              let items = listRaw as? [[String: Any]] else { return [:] }

        var result: [String: String] = [:]
        for item in items {
            guard let service = item[kSecAttrService as String] as? String,
                  service.hasPrefix("Claude Code-credentials") else { continue }
            let account = item[kSecAttrAccount as String] as? String ?? ""
            var fetchQ: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if !account.isEmpty { fetchQ[kSecAttrAccount as String] = account }
            var dataRaw: CFTypeRef?
            guard SecItemCopyMatching(fetchQ as CFDictionary, &dataRaw) == errSecSuccess,
                  let data = dataRaw as? Data,
                  let trimmed = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  let jsonData = trimmed.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty
            else { continue }
            result[service] = token
        }
        return result
    }

    // MARK: - Source cache

    private func loadCache() -> [String: AccountSource] {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let decoded = try? JSONDecoder().decode([String: AccountSource].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveCache(_ cache: [String: AccountSource]) {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    // MARK: - File watcher (mirrors AuthManager.startWatchingCredentials)

    private func startWatching() {
        stopWatching()
        let path = Self.registryURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }   // File absent — no watch needed; reload() on next start()

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )
        src.setEventHandler { [weak self] in
            // Debounce: editors write-then-rename; settle for 400ms before reload
            self?.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                // Re-arm watcher after atomic rename (which invalidates the old fd)
                self?.stopWatching()
                self?.reload()
                self?.startWatching()
            }
            self?.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { stopWatching() }

    // MARK: - Helpers

    private func formatName(_ key: String) -> String {
        key.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}
