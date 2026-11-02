import Darwin
import Foundation

// MARK: - Session Center · JSONL reader
// 从指定偏移逐行读取 JSONL，并返回下次接着读的位置，供 Claude Code 会话文件增量解析：
// 会话进行中文件只会追加，每次只读新增的几行，不必把十几 MB 的文件整份重新解析。
// 以换行结尾的行读过就算数；文件末尾没有换行的半行可能正写到一半，只有 onLine 接受（解析成功）才算读过，
// 否则下次从这一行开头重读。单行最多缓冲 maxLineBytes 字节，超出的部分丢弃（截断的行解析失败，等于跳过）。

enum SessionLineReader {
    /// 逐行回调含任一 needle 的行，返回读到的位置；文件打不开或偏移越界返回 nil。
    /// onLine 的返回值只对末尾的半行有意义：返回 true 表示这一行完整可用。
    static func read(
        path: String,
        from offset: UInt64 = 0,
        needles: [Data],
        maxLineBytes: Int,
        onLine: (Data) -> Bool
    ) -> UInt64? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else { return nil }

        let cap = max(1, maxLineBytes)
        let chunkSize = 128 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var line = Data()
        line.reserveCapacity(64 * 1024)
        var position = offset
        var lineStart = offset

        func append(_ bytes: UnsafePointer<UInt8>, count: Int) {
            guard count > 0, line.count < cap else { return }
            line.append(bytes, count: min(count, cap - line.count))
        }

        func deliver() -> Bool {
            defer { line.removeAll(keepingCapacity: true) }
            guard !line.isEmpty, needles.isEmpty || needles.contains(where: { line.range(of: $0) != nil }) else {
                return false
            }
            let current = line
            return autoreleasepool { onLine(current) }
        }

        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, chunkSize) }
            guard count > 0 else { break }
            chunk.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var index = 0
                while index < count {
                    if let found = memchr(base + index, 0x0A, count - index) {
                        let newline = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                        append(base + index, count: newline - index)
                        _ = deliver()
                        index = newline + 1
                        lineStart = position + UInt64(index)
                    } else {
                        append(base + index, count: count - index)
                        index = count
                    }
                }
            }
            position += UInt64(count)
        }

        guard lineStart < position else { return position }
        return deliver() ? position : lineStart
    }
}
