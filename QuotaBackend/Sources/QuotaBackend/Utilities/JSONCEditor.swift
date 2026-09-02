import Foundation

// MARK: - JSONC Editor
// 在 JSONC（带 // 与 /* */ 注释、可含尾随逗号的 JSON）文本上做「按目标字典对齐」的最小文本编辑，
// 最大限度保留原有注释与排版。用途：OpenCode 接管 opencode.jsonc 时注入受管块而不丢用户注释。
//
// 数据来源/写入目标: ~/.config/opencode/opencode.jsonc。
// 工作方式: 递归比对「原文解析树（带源码区间）」与目标字典，仅对发生变化的键做插入/替换/删除，
//           未变化的子树（含其中注释）原样保留。
// 安全: 解析失败或写后自校验（重新解析 == 目标）不通过时返回 nil，由调用方回退结构化写回，
//       绝不产出与目标语义不一致的配置。

public enum JSONCEditor {

    /// 解析根节点为对象的 JSON/JSONC。发现与编辑共用同一解析器，
    /// 避免“能识别但不能编辑”或“能编辑但被判非法”的口径分裂。
    public static func parseObject(_ text: String) -> [String: Any]? {
        var parser = Parser(chars: Array(text))
        guard let root = try? parser.parseDocument(), root.kind == .object else { return nil }
        return root.value as? [String: Any]
    }

    /// 把 `baseText` 的 JSONC 文本结构对齐到 `target`，尽量保留注释与格式。
    /// - Returns: 对齐后的 JSONC 文本；当无法安全完成（解析失败/编辑冲突/自校验失败）时返回 nil。
    public static func merge(baseText: String, target: [String: Any]) -> String? {
        let chars = Array(baseText)
        var parser = Parser(chars: chars)
        guard let root = try? parser.parseDocument(), root.kind == .object else { return nil }

        let indentUnit = detectIndentUnit(chars)
        var edits: [Edit] = []
        collectObjectEdits(node: root, target: target, level: 0, indentUnit: indentUnit, edits: &edits)
        guard let patched = applyEdits(chars, edits) else { return nil }

        // 写后自校验：重新解析对齐结果，结构必须与目标完全一致，否则放弃（回退结构化写回）。
        var verifier = Parser(chars: Array(patched))
        guard let verified = try? verifier.parseDocument(),
              jsonEqual(verified.value, target) else { return nil }
        return patched
    }

    // MARK: - Edit Model

    private struct Edit {
        let start: Int
        let end: Int           // 半开区间 [start, end)
        let replacement: String
    }

    /// 自下而上（按 start 降序）应用编辑；要求各编辑区间互不重叠，重叠则返回 nil。
    private static func applyEdits(_ chars: [Character], _ edits: [Edit]) -> String? {
        guard !edits.isEmpty else { return String(chars) }
        let sorted = edits.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        var lastEnd = -1
        for edit in sorted {
            if edit.start < lastEnd { return nil }
            lastEnd = max(lastEnd, edit.end)
        }
        var out = chars
        for edit in sorted.reversed() {
            out.replaceSubrange(edit.start..<edit.end, with: Array(edit.replacement))
        }
        return String(out)
    }

    // MARK: - Diff → Edits

    private static func collectObjectEdits(
        node: Node,
        target: [String: Any],
        level: Int,
        indentUnit: String,
        edits: inout [Edit]
    ) {
        var existing: [String: Member] = [:]
        for member in node.members { existing[member.key] = member }

        // 删除：原文中存在但目标已无的键（连同其分隔逗号/前导空白到下一个键）。
        for (idx, member) in node.members.enumerated() where target[member.key] == nil {
            let delEnd = idx + 1 < node.members.count ? node.members[idx + 1].memberStart : node.contentEnd
            edits.append(Edit(start: member.memberStart, end: delEnd, replacement: ""))
        }

        // 更新/递归 + 收集新增键。
        var inserts: [(String, Any)] = []
        for (key, targetValue) in target {
            guard let member = existing[key] else {
                inserts.append((key, targetValue))
                continue
            }
            if let targetDict = targetValue as? [String: Any], member.node.kind == .object {
                collectObjectEdits(node: member.node, target: targetDict, level: level + 1, indentUnit: indentUnit, edits: &edits)
            } else if !jsonEqual(member.node.value, targetValue) {
                let replacement = serialize(targetValue, level: level + 1, indentUnit: indentUnit)
                edits.append(Edit(start: member.node.start, end: member.node.end, replacement: replacement))
            }
        }

        guard !inserts.isEmpty else { return }
        appendInsertEdits(inserts, node: node, target: target, level: level, indentUnit: indentUnit, edits: &edits)
    }

