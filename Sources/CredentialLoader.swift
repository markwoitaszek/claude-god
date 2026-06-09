// CredentialLoader.swift
// Stateless credential resolution: one AccountSource → one CredentialBundle.
// Does NOT mutate AuthManager — safe to call from background threads for any profile.
// Based on Claude God (MIT © 2025 Lucas Charvolin).

import Foundation

// MARK: - Credential bundle

struct CredentialBundle {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Double?
    let subscriptionType: String
}

// MARK: - Loader

enum CredentialLoader {

    /// Resolve credentials for the given source. Returns nil if not found or invalid.
    /// Off-main-thread safe — does not access any @Published properties.
    static func load(from source: AccountSource) -> CredentialBundle? {
        switch source {
        case .keychainService(let name):
            return fromKeychain(service: name)
        case .credentialsFile(let path):
            let expanded = (path as NSString).expandingTildeInPath
            return fromFile(URL(fileURLWithPath: expanded))
        }
    }

    // MARK: - File

    static func fromFile(_ url: URL) -> CredentialBundle? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = oauthDict(from: json),
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return CredentialBundle(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: oauth["expiresAt"] as? Double,
            subscriptionType: oauth["subscriptionType"] as? String ?? ""
        )
    }

    // MARK: - Keychain (no-prompt CLI path)

    private static func fromKeychain(service: String) -> CredentialBundle? {
        guard let json = readKeychainViaSecurityCLI(service: service),
              let oauth = oauthDict(from: json),
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return CredentialBundle(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: oauth["expiresAt"] as? Double,
            subscriptionType: oauth["subscriptionType"] as? String ?? ""
        )
    }

    private static func readKeychainViaSecurityCLI(service: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let trimmed = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  let jsonData = trimmed.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { return nil }
            return json
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    /// Extract the oauthAccount dict, supporting both key variants Claude Code has used.
    private static func oauthDict(from json: [String: Any]) -> [String: Any]? {
        if let o = json["claudeAiOauth"] as? [String: Any] { return o }
        if let o = json["oauthAccount"]  as? [String: Any] { return o }
        return nil
    }
}
