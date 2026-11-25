import Foundation

/// A file another run edited after this run did, waiting for this run's next turn.
public struct ConcurrentWorkNotice: Sendable, Equatable {
    public let path: String
    /// Label of the run that edited it, already rendered ("thread 'X' (Bot Y)").
    public let editor: String
    public let at: Date

    public init(path: String, editor: String, at: Date) {
        self.path = path
        self.editor = editor
        self.at = at
    }
}

/// An earlier run whose request reads like the new one.
public struct SimilarWork: Sendable, Equatable {
    public let threadID: AgentThreadID
    public let threadTitle: String
    public let isRunning: Bool
    public let finishedAt: Date?
    public let files: [String]
    /// Start of the last assistant message of a finished run, whitespace collapsed.
    public let resultSummary: String?
    public let score: Double

    public init(
        threadID: AgentThreadID, threadTitle: String, isRunning: Bool, finishedAt: Date?,
        files: [String], resultSummary: String?, score: Double
    ) {
        self.threadID = threadID; self.threadTitle = threadTitle; self.isRunning = isRunning
        self.finishedAt = finishedAt; self.files = files; self.resultSummary = resultSummary; self.score = score
    }
}

/// Text the host appends to every provider turn so an agent knows who else works in its repository.
public enum ConcurrentWorkDirective {
    public static let maxRuns = 5
    public static let maxFilesPerRun = 10
    public static let maxNotices = 5
    public static let maxSimilar = 3
    public static let maxSummaryLength = 200

    public static let rule = "Before editing a file listed here, call rc_activity_list with same_repo:true to see who owns it now, then choose another file, wait, or use a worktree. Do not redo work another run is doing."

    /// Nil when there is nothing to tell. `ownRoot` is the checkout this run edits, so runs sharing it are marked.
    public static func render(
        runs: [ConcurrentRunSummary],
        notices: [ConcurrentWorkNotice] = [],
        similar: [SimilarWork] = [],
        ownRoot: String?,
        now: Date = Date()
    ) -> String? {
        guard !runs.isEmpty || !notices.isEmpty || !similar.isEmpty else { return nil }
        var lines = ["<concurrent_work>"]
        if !runs.isEmpty {
            lines.append("Other agent runs are working in this repository right now:")
            // Runs with edits first: they are the ones that can collide.
            let ranked = runs.filter { !$0.editingFiles.isEmpty } + runs.filter { $0.editingFiles.isEmpty }
            for run in ranked.prefix(maxRuns) { lines.append(describe(run, ownRoot: ownRoot, now: now)) }
            if ranked.count > maxRuns { lines.append("- and \(ranked.count - maxRuns) more; call rc_activity_list with same_repo:true for the full list.") }
        }
        if !notices.isEmpty {
            lines.append("Changed under you since your last turn:")
            for notice in notices.suffix(maxNotices) {
                lines.append("- `\(clean(notice.path))` was also edited by \(clean(notice.editor)) \(ago(notice.at, now: now)).")
            }
        }
        if !similar.isEmpty {
            lines.append("Similar work already exists. Check it first; do not redo it:")
            for work in similar.prefix(maxSimilar) { lines.append(describe(work, now: now)) }
        }
        if !runs.isEmpty || !notices.isEmpty { lines.append(rule) }
        lines.append("</concurrent_work>")
        return lines.joined(separator: "\n")
    }

    /// One-line warning for a tool result: the work exists, the call went ahead anyway.
    public static func similarWarning(_ work: [SimilarWork], now: Date = Date()) -> String? {
        guard !work.isEmpty else { return nil }
        let lines = work.prefix(maxSimilar).map { describe($0, now: now) }
        return "Similar work already exists in this Bot's conversations. Check it before repeating it; this call was not blocked.\n" + lines.joined(separator: "\n")
    }

    private static func describe(_ run: ConcurrentRunSummary, ownRoot: String?, now: Date) -> String {
        var line = "- \(label(title: run.threadTitle, bot: run.botName))"
        let objective = clean(run.objective)
        if !objective.isEmpty { line += ": \"\(objective)\"" }
        var place: [String] = []
        if let branch = run.branch, !branch.isEmpty { place.append("branch \(clean(branch))") }
        place.append(run.worktreePath == ownRoot ? "same checkout as you" : "worktree \(clean(run.worktreePath))")
        line += " (\(place.joined(separator: ", ")))"
        if run.editingFiles.isEmpty {
            line += "; no edits yet"
        } else {
            let shown = run.editingFiles.prefix(maxFilesPerRun).map { "`\(clean($0.path))` (started \(ago($0.since, now: now)))" }
            line += "; editing " + shown.joined(separator: ", ")
            if run.editingFiles.count > maxFilesPerRun { line += ", and \(run.editingFiles.count - maxFilesPerRun) more" }
        }
        return line
    }

    private static func describe(_ work: SimilarWork, now: Date) -> String {
        var line = "- thread '\(clean(work.threadTitle))', "
        if work.isRunning {
            line += "running"
        } else if let finished = work.finishedAt {
            line += "finished \(ago(finished, now: now))"
        } else {
            line += "finished"
        }
        if !work.files.isEmpty {
            line += "; files " + work.files.prefix(maxFilesPerRun).map { "`\(clean($0))`" }.joined(separator: ", ")
        }
        if let summary = work.resultSummary.map(clean), !summary.isEmpty {
            line += "; result: \(String(summary.prefix(maxSummaryLength)))"
        }
        return line
    }

    public static func label(title: String, bot: String?) -> String {
        let name = clean(title)
        let base = name.isEmpty ? "a thread" : "thread '\(name)'"
        guard let bot = bot.map(clean), !bot.isEmpty else { return base }
        return "\(base) (Bot \(bot))"
    }

    /// Titles, objectives and paths come from users and files: one line, no tag syntax.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func ago(_ date: Date, now: Date) -> String {
        let text = minutesText(now.timeIntervalSince(date))
        return text == "just now" ? text : text + " ago"
    }

    private static func minutesText(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours < 48 ? "\(hours) h" : "\(hours / 24) d"
    }
}
