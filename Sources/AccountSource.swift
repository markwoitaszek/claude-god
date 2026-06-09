// AccountSource.swift
// Describes where a profile's OAuth credentials live.
// Based on Claude God (MIT © 2025 Lucas Charvolin).

import Foundation

/// Where a profile's OAuth credentials are stored.
/// Keychain is the primary case (how Claude Code stores creds on modern installs).
/// File is the fallback for profiles whose Keychain entry cannot be correlated.
enum AccountSource: Codable, Equatable, Hashable {
    /// A macOS Keychain generic-password service name.
    /// Discovered at first launch via token-correlation against the profile directory.
    /// Example: "Claude Code-credentials-personal"
    case keychainService(String)

    /// An absolute path to a credentials file.
    /// Example: "~/.claude-work/.credentials.json"
    case credentialsFile(String)

    private enum Kind: String, Codable { case keychain, file }
    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .keychain: self = .keychainService(try c.decode(String.self, forKey: .value))
        case .file:     self = .credentialsFile(try c.decode(String.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keychainService(let s):
            try c.encode(Kind.keychain, forKey: .kind)
            try c.encode(s, forKey: .value)
        case .credentialsFile(let p):
            try c.encode(Kind.file, forKey: .kind)
            try c.encode(p, forKey: .value)
        }
    }
}
