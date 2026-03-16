// MemoryManager.swift
// Reads claude-mem SQLite database and exposes memory data

import Foundation
import SQLite3

// MARK: - Models

struct ClaudeMemory: Identifiable {
    let id: Int64
    let sessionId: String
    let text: String
    let type: String
    let title: String?
    let subtitle: String?
    let narrative: String?
    let facts: [String]
    let concepts: [String]
    let filesRead: [String]
    let filesModified: [String]
    let project: String?
    let createdAt: Date

    var displayTitle: String {
        title ?? narrative ?? text.prefix(80).description
    }

    var allFiles: [String] {
        Array(Set(filesRead + filesModified)).sorted()
    }

    func toMarkdown() -> String {
        var lines: [String] = []
        lines.append("## \(displayTitle)")
        lines.append("")
        lines.append("- **Type**: \(type)")
        lines.append("- **Date**: \(createdAt.formatted(date: .long, time: .shortened))")
        if let project { lines.append("- **Project**: \(project)") }
        if let subtitle { lines.append("- **Subtitle**: \(subtitle)") }
        lines.append("")
        if let narrative {
            lines.append(narrative)
            lines.append("")
        }
        if !text.isEmpty && text != (narrative ?? "") {
            lines.append(text)
            lines.append("")
        }
        if !facts.isEmpty {
            lines.append("### Facts")
            facts.forEach { lines.append("- \($0)") }
            lines.append("")
        }
        if !concepts.isEmpty {
            lines.append("### Concepts")
            concepts.forEach { lines.append("- \($0)") }
            lines.append("")
        }
        if !allFiles.isEmpty {
            lines.append("### Files")
            allFiles.forEach { lines.append("- `\($0)`") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

struct MemoryStats {
    let totalMemories: Int
    let totalSessions: Int
    let totalProjects: Int
    let recentCount: Int  // last 7 days
    let topProjects: [(name: String, count: Int)]

    static let empty = MemoryStats(totalMemories: 0, totalSessions: 0, totalProjects: 0, recentCount: 0, topProjects: [])
}

struct DailyActivity: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

struct ProjectSummary: Identifiable {
    let project: String
    let totalObservations: Int
    let allFacts: [String]
    let allConcepts: [String]
    let allFiles: [String]
    let lastActive: Date
    var id: String { project }

    var displayName: String {
        (project as NSString).lastPathComponent
    }
}

// MARK: - Manager

class MemoryManager: ObservableObject {

    @Published var memories: [ClaudeMemory] = []
    @Published var stats: MemoryStats = .empty
    @Published var isInstalled = false
    @Published var isLoading = false
    @Published var searchText = ""
    @Published var selectedProject: String?
    @Published var projects: [String] = []
    @Published var dailyActivity: [DailyActivity] = []
    @Published var projectSummaries: [ProjectSummary] = []

    static let dbPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-mem/claude-mem.db")
    }()

    // MARK: - Installation check

    func checkInstallation() {
        isInstalled = FileManager.default.fileExists(atPath: Self.dbPath.path)
    }

    // MARK: - Load data

    func refresh() {
        isLoading = true
        checkInstallation()
        guard isInstalled else {
            memories = []
            stats = .empty
            projects = []
            isLoading = false
            return
        }

        let search = searchText
        let project = selectedProject

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Self.loadFromDB(search: search, project: project)
            DispatchQueue.main.async {
                self.memories = result.memories
                self.stats = result.stats
                self.projects = result.projects
                self.dailyActivity = result.dailyActivity
                self.projectSummaries = result.projectSummaries
                self.isLoading = false
            }
        }
    }

    // MARK: - SQLite reading

    private struct LoadResult {
        let memories: [ClaudeMemory]
        let stats: MemoryStats
        let projects: [String]
        let dailyActivity: [DailyActivity]
        let projectSummaries: [ProjectSummary]
    }

    private static func loadFromDB(search: String, project: String?) -> LoadResult {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            Log.error("Failed to open claude-mem database")
            return LoadResult(memories: [], stats: .empty, projects: [], dailyActivity: [], projectSummaries: [])
        }
        defer { sqlite3_close(db) }

        let allMemories = queryMemories(db: db, search: search, project: project)
        let stats = computeStats(db: db)
        let projects = queryProjects(db: db)
        let daily = queryDailyActivity(db: db)
        let summaries = queryProjectSummaries(db: db)

        return LoadResult(memories: allMemories, stats: stats, projects: projects, dailyActivity: daily, projectSummaries: summaries)
    }

    private static func queryMemories(db: OpaquePointer, search: String, project: String?) -> [ClaudeMemory] {
        var sql = """
            SELECT id, memory_session_id, text, type, title, subtitle, narrative, facts, concepts, files_read, files_modified, project, created_at_epoch
            FROM observations
            WHERE 1=1
            """
        var params: [String] = []

        if !search.isEmpty {
            sql += " AND (text LIKE ? OR title LIKE ? OR narrative LIKE ?)"
            let like = "%\(search)%"
            params.append(contentsOf: [like, like, like])
        }
        if let project {
            sql += " AND project = ?"
            params.append(project)
        }

        sql += " ORDER BY created_at_epoch DESC LIMIT 100"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.error("Failed to prepare observations query: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (param as NSString).utf8String, -1, nil)
        }

        var results: [ClaudeMemory] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let sessionId = columnText(stmt, 1)
            let text = columnText(stmt, 2)
            let type = columnText(stmt, 3)
            let title = columnTextOptional(stmt, 4)
            let subtitle = columnTextOptional(stmt, 5)
            let narrative = columnTextOptional(stmt, 6)
            let facts = parseJSONArray(columnTextOptional(stmt, 7))
            let concepts = parseJSONArray(columnTextOptional(stmt, 8))
            let filesRead = parseJSONArray(columnTextOptional(stmt, 9))
            let filesModified = parseJSONArray(columnTextOptional(stmt, 10))
            let project = columnTextOptional(stmt, 11)
            let epoch = sqlite3_column_double(stmt, 12)

            results.append(ClaudeMemory(
                id: id,
                sessionId: sessionId,
                text: text,
                type: type,
                title: title,
                subtitle: subtitle,
                narrative: narrative,
                facts: facts,
                concepts: concepts,
                filesRead: filesRead,
                filesModified: filesModified,
                project: project,
                createdAt: Date(timeIntervalSince1970: epoch)
            ))
        }

        return results
    }