    private static func appendInsertEdits(
        _ inserts: [(String, Any)],
        node: Node,
        target: [String: Any],
        level: Int,
        indentUnit: String,
        edits: inout [Edit]
    ) {
        let memberIndent = String(repeating: indentUnit, count: level + 1)
        let braceIndent = String(repeating: indentUnit, count: level)
        let sortedInserts = inserts.sorted { $0.0 < $1.0 }

        func memberText(_ key: String, _ value: Any) -> String {
            "\"\(escapeString(key))\": " + serialize(value, level: level + 1, indentUnit: indentUnit)
        }

        // 锚点优先选「最后一个保留下来的成员」之后插入：前导逗号 + 换行，逗号/无逗号原文都干净。
        if let lastKept = node.members.last(where: { target[$0.key] != nil }) {
            var text = ""
            for (key, value) in sortedInserts {
                text += ",\n" + memberIndent + memberText(key, value)
            }
            edits.append(Edit(start: lastKept.node.end, end: lastKept.node.end, replacement: text))
            return
        }

        // 对象为空（或成员将被全部删除）：花括号间若仅空白则整体重排为带新成员；否则在 `{` 后插入。
        let interIsBlank = (node.contentStart..<node.contentEnd).allSatisfy { isWhitespace(node.chars[$0]) }
        let body = sortedInserts.map { memberIndent + memberText($0.0, $0.1) }.joined(separator: ",\n")
        if interIsBlank {
            let replacement = "\n" + body + "\n" + braceIndent
            edits.append(Edit(start: node.contentStart, end: node.contentEnd, replacement: replacement))
        } else {
            let replacement = "\n" + body + ","
            edits.append(Edit(start: node.contentStart, end: node.contentStart, replacement: replacement))
        }
    }

    // MARK: - Serialization (stable, sorted keys, comment-free值块)

    private static func serialize(_ value: Any, level: Int, indentUnit: String) -> String {
        let indent = String(repeating: indentUnit, count: level)
        let childIndent = String(repeating: indentUnit, count: level + 1)

        if let dict = value as? [String: Any] {
            if dict.isEmpty { return "{}" }
            let lines = dict.keys.sorted().map { key in
                childIndent + "\"\(escapeString(key))\": " + serialize(dict[key]!, level: level + 1, indentUnit: indentUnit)
            }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
        }
        if let array = value as? [Any] {
            if array.isEmpty { return "[]" }
            let lines = array.map { childIndent + serialize($0, level: level + 1, indentUnit: indentUnit) }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + indent + "]"
        }
        if value is NSNull { return "null" }
        if let string = value as? String { return "\"\(escapeString(string))\"" }
        if let number = value as? NSNumber { return numberLiteral(number) }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let int = value as? Int { return String(int) }
        if let double = value as? Double { return numberLiteral(NSNumber(value: double)) }
        return "null"
    }

    private static func numberLiteral(_ number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        let value = number.doubleValue
        if value.rounded() == value && abs(value) < 9e15 {
            return String(number.intValue)
        }
        return String(value)
    }

    private static func escapeString(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count + 2)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: - Value Equality

