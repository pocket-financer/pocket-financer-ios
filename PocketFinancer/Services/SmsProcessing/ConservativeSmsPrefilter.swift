import Foundation

/// Pure pilot policy; not wired into intake, inference, storage, or erasure.
///
/// conservative-prefilter-v1 excludes only whole ASCII messages matching the closed
/// templates below. ASCII case and runs of space/tab/CR/LF are ignored for matching
/// only. Non-ASCII and all other messages pass. Sender/analyzer/regex misses are not
/// inputs. Callers retain the unchanged source; passing is not a classification.
/// Intelligence owns semantics and the byte-identical prefilter-v1.json fixture.
nonisolated enum ConservativeSmsPrefilter {
    static let policyID = "conservative-prefilter-v1"

    enum Decision: String, Equatable {
        case pass
        case exclude
    }

    enum Reason: String, Equatable {
        case uncertain
        case standaloneVerification = "standalone_verification"
        case standalonePromotion = "standalone_promotion"
    }

    struct Result: Equatable {
        let decision: Decision
        let reason: Reason
    }

    static func evaluate(_ body: String) -> Result {
        if body.unicodeScalars.allSatisfy({ $0.value <= 127 }) {
            let normalized = body.lowercased()
                .replacingOccurrences(of: "[ \\t\\r\\n]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " "))
            if wholeMatch(
                #"your (?:otp|login verification code) is [0-9]{4,8}\. do not share it\."#,
                in: normalized
            ) {
                return Result(decision: .exclude, reason: .standaloneVerification)
            }
            if wholeMatch(
                #"advertisement: save [0-9]{1,2}% in our weekend sale\. shop now\."#,
                in: normalized
            ) {
                return Result(decision: .exclude, reason: .standalonePromotion)
            }
        }
        return Result(decision: .pass, reason: .uncertain)
    }

    private static func wholeMatch(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range)?.range == range
    }
}