    private static func computeStats(db: OpaquePointer) -> MemoryStats {
        let totalMemories = queryCount(db: db, sql: "SELECT COUNT(*) FROM observations")
        let totalSessions = queryCount(db: db, sql: "SELECT COUNT(DISTINCT memory_session_id) FROM observations")
        let totalProjects = queryCount(db: db, sql: "SELECT COUNT(DISTINCT project) FROM observations WHERE project IS NOT NULL AND project != ''")

        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970
        let recentCount = queryCount(db: db, sql: "SELECT COUNT(*) FROM observations WHERE created_at_epoch > \(sevenDaysAgo)")

        // Top projects
        var topProjects: [(name: String, count: Int)] = []
        var stmt: OpaquePointer?
        let topSQL = "SELECT project, COUNT(*) as cnt FROM observations WHERE project IS NOT NULL AND project != '' GROUP BY project ORDER BY cnt DESC LIMIT 5"
        if sqlite3_prepare_v2(db, topSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = columnText(stmt, 0)
                let count = Int(sqlite3_column_int(stmt, 1))
                topProjects.append((name: name, count: count))
            }
            sqlite3_finalize(stmt)
        }

        return MemoryStats(
            totalMemories: totalMemories,
            totalSessions: totalSessions,
            totalProjects: totalProjects,
            recentCount: recentCount,
            topProjects: topProjects
        )
    }

    private static func queryProjects(db: OpaquePointer) -> [String] {
        var projects: [String] = []
        var stmt: OpaquePointer?
        let sql = "SELECT DISTINCT project FROM observations WHERE project IS NOT NULL AND project != '' ORDER BY project"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                projects.append(columnText(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }
        return projects
    }

    // MARK: - Daily activity (last 30 days)

    private static func queryDailyActivity(db: OpaquePointer) -> [DailyActivity] {
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 3600).timeIntervalSince1970
        let sql = """
            SELECT date(created_at_epoch, 'unixepoch', 'localtime') as day, COUNT(*) as cnt
            FROM observations
            WHERE created_at_epoch > \(thirtyDaysAgo)
            GROUP BY day ORDER BY day ASC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var results: [DailyActivity] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let dayStr = columnText(stmt, 0)
            let count = Int(sqlite3_column_int(stmt, 1))
            if let date = formatter.date(from: dayStr) {
                results.append(DailyActivity(date: date, count: count))
            }
        }
        return results
    }

    // MARK: - Project summaries

    private static func queryProjectSummaries(db: OpaquePointer) -> [ProjectSummary] {
        let sql = """
            SELECT project, COUNT(*) as cnt, MAX(created_at_epoch) as last_epoch,
                   GROUP_CONCAT(facts, '|||'), GROUP_CONCAT(concepts, '|||'),
                   GROUP_CONCAT(files_read, '|||'), GROUP_CONCAT(files_modified, '|||')
            FROM observations
            WHERE project IS NOT NULL AND project != ''
            GROUP BY project ORDER BY cnt DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [ProjectSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let project = columnText(stmt, 0)
            let count = Int(sqlite3_column_int(stmt, 1))
            let lastEpoch = sqlite3_column_double(stmt, 2)
            let factsConcat = columnTextOptional(stmt, 3) ?? ""
            let conceptsConcat = columnTextOptional(stmt, 4) ?? ""
            let filesReadConcat = columnTextOptional(stmt, 5) ?? ""
            let filesModConcat = columnTextOptional(stmt, 6) ?? ""

            let allFacts = extractUniqueFromConcatenatedJSON(factsConcat)
            let allConcepts = extractUniqueFromConcatenatedJSON(conceptsConcat)
            let allFiles = Array(Set(
                extractUniqueFromConcatenatedJSON(filesReadConcat) +
                extractUniqueFromConcatenatedJSON(filesModConcat)
            )).sorted()

            results.append(ProjectSummary(
                project: project,
                totalObservations: count,
                allFacts: allFacts,
                allConcepts: allConcepts,
                allFiles: allFiles,
                lastActive: Date(timeIntervalSince1970: lastEpoch)
            ))
        }
        return results
    }

    private static func extractUniqueFromConcatenatedJSON(_ concat: String) -> [String] {
        let parts = concat.components(separatedBy: "|||")
        var seen = Set<String>()
        var result: [String] = []
        for part in parts {
            for item in parseJSONArray(part) where !seen.contains(item) {
                seen.insert(item)
                result.append(item)
            }
        }
        return result
    }

    // MARK: - Delete observation

    func deleteMemory(id: Int64) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(Self.dbPath.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
                  let db else { return }
            defer { sqlite3_close(db) }

            var stmt: OpaquePointer?
            let sql = "DELETE FROM observations WHERE id = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)

            DispatchQueue.main.async {
                self.memories.removeAll { $0.id == id }
                self.refresh()
            }
        }
    }

    // MARK: - Export

    func exportAllAsMarkdown() -> String {
        let grouped = Dictionary(grouping: memories, by: { $0.project ?? "No project" })
        var lines: [String] = ["# Claude Memory Export", ""]
        lines.append("Exported \(memories.count) observations on \(Date().formatted(date: .long, time: .shortened))")
        lines.append("")

        for (project, memories) in grouped.sorted(by: { $0.key < $1.key }) {
            lines.append("---")
            lines.append("# Project: \((project as NSString).lastPathComponent)")
            lines.append("")
            for memory in memories {
                lines.append(memory.toMarkdown())
            }
        }
        return lines.joined(separator: "\n")
    }

    func exportProjectAsMarkdown(project: String) -> String {
        let filtered = memories.filter { $0.project == project }
        var lines: [String] = ["# Claude Memory — \((project as NSString).lastPathComponent)", ""]
        lines.append("\(filtered.count) observations")
        lines.append("")
        for memory in filtered {
            lines.append(memory.toMarkdown())
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private static func columnTextOptional(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else { return nil }
        let str = String(cString: cStr)
        return str.isEmpty ? nil : str
    }

    private static func parseJSONArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return array
    }

    private static func queryCount(db: OpaquePointer, sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }
}
