import Foundation

public enum CodexFollowUpQuestion {
    private static let prefix = "final-answer:"

    public static func requestID(for turnID: String) -> String { prefix + turnID }

    static func isRequestID(_ requestID: String?) -> Bool {
        requestID?.hasPrefix(prefix) == true
    }

    private static let choiceRow = try! NSRegularExpression(
        pattern: #"^(?:[-*]\s+[A-D1-4]$|(?:[-*]\s*)?(?:[A-Da-d1-4][.、):：）]|\([A-Da-d1-4]\))\s*\S)"#
    )

    private static let replyInstruction = try! NSRegularExpression(
        pattern: #"""
            ^(?:为了继续[，,\s]*|接下来[，,\s]*)?
            (?:
                请(?:(?:你|您)|在(?:界面|选择框)(?:中|里))?(?:选|回复|回答|确认|告诉我|给我|补充|提供|说明|指定|发我)
                | (?:回复|回答)\s*[A-D1-4]
                | (?:我(?:会|先|在)?)?等(?:待)?(?:你|您)(?:选|的?回复|的?答复|的?回答|确认|补充)
                | 我需要(?:你|您)(?:确认|选择|回复|回答|补充|提供|告诉我)
                | please\s+(?:reply|answer|choose|select|pick|confirm|tell\s+me|provide|specify|clarify|send\s+me)\b
                | (?:i\s+need|i[’']m\s+waiting\s+for)\s+you\s+to\s+(?:answer|reply|choose|confirm|provide)\b
            )
            """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    private static let directQuestion = try! NSRegularExpression(
        pattern: #"""
            ^(?:
                (?:你|您)(?:想|希望|更倾向|更希望|愿意|要|能否|是否|介意|方便|觉得|选|能(?:确认|提供|补充|说明|告诉我))
                | (?:能否|方便)(?:确认|补充|提供|告诉我|说明)
                | 要(?:我|不要我)(?:继续|开始|执行|按)
                | [A-D1-4]\s*(?:还是|或)\s*[A-D1-4]
                | (?:would|could|can|will)\s+you\s+(?:prefer|choose|confirm|provide|clarify|tell\s+me|share|select|like)
                | which\s+(?:option|approach|version|one)\b
                | what\s+(?:would|do)\s+you\s+(?:prefer|want|think)
                | should\s+i\s+(?:go\s+ahead|continue|proceed|use)
            )
            """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    static func requiresReply(_ text: String) -> Bool {
        guard text.utf8.count <= 64 * 1024 else { return false }
        var fence: String?
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let delimiter = ["\u{60}\u{60}\u{60}", "~~~"].first(where: line.hasPrefix) {
                if fence == delimiter { fence = nil }
                else if fence == nil { fence = delimiter }
                continue
            }
            guard fence == nil, !line.isEmpty, !line.hasPrefix(">"), !line.hasPrefix("|"),
                  !raw.hasPrefix("    "), !raw.hasPrefix("\t") else { continue }
            lines.append(line.replacingOccurrences(of: "**", with: ""))
        }
        let optionsAtEnd = lines.reversed().prefix { matches(choiceRow, $0) }.count
        guard let lastLine = lines.dropLast(optionsAtEnd >= 2 ? optionsAtEnd : 0).last,
              !lastLine.hasPrefix("#") else { return false }
        let isBullet = lastLine.hasPrefix("- ") || lastLine.hasPrefix("* ")
        let line = isBullet ? String(lastLine.dropFirst(2)) : lastLine
        let punctuation = CharacterSet(charactersIn: "。！？.!?")
        let body = line.trimmingCharacters(in: punctuation)
        guard let sentence = body.components(separatedBy: punctuation).last?
            .trimmingCharacters(in: .whitespaces), !sentence.isEmpty else { return false }
        return matches(replyInstruction, sentence)
            || ((line.hasSuffix("？") || line.hasSuffix("?")) && matches(directQuestion, sentence))
    }

    private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
