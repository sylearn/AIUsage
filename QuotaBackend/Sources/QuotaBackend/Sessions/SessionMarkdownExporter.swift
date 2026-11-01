import Foundation

// MARK: - Session Center · Markdown export
// 把一段会话导出为 Markdown；界面文案由调用方传入，导出逻辑不绑定语言。

public enum SessionMarkdownExporter {
    public struct Labels: Sendable {
        public var you = "You"
        public var session = "Session"
        public var directory = "Directory"
        public var branch = "Branch"
        public var model = "Model"
        public var updated = "Updated"
        public var contextCompacted = "Context compacted"
        public var interrupted = "Interrupted"
        public var omitted: @Sendable (Int) -> String = { "\($0) earlier items omitted" }

        public init() {}
    }

    public static func markdown(
        summary: SessionSummary,
        transcript: SessionTranscript,
        labels: Labels = Labels(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines = ["# " + summary.title, ""]
        lines.append("- \(summary.tool.displayName) · \(labels.session) \(code(summary.sessionID))")
        if let directory = summary.directory { lines.append("- \(labels.directory): \(code(directory))") }
        if let branch = summary.gitBranch { lines.append("- \(labels.branch): \(code(branch))") }
        if let model = summary.model { lines.append("- \(labels.model): \(model)") }
        lines.append("- \(labels.updated): \(formatter.string(from: summary.updatedAt))")
        lines.append(contentsOf: ["", "---", ""])
        if transcript.omittedCount > 0 {
            lines.append(contentsOf: ["> " + labels.omitted(transcript.omittedCount), ""])
        }

        for item in transcript.items {
            let time = item.date.map { " · " + formatter.string(from: $0) } ?? ""
            switch item.entry {
            case .prompt(let text):
                lines.append(contentsOf: ["### \(labels.you)\(time)", "", text, ""])
            case .reply(let text):
                lines.append(contentsOf: ["### \(summary.tool.displayName)\(time)", "", text, ""])
            case .steps(let steps):
                for step in steps {
                    let mark = step.failed ? "✗" : "✓"
                    var line = "- \(mark) \(step.name)"
                    if !step.detail.isEmpty { line += " " + code(step.detail) }
                    if let note = step.failureNote, !note.isEmpty { line += " — " + note }
                    lines.append(line)
                }
                lines.append("")
            case .notice(let notice):
                let text = notice == .contextCompacted ? labels.contextCompacted : labels.interrupted
                lines.append(contentsOf: ["> " + text, ""])
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 行内代码；内容本身含反引号时用双反引号包裹。
    static func code(_ text: String) -> String {
        text.contains("`") ? "`` " + text + " ``" : "`" + text + "`"
    }
}
