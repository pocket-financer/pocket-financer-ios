import Foundation

/// Frozen extractor offsets are Unicode-scalar offsets, never UTF-16 offsets.
nonisolated struct UnicodeScalarSpan: Codable, Equatable, Hashable, Sendable {
    let startScalar: Int
    let endScalar: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case startScalar = "start_scalar"
        case endScalar = "end_scalar"
        case text
    }

    init(source: String, startScalar: Int, endScalar: Int, text: String) throws {
        guard startScalar >= 0, endScalar > startScalar else {
            throw SmsExtractorValidationError.evidenceOutOfBounds
        }
        let scalars = source.unicodeScalars
        guard
            let lower = scalars.index(
                scalars.startIndex,
                offsetBy: startScalar,
                limitedBy: scalars.endIndex
            ),
            let upper = scalars.index(
                scalars.startIndex,
                offsetBy: endScalar,
                limitedBy: scalars.endIndex
            ),
            lower < upper
        else {
            throw SmsExtractorValidationError.evidenceOutOfBounds
        }
        let expected = String(scalars[lower..<upper])
        guard expected == text else { throw SmsExtractorValidationError.evidenceMismatch }
        self.startScalar = startScalar
        self.endScalar = endScalar
        self.text = text
    }

    init?(source: String, nsRange: NSRange) {
        guard
            nsRange.location >= 0,
            nsRange.length > 0,
            nsRange.location <= source.utf16.count,
            nsRange.length <= source.utf16.count - nsRange.location
        else { return nil }
        let utf16 = source.utf16
        let utf16Start = utf16.index(utf16.startIndex, offsetBy: nsRange.location)
        let utf16End = utf16.index(utf16Start, offsetBy: nsRange.length)
        let scalars = source.unicodeScalars
        guard
            let scalarStart = utf16Start.samePosition(in: scalars),
            let scalarEnd = utf16End.samePosition(in: scalars),
            scalarStart < scalarEnd
        else { return nil }
        let startScalar = scalars.distance(from: scalars.startIndex, to: scalarStart)
        let endScalar = scalars.distance(from: scalars.startIndex, to: scalarEnd)
        let text = String(scalars[scalarStart..<scalarEnd])
        guard !text.isEmpty else { return nil }
        self.startScalar = startScalar
        self.endScalar = endScalar
        self.text = text
    }

    func stringRange(in source: String) throws -> Range<String.Index> {
        guard startScalar >= 0, endScalar > startScalar else {
            throw SmsExtractorValidationError.evidenceOutOfBounds
        }
        let scalars = source.unicodeScalars
        guard
            let lower = scalars.index(
                scalars.startIndex,
                offsetBy: startScalar,
                limitedBy: scalars.endIndex
            ),
            let upper = scalars.index(
                scalars.startIndex,
                offsetBy: endScalar,
                limitedBy: scalars.endIndex
            ),
            lower < upper
        else {
            throw SmsExtractorValidationError.evidenceOutOfBounds
        }
        return lower..<upper
    }

    func nsRange(in source: String) throws -> NSRange {
        let range = try stringRange(in: source)
        guard String(source.unicodeScalars[range]) == text else {
            throw SmsExtractorValidationError.evidenceMismatch
        }
        let utf16 = source.utf16
        guard
            let utf16Start = range.lowerBound.samePosition(in: utf16),
            let utf16End = range.upperBound.samePosition(in: utf16)
        else {
            throw SmsExtractorValidationError.evidenceOutOfBounds
        }
        let location = utf16.distance(from: utf16.startIndex, to: utf16Start)
        let length = utf16.distance(from: utf16Start, to: utf16End)
        return NSRange(location: location, length: length)
    }
}
