import Foundation

/// Frozen extractor offsets are Unicode-scalar offsets, never UTF-16 offsets.
nonisolated struct UnicodeScalarSpan: Codable, Equatable, Sendable {
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
                scalars.startIndex, offsetBy: startScalar, limitedBy: scalars.endIndex
            ),
            let upper = scalars.index(
                scalars.startIndex, offsetBy: endScalar, limitedBy: scalars.endIndex
            ),
            let start = String.Index(lower, within: source),
            let end = String.Index(upper, within: source)
        else {
            throw SmsExtractorValidationError.evidenceOutOfBounds
        }
        let expected = String(source[start..<end])
        guard expected == text else { throw SmsExtractorValidationError.evidenceMismatch }
        self.startScalar = startScalar
        self.endScalar = endScalar
        self.text = text
    }

    func stringRange(in source: String) throws -> Range<String.Index> {
        guard
            let lower = source.unicodeScalars.index(
                source.unicodeScalars.startIndex, offsetBy: startScalar, limitedBy: source.unicodeScalars.endIndex),
            let upper = source.unicodeScalars.index(
                source.unicodeScalars.startIndex, offsetBy: endScalar, limitedBy: source.unicodeScalars.endIndex),
            let start = String.Index(lower, within: source), let end = String.Index(upper, within: source)
        else { throw SmsExtractorValidationError.evidenceOutOfBounds }
        return start..<end
    }

    func nsRange(in source: String) throws -> NSRange {
        NSRange(try stringRange(in: source), in: source)
    }
}
