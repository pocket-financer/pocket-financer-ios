import Foundation

enum StructuralClauseSegmenter {
    nonisolated static func clauses(in source: String) -> [SmsClause] {
        guard !source.isEmpty else { return [] }
        let separators = try! NSRegularExpression(
            pattern: #"(?:[\r\n]+|(?<=[.!?;])\s+|\s+(?:but|however|while|whereas)\s+)"#,
            options: [.caseInsensitive]
        )
        let full = NSRange(source.startIndex..., in: source)
        var cursor = 0
        var ranges: [NSRange] = []
        for match in separators.matches(in: source, range: full) {
            appendTrimmed(NSRange(location: cursor, length: match.range.location - cursor), source, &ranges)
            cursor = match.range.location + match.range.length
        }
        appendTrimmed(NSRange(location: cursor, length: full.length - cursor), source, &ranges)
        return ranges.enumerated().compactMap { index, range in
            evidence(source: source, utf16Range: range).map {
                SmsClause(id: "cl\(index)", evidence: $0, states: [], financialFamilies: [])
            }
        }
    }

    nonisolated static func clauseID(
        containing evidence: SmsEvidenceSpan,
        clauses: [SmsClause]
    ) -> String? {
        clauses.first {
            evidence.startCharacter >= $0.evidence.startCharacter
                && evidence.endCharacter <= $0.evidence.endCharacter
        }?.id
    }

    nonisolated static func evidence(source: String, utf16Range: NSRange) -> SmsEvidenceSpan? {
        guard let range = Range(utf16Range, in: source) else { return nil }
        let startCharacter = source[..<range.lowerBound].unicodeScalars.count
        let endCharacter = source[..<range.upperBound].unicodeScalars.count
        let startUTF8 = source[..<range.lowerBound].utf8.count
        let endUTF8 = source[..<range.upperBound].utf8.count
        return SmsEvidenceSpan(
            startCharacter: startCharacter,
            endCharacter: endCharacter,
            startUTF8: startUTF8,
            endUTF8: endUTF8,
            text: String(source[range])
        )
    }

    private nonisolated static func appendTrimmed(
        _ range: NSRange,
        _ source: String,
        _ output: inout [NSRange]
    ) {
        guard let swiftRange = Range(range, in: source) else { return }
        let substring = source[swiftRange]
        guard let first = substring.firstIndex(where: { !$0.isWhitespace }) else { return }
        let last = substring.lastIndex(where: { !$0.isWhitespace })!
        let end = substring.index(after: last)
        output.append(NSRange(first..<end, in: source))
    }
}