    private static func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if let ld = lhs as? [String: Any], let rd = rhs as? [String: Any] {
            guard ld.count == rd.count else { return false }
            for (key, lvalue) in ld {
                guard let rvalue = rd[key], jsonEqual(lvalue, rvalue) else { return false }
            }
            return true
        }
        if let la = lhs as? [Any], let ra = rhs as? [Any] {
            guard la.count == ra.count else { return false }
            for idx in la.indices where !jsonEqual(la[idx], ra[idx]) { return false }
            return true
        }
        if lhs is NSNull, rhs is NSNull { return true }
        if let ls = lhs as? String, let rs = rhs as? String { return ls == rs }
        if let ln = lhs as? NSNumber, let rn = rhs as? NSNumber { return ln == rn }
        return false
    }

    // MARK: - Indentation Detection

    /// 取原文第一处「换行后非空缩进」作为缩进单位（一级成员缩进），无则默认两空格。
    private static func detectIndentUnit(_ chars: [Character]) -> String {
        var index = 0
        while index < chars.count {
            if chars[index] == "\n" {
                var cursor = index + 1
                var whitespace = ""
                while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" {
                    whitespace.append(chars[cursor]); cursor += 1
                }
                if !whitespace.isEmpty, cursor < chars.count, chars[cursor] != "\n", chars[cursor] != "\r" {
                    return whitespace
                }
            }
            index += 1
        }
        return "  "
    }

    private static func isWhitespace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r"
    }

    // MARK: - Parse Tree

    private enum Kind { case object, array, string, number, bool, null }

    private final class Node {
        let kind: Kind
        let start: Int
        var end: Int
        var value: Any
        // object only
        let chars: [Character]
        var members: [Member] = []
        var contentStart: Int = 0   // `{` 之后的位置
        var contentEnd: Int = 0     // `}` 所在位置

        init(kind: Kind, start: Int, chars: [Character]) {
            self.kind = kind
            self.start = start
            self.end = start
            self.value = NSNull()
            self.chars = chars
        }
    }

    private struct Member {
        let key: String
        let node: Node
        let memberStart: Int        // key 起始引号位置
    }

    private struct ParseError: Error {}

    // MARK: - Recursive Descent Parser

    private struct Parser {
        let chars: [Character]
        var i = 0

        init(chars: [Character]) { self.chars = chars }

        mutating func parseDocument() throws -> Node {
            skipTrivia()
            let node = try parseValue()
            skipTrivia()
            guard i >= chars.count else { throw ParseError() }
            return node
        }

        mutating func skipTrivia() {
            while i < chars.count {
                let c = chars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1; continue }
                if c == "/", i + 1 < chars.count {
                    if chars[i + 1] == "/" {
                        i += 2
                        while i < chars.count, chars[i] != "\n" { i += 1 }
                        continue
                    }
                    if chars[i + 1] == "*" {
                        i += 2
                        while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                        i = min(i + 2, chars.count)
                        continue
                    }
                }
                break
            }
        }

        mutating func parseValue() throws -> Node {
            guard i < chars.count else { throw ParseError() }
            switch chars[i] {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return try parseStringNode()
            case "t", "f": return try parseBool()
            case "n": return try parseNull()
            default:
                let c = chars[i]
                if c == "-" || (c >= "0" && c <= "9") { return try parseNumber() }
                throw ParseError()
            }
        }

        mutating func parseObject() throws -> Node {
            let node = Node(kind: .object, start: i, chars: chars)
            var dict: [String: Any] = [:]
            i += 1
            node.contentStart = i
            while true {
                skipTrivia()
                guard i < chars.count else { throw ParseError() }
                if chars[i] == "}" { node.contentEnd = i; i += 1; break }
                guard chars[i] == "\"" else { throw ParseError() }
                let keyStart = i
                let key = try parseStringLiteral()
                skipTrivia()
                guard i < chars.count, chars[i] == ":" else { throw ParseError() }
                i += 1
                skipTrivia()
                let valueNode = try parseValue()
                node.members.append(Member(key: key, node: valueNode, memberStart: keyStart))
                dict[key] = valueNode.value
                skipTrivia()
                if i < chars.count, chars[i] == "," { i += 1; continue }
                if i < chars.count, chars[i] == "}" { node.contentEnd = i; i += 1; break }
                throw ParseError()
            }
            node.end = i
            node.value = dict
            return node
        }

        mutating func parseArray() throws -> Node {
            let node = Node(kind: .array, start: i, chars: chars)
            var array: [Any] = []
            i += 1
            while true {
                skipTrivia()
                guard i < chars.count else { throw ParseError() }
                if chars[i] == "]" { i += 1; break }
                let element = try parseValue()
                array.append(element.value)
                skipTrivia()
                if i < chars.count, chars[i] == "," { i += 1; continue }
                if i < chars.count, chars[i] == "]" { i += 1; break }
                throw ParseError()
            }
            node.end = i
            node.value = array
            return node
        }

        mutating func parseStringNode() throws -> Node {
            let start = i
            let string = try parseStringLiteral()
            let node = Node(kind: .string, start: start, chars: chars)
            node.end = i
            node.value = string
            return node
        }

        mutating func parseStringLiteral() throws -> String {
            guard i < chars.count, chars[i] == "\"" else { throw ParseError() }
            i += 1
            var out = ""
            while i < chars.count {
                let c = chars[i]
                if c == "\\" {
                    i += 1
                    guard i < chars.count else { throw ParseError() }
                    switch chars[i] {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        guard i + 4 < chars.count else { throw ParseError() }
                        let hex = String(chars[(i + 1)...(i + 4)])
                        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { throw ParseError() }
                        out.unicodeScalars.append(scalar)
                        i += 4
                    default: throw ParseError()
                    }
                    i += 1
                } else if c == "\"" {
                    i += 1
                    return out
                } else {
                    out.append(c)
                    i += 1
                }
            }
            throw ParseError()
        }

        mutating func parseBool() throws -> Node {
            let start = i
            if matchLiteral("true") {
                let node = Node(kind: .bool, start: start, chars: chars)
                node.end = i; node.value = NSNumber(value: true); return node
            }
            if matchLiteral("false") {
                let node = Node(kind: .bool, start: start, chars: chars)
                node.end = i; node.value = NSNumber(value: false); return node
            }
            throw ParseError()
        }

        mutating func parseNull() throws -> Node {
            let start = i
            guard matchLiteral("null") else { throw ParseError() }
            let node = Node(kind: .null, start: start, chars: chars)
            node.end = i
            node.value = NSNull()
            return node
        }

        mutating func parseNumber() throws -> Node {
            let start = i
            var text = ""
            while i < chars.count {
                let c = chars[i]
                if c == "-" || c == "+" || c == "." || c == "e" || c == "E" || (c >= "0" && c <= "9") {
                    text.append(c); i += 1
                } else { break }
            }
            guard !text.isEmpty else { throw ParseError() }
            let node = Node(kind: .number, start: start, chars: chars)
            node.end = i
            if let intValue = Int(text) {
                node.value = NSNumber(value: intValue)
            } else if let doubleValue = Double(text) {
                node.value = NSNumber(value: doubleValue)
            } else {
                throw ParseError()
            }
            return node
        }

        mutating func matchLiteral(_ literal: String) -> Bool {
            let literalChars = Array(literal)
            guard i + literalChars.count <= chars.count else { return false }
            for offset in 0..<literalChars.count where chars[i + offset] != literalChars[offset] {
                return false
            }
            i += literalChars.count
            return true
        }
    }
}
