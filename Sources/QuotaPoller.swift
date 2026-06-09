// QuotaPoller.swift
// Polls quota data for all configured accounts in the background.
// Uses CredentialLoader (off-main-thread safe) and delegates HTTP fetching to UsageManager.
// Based on Claude God (MIT © 2025 Lucas Charvolin).

import Foundation

// MARK: - Per-profile quota snapshot

struct ProfileQuota {
    let accountID: UUID
    let label: String
    let quotas: [UsageQuota]
    let fetchedAt: Date
    let error: String?

    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 180 }
    var worstUtilization: Double { quotas.map(\.utilization).max() ?? 0 }
}

// MARK: - Poller

final class QuotaPoller {
    private var isPolling = false

    /// Fan out a background fetch for each account. Calls `onResult` on the main queue
    /// for each account as results arrive (not batched — callers must handle concurrent updates).
    func pollAll(accounts: [AccountInfo],
                 onResult: @escaping (UUID, ProfileQuota) -> Void) {
        guard !isPolling, !accounts.isEmpty else { return }
        isPolling = true

        let group = DispatchGroup()

        for account in accounts {
            let accountID = account.id
            let label = account.label

            group.enter()
            DispatchQueue.global(qos: .utility).async {
                guard let bundle = CredentialLoader.load(from: account.source) else {
                    Log.warn("QuotaPoller: no credentials for \(label)")
                    let pq = ProfileQuota(accountID: accountID, label: label,
                                          quotas: [], fetchedAt: Date(),
                                          error: "No credentials found")
                    DispatchQueue.main.async { onResult(accountID, pq) }
                    group.leave()
                    return
                }

                UsageManager.fetchQuotasStateless(token: bundle.accessToken) { quotas in
                    let pq = ProfileQuota(
                        accountID: accountID,
                        label: label,
                        quotas: quotas ?? [],
                        fetchedAt: Date(),
                        error: quotas == nil ? "Fetch failed" : nil
                    )
                    DispatchQueue.main.async { onResult(accountID, pq) }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.isPolling = false
        }
    }
}
