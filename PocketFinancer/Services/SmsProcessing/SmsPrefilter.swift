import Foundation

/// Pure, deterministic, strictly fail-open SMS prefilter (`sms-prefilter/1`).
///
/// Mirrors `pocketfinancer_sms.prefilter` identically: inspects only the immutable
/// SMS body and excludes unambiguously non-transactional messages before inference.
nonisolated enum SmsPrefilter {
    static let policyID = "sms-prefilter/1"

    enum Decision: String, Equatable, Sendable {
        case pass
        case exclude
    }

    enum Reason: String, Equatable, Sendable {
        case empty
        case noDigits = "no_digits"
        case gamingPromo = "gaming_promo"
        case collectOrMandateRequest = "collect_or_mandate_request"
        case otpVerification = "otp_verification"
        case telecomNotice = "telecom_notice"
        case brokerageEodReport = "brokerage_eod_report"
        case noFinancialCue = "no_financial_cue"
        case eligible
    }

    struct Result: Equatable, Sendable {
        let decision: Decision
        let reason: Reason
    }

    private static let hasDigit = RegexPattern(#"\d"#, options: [])
    // Future/conditional/negated clauses (for example, "Once approved, money will
    // be debited") must not count as completed movement inside the guard.
    private static let futureOrConditional = RegexPattern(
        #"(?:"#
            + #"\b(?:once\s+approved|on\s+approving\s+the\s+request)\b[^.!?\n]*|"#
            + #"\b(?:will|shall|may|might|would|should|scheduled\s+to|set\s+to|about\s+to|"#
            + #"going\s+to|yet\s+to|not(?:\s+been)?)\s+"#
            + #"(?:be\s+)?(?:debited|credited|spent|deducted|withdrawn|deposited|transferred|"#
            + #"refunded|reversed|charged)\b"#
            + #")"#
    )
    private static let completedGuard = RegexPattern(
        #"\b(?:"#
            + #"debited|credited|spent|deducted|withdrawn|deposited|transferred|refunded|reversed|"#
            + #"autopaid|auto-?debited|sent\s+(?:rs|inr|₹)|money\s+transfer|"#
            + #"payment\s+of\s+(?:rs\.?|inr|₹).*(?:successful|received)|"#
            + #"transaction\s+of\s+(?:rs\.?|inr|₹).*successful|"#
            + #"has\s+been\s+received|received\s+towards|without\s+otp|txn\s+(?:rs\.?|inr|₹)"#
            + #")\b"#
    )
    private static let gamingPromo = RegexPattern(
        #"\b(?:rummy|my11circle|dream11|junglee\s*rummy|mpl\s*pro|winzo)\b"#
    )
    private static let collectOrMandateRequest = RegexPattern(
        #"(?:"#
            + #"\bhas\s+requested\s+(?:rs\.?|inr|₹|money)\b|"#
            + #"\bonce\s+approved,?\s*(?:money|the\s+amount)\s+will\s+be\s+debited\b|"#
            + #"\bon\s+approving\s+the\s+request\b|"#
            + #"\bupi[- ]mandate\s+request\b|"#
            + #"\bcollect\s+request\b"#
            + #")"#
    )
    private static let otpVerification = RegexPattern(
        #"(?:"#
            + #"\b(?:otp|one[- ]time[- ]password|verification\s+code|security\s+code|"#
            + #"login\s+code|auth(?:entication)?\s+code)\b.*\b(?:is|for|:)\b|"#
            + #"\b\d{4,8}\b\s+is\s+(?:your|the)\s+(?:otp|one[- ]time[- ]password|"#
            + #"verification\s+code|security\s+code|secret\s+code|pin|mpin)|"#
            + #"\botp\s*(?:is|:|-)\s*\d{4,8}\b|"#
            + #"\buse\s+(?:otp\s*)?\d{4,8}\s+(?:as|to)\b"#
            + #")"#
    )
    private static let telecomNotice = RegexPattern(
        #"(?:"#
            + #"\bdaily\s+data\s+quota\s+used\b|"#
            + #"\bhigh[- ]speed\s+data\b|"#
            + #"\bplan\s+has\s+expired\b|"#
            + #"प्लॅन\s+(?:समाप्त|लवकरच)|"#
            + #"कॉलरट्यून्स|"#
            + #"\bvi\s+super\s+hour\b|"#
            + #"\bvi\s+exclusive\b|"#
            + #"\bbinge\s+all\s+night\b|"#
            + #"\bcaller\s*tune\b|"#
            + #"\bmissed\s+call\s+alert\b|"#
            + #"\brecharge\s+(?:now|today|with\s+rs|your\s+(?:jio|vi|airtel))\b|"#
            + #"\bunlimited\s+pack\b.*\bexpir"#
            + #")"#
    )
    private static let brokerageEodReport = RegexPattern(
        #"(?:"#
            + #"\breported\s+your\s+fund\s+bal(?:ance)?\b|"#
            + #"\byour\s+traded\s+value\s+for\b.*national\s+stock\s+exchange|"#
            + #"\btotal\s+amount\s+payable\s+to\s+you\s+at\s+the\s+end\s+of\s+date\b"#
            + #")"#
    )
    private static let financialCue = RegexPattern(
        #"(?:"#
            + #"rs\.?|inr|₹|usd|\$|eur|€|gbp|£|aed|sgd|aud|cad|jpy|¥|"#
            + #"\b(?:bank|a/c|acct|account|card|upi|vpa|neft|imps|rtgs|wallet|"#
            + #"paytm|phonepe|gpay|simpl|slice|onecard|cred|apay|amazon\s*pay|"#
            + #"debited|credited|spent|paid|deducted|withdrawn|deposited|transferred|"#
            + #"received|refund|reversed|txn|transaction|payment|bill|emi|mandate|"#
            + #"autopay|balance|salary|dividend|sip|redemption|payout)\b"#
            + #")"#
    )

    static func evaluate(_ body: String) -> Result {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Result(decision: .exclude, reason: .empty)
        }
        if !hasDigit.containsMatch(in: body) {
            return Result(decision: .exclude, reason: .noDigits)
        }
        if gamingPromo.containsMatch(in: body) {
            return Result(decision: .exclude, reason: .gamingPromo)
        }
        let sanitized = futureOrConditional.replacingMatches(in: body, with: " ")
        let hasCompleted = completedGuard.containsMatch(in: sanitized)
        if !hasCompleted && collectOrMandateRequest.containsMatch(in: body) {
            return Result(decision: .exclude, reason: .collectOrMandateRequest)
        }
        if !hasCompleted && otpVerification.containsMatch(in: body) {
            return Result(decision: .exclude, reason: .otpVerification)
        }
        if !hasCompleted && telecomNotice.containsMatch(in: body) {
            return Result(decision: .exclude, reason: .telecomNotice)
        }
        if brokerageEodReport.containsMatch(in: body) {
            return Result(decision: .exclude, reason: .brokerageEodReport)
        }
        if !financialCue.containsMatch(in: body) {
            return Result(decision: .exclude, reason: .noFinancialCue)
        }
        return Result(decision: .pass, reason: .eligible)
    }
}

nonisolated private struct RegexPattern: @unchecked Sendable {
    private let expression: NSRegularExpression

    init(
        _ pattern: String,
        options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
    ) {
        expression = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func containsMatch(in value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    func replacingMatches(in value: String, with template: String) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }
}
