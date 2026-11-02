import Darwin
import Foundation

// MARK: - Session Center · Claude Code 运行中的会话
// Claude Code 2.1 起每个进程在 <root>/sessions/<pid>.json 登记自己：sessionId、status（busy / idle …）、procStart。
// 判断规则与 Claude Code 自己判断「会话被谁占用」一致：PID 还活着，且进程启动时间与 procStart 吻合（防止 PID 被复用）。
// status 为 idle 表示在等输入，其余（busy、waiting 等）都算正在运行。转入后台的会话（parkedJobId）不算。
// 进程崩溃会留下登记文件，PID 检查能把它排除；更早的版本没有这个目录，就不显示「进行中」。

enum ClaudeSessionRegistry {
    static func activities(root: String) -> [String: SessionActivity] {
        let directory = (root as NSString).appendingPathComponent("sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [:] }
        var result: [String: SessionActivity] = [:]
        for name in names where name.hasSuffix(".json") {
            guard let record = SessionJSON.object(atPath: (directory as NSString).appendingPathComponent(name)),
                  let sessionID = record["sessionId"] as? String, !sessionID.isEmpty,
                  let pid = SessionJSON.int(record["pid"]), pid > 0, pid < Int(Int32.max),
                  record["parkedJobId"] == nil,
                  isRunning(pid_t(pid), procStart: record["procStart"] as? String) else { continue }
            let activity: SessionActivity = (record["status"] as? String) == "idle" ? .waiting : .working
            if result[sessionID] != .working { result[sessionID] = activity }
        }
        return result
    }

    /// PID 活着，且（能比对时）启动时间与登记的一致。
    static func isRunning(_ pid: pid_t, procStart: String?) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let procStart, let recorded = parseProcStart(procStart), let started = startTime(of: pid) else {
            return true
        }
        // procStart 实测是 UTC 的 ctime 格式；以防将来改成本地时间，两种都接受。
        let difference = started.timeIntervalSince(recorded)
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: started))
        return abs(difference) <= 2 || abs(difference + offset) <= 2
    }

    /// 「Mon Nov  2 01:12:05 2026」（日期前补空格）。
    static func parseProcStart(_ text: String) -> Date? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return procStartFormatter.date(from: collapsed)
    }

    static let procStartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}
