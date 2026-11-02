import Foundation

nonisolated struct SmsStructuralMatch {
    fileprivate let source: String
    fileprivate let normalized: String
    fileprivate let result: NSTextCheckingResult
    fileprivate let sourceStartUTF16: [Int]
    fileprivate let sourceEndUTF16: [Int]

    func evidence(group: String? = nil) -> SmsEvidenceSpan? {
        let normalizedRange = group.map(result.range(withName:)) ?? result.range
        guard normalizedRange.location != NSNotFound, normalizedRange.length > 0 else { return nil }
        let endIndex = normalizedRange.location + normalizedRange.length - 1
        guard normalizedRange.location < sourceStartUTF16.count, endIndex < sourceEndUTF16.count else {
            return nil
        }
        return StructuralClauseSegmenter.evidence(
            source: source,
            utf16Range: NSRange(
                location: sourceStartUTF16[normalizedRange.location],
                length: sourceEndUTF16[endIndex] - sourceStartUTF16[normalizedRange.location]
            )
        )
    }

    func normalizedGroup(_ group: String) -> String? {
        let range = result.range(withName: group)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: normalized) else {
            return nil
        }
        return String(normalized[swiftRange])
    }
}

nonisolated struct SmsStructuralView {
    let source: String
    let normalized: String
    private let sourceStartUTF16: [Int]
    private let sourceEndUTF16: [Int]

    init(_ source: String) {
        self.source = source
        var normalized = ""
        var starts: [Int] = []
        var ends: [Int] = []
        var sourceUTF16Offset = 0
        var previousWasSpace = false
        for scalar in source.unicodeScalars {
            let sourceLength = String(scalar).utf16.count
            var mapped = String(scalar).precomposedStringWithCompatibilityMapping.lowercased()
            // Swift lowercasing is not a complete Unicode casefold. Freeze the
            // important multi-scalar case used by the reference behavior.
            if mapped == "ß" { mapped = "ss" }
            for outputScalar in mapped.unicodeScalars {
                let isSpace = CharacterSet.whitespacesAndNewlines.contains(outputScalar)
                if isSpace && previousWasSpace { continue }
                let output = isSpace ? " " : String(outputScalar)
                previousWasSpace = isSpace
                normalized.append(contentsOf: output)
                for _ in output.utf16 {
                    starts.append(sourceUTF16Offset)
                    ends.append(sourceUTF16Offset + sourceLength)
                }
            }
            sourceUTF16Offset += sourceLength
        }
        self.normalized = normalized
        sourceStartUTF16 = starts
        sourceEndUTF16 = ends
    }

    func matches(_ pattern: String) -> [SmsStructuralMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let full = NSRange(normalized.startIndex..., in: normalized)
        return regex.matches(in: normalized, range: full).map {
            SmsStructuralMatch(
                source: source,
                normalized: normalized,
                result: $0,
                sourceStartUTF16: sourceStartUTF16,
                sourceEndUTF16: sourceEndUTF16
            )
        }
    }
}
