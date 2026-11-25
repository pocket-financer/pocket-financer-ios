import SwiftUI
import UIKit

enum SmsReviewField: String, CaseIterable, Identifiable {
    case amount, direction, account, counterparty

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct EvidenceSelectionTextView: UIViewRepresentable {
    let source: String
    let selections: [SmsReviewField: UnicodeScalarSpan?]
    let activeField: SmsReviewField
    let onSelectionChanged: (UnicodeScalarSpan) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .secondarySystemGroupedBackground
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        view.layer.cornerRadius = 12
        view.delegate = context.coordinator
        view.accessibilityLabel = "SMS evidence. \(activeField.label) is active."
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true
        let value = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
            ]
        )
        for field in SmsReviewField.allCases {
            guard let span = selections[field] ?? nil,
                let range = try? span.nsRange(in: source)
            else { continue }
            value.addAttributes(
                [
                    .backgroundColor: field.color.withAlphaComponent(0.36),
                    .underlineColor: field.color,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ],
                range: range
            )
        }
        view.attributedText = value
        if let span = selections[activeField] ?? nil,
            let range = try? span.nsRange(in: source)
        {
            view.selectedRange = range
        } else {
            view.selectedRange = NSRange(location: 0, length: 0)
        }
        view.accessibilityLabel =
            "SMS evidence. \(activeField.label) is active. Drag the selection handles to reselect it."
        context.coordinator.updating = false
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EvidenceSelectionTextView
        var updating = false

        init(parent: EvidenceSelectionTextView) { self.parent = parent }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating, textView.selectedRange.length > 0,
                let range = Range(textView.selectedRange, in: parent.source)
            else { return }
            let scalars = parent.source.unicodeScalars
            guard let scalarStart = range.lowerBound.samePosition(in: scalars),
                let scalarEnd = range.upperBound.samePosition(in: scalars)
            else { return }
            let start = scalars.distance(from: scalars.startIndex, to: scalarStart)
            let end = scalars.distance(from: scalars.startIndex, to: scalarEnd)
            let text = String(parent.source[range])
            guard
                let span = try? UnicodeScalarSpan(
                    source: parent.source,
                    startScalar: start,
                    endScalar: end,
                    text: text
                )
            else { return }
            parent.onSelectionChanged(span)
        }
    }
}

extension SmsReviewField {
    fileprivate var color: UIColor {
        switch self {
        case .amount: UIColor.systemOrange
        case .direction: UIColor.systemBlue
        case .account: UIColor.systemGreen
        case .counterparty: UIColor.systemPurple
        }
    }
}
