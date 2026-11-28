import Foundation
import SwiftUI
import UIKit

typealias SmsReviewField = SmsReviewFieldKind

extension SmsReviewFieldKind {
    var wireName: String { rawValue }

    var systemImage: String {
        switch self {
        case .amount: "banknote"
        case .direction: "arrow.left.arrow.right"
        case .account: "building.columns"
        case .counterparty: "storefront"
        }
    }

    var accentColor: Color {
        switch self {
        case .amount: .orange
        case .direction: .blue
        case .account: .green
        case .counterparty: .purple
        }
    }

    var accentUIColor: UIColor {
        switch self {
        case .amount: .systemOrange
        case .direction: .systemBlue
        case .account: .systemGreen
        case .counterparty: .systemPurple
        }
    }

    var highlightBackgroundColor: Color {
        accentColor.opacity(0.22)
    }
}

struct EvidenceSelectionTextView: UIViewRepresentable {
    let source: String
    let selections: [SmsReviewField: UnicodeScalarSpan]
    let pendingSelection: UnicodeScalarSpan?
    let onSelectionChanged: (UnicodeScalarSpan?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.isFindInteractionEnabled = false
        view.dataDetectorTypes = []
        view.backgroundColor = .secondarySystemGroupedBackground
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        view.textContainer.lineFragmentPadding = 0
        view.layer.cornerRadius = 12
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.separator.cgColor
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.accessibilityLabel = "SMS evidence. Select source text, then tap the field it belongs to."
        view.accessibilityIdentifier = "review-source-evidence"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.layer.borderColor = UIColor.separator.cgColor

        let currentSizeCategory = view.traitCollection.preferredContentSizeCategory
        let needsAttributedUpdate =
            context.coordinator.lastSource != source
            || context.coordinator.lastSelections != selections
            || context.coordinator.lastSizeCategory != currentSizeCategory

        if needsAttributedUpdate {
            context.coordinator.updating = true
            let previousRange = view.selectedRange
            view.attributedText = buildAttributedSource()
            if pendingSelection != nil,
                previousRange.location + previousRange.length <= (source as NSString).length
            {
                view.selectedRange = previousRange
            } else {
                view.selectedRange = NSRange(location: 0, length: 0)
            }
            context.coordinator.updating = false
            context.coordinator.lastSource = source
            context.coordinator.lastSelections = selections
            context.coordinator.lastSizeCategory = currentSizeCategory
        }

        if pendingSelection == nil {
            if context.coordinator.lastReportedSpan != nil || view.selectedRange.length > 0 {
                context.coordinator.updating = true
                view.selectedRange = NSRange(location: 0, length: 0)
                if view.isFirstResponder {
                    view.resignFirstResponder()
                }
                context.coordinator.updating = false
                context.coordinator.lastReportedSpan = nil
            }
        } else if let pendingSelection,
            pendingSelection != context.coordinator.lastReportedSpan,
            let range = try? pendingSelection.nsRange(in: source)
        {
            context.coordinator.updating = true
            view.selectedRange = range
            context.coordinator.updating = false
            context.coordinator.lastReportedSpan = pendingSelection
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context _: Context
    ) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(84, ceil(fitted.height)))
    }

    private func buildAttributedSource() -> NSAttributedString {
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let semiboldDescriptor = bodyFont.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
        ])
        let highlightFont = UIFont(descriptor: semiboldDescriptor, size: bodyFont.pointSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4

        let value = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: bodyFont,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraphStyle,
            ]
        )

        for field in SmsReviewField.allCases {
            guard let span = selections[field],
                let range = try? span.nsRange(in: source)
            else { continue }
            value.addAttributes(
                [
                    .backgroundColor: field.accentUIColor.withAlphaComponent(0.28),
                    .underlineColor: field.accentUIColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .font: highlightFont,
                ],
                range: range
            )
        }
        return value
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EvidenceSelectionTextView
        var updating = false
        var lastSource: String?
        var lastSelections: [SmsReviewField: UnicodeScalarSpan] = [:]
        var lastSizeCategory: UIContentSizeCategory?
        var lastReportedSpan: UnicodeScalarSpan?

        init(parent: EvidenceSelectionTextView) { self.parent = parent }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating else { return }
            guard textView.selectedRange.length > 0 else {
                if lastReportedSpan != nil || parent.pendingSelection != nil {
                    lastReportedSpan = nil
                    parent.onSelectionChanged(nil)
                }
                return
            }
            guard let rawSpan = UnicodeScalarSpan(source: parent.source, nsRange: textView.selectedRange) else {
                return
            }
            let scalars = parent.source.unicodeScalars
            guard
                var scalarStart = scalars.index(
                    scalars.startIndex,
                    offsetBy: rawSpan.startScalar,
                    limitedBy: scalars.endIndex
                ),
                var scalarEnd = scalars.index(
                    scalars.startIndex,
                    offsetBy: rawSpan.endScalar,
                    limitedBy: scalars.endIndex
                )
            else { return }

            while scalarStart < scalarEnd && scalars[scalarStart].properties.isWhitespace {
                scalarStart = scalars.index(after: scalarStart)
            }
            while scalarEnd > scalarStart {
                let beforeEnd = scalars.index(before: scalarEnd)
                if scalars[beforeEnd].properties.isWhitespace {
                    scalarEnd = beforeEnd
                } else {
                    break
                }
            }
            guard scalarStart < scalarEnd else {
                if lastReportedSpan != nil || parent.pendingSelection != nil {
                    lastReportedSpan = nil
                    parent.onSelectionChanged(nil)
                }
                return
            }
            let start = scalars.distance(from: scalars.startIndex, to: scalarStart)
            let end = scalars.distance(from: scalars.startIndex, to: scalarEnd)
            let text = String(scalars[scalarStart..<scalarEnd])
            guard
                let span = try? UnicodeScalarSpan(
                    source: parent.source,
                    startScalar: start,
                    endScalar: end,
                    text: text
                )
            else { return }
            guard span != lastReportedSpan else { return }
            lastReportedSpan = span
            parent.onSelectionChanged(span)
        }
    }
}
