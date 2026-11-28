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
        guard
            utf16Range.location >= 0,
            utf16Range.length >= 0,
            utf16Range.location <= source.utf16.count,
            utf16Range.length <= source.utf16.count - utf16Range.location
        else { return nil }
        let utf16 = source.utf16
        let utf16Start = utf16.index(utf16.startIndex, offsetBy: utf16Range.location)
        let utf16End = utf16.index(utf16Start, offsetBy: utf16Range.length)
        let scalars = source.unicodeScalars
        guard
            let lower = utf16Start.samePosition(in: scalars),
            let upper = utf16End.samePosition(in: scalars)
        else { return nil }
        let startCharacter = scalars.distance(from: scalars.startIndex, to: lower)
        let endCharacter = scalars.distance(from: scalars.startIndex, to: upper)
        let startUTF8 = source.utf8.distance(from: source.utf8.startIndex, to: lower)
        let endUTF8 = source.utf8.distance(from: source.utf8.startIndex, to: upper)
        return SmsEvidenceSpan(
            startCharacter: startCharacter,
            endCharacter: endCharacter,
            startUTF8: startUTF8,
            endUTF8: endUTF8,
            text: String(scalars[lower..<upper])
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
