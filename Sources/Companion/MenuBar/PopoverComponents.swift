import SwiftUI
import CompanionCore

/// a card: stock liquid glass, or a solid window-background card with reduce transparency. never put another
/// glass element inside one (glass on glass turns muddy); use plain controls inside.
struct GlassSection<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let inner = VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        if reduceTransparency {
            inner
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay {
                    shape.strokeBorder(tint ?? Color(nsColor: .separatorColor),
                                       lineWidth: contrast == .increased ? 1.5 : 1)
                }
        } else {
            inner
                .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.35)) } ?? .regular, in: shape)
                .overlay {
                    if contrast == .increased { shape.strokeBorder(Color.primary.opacity(0.35), lineWidth: 1) }
                }
        }
    }
}

/// the one card title: small, semibold, secondary. every card starts with one (or with a row that acts as one).
struct CardTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Palette.secondaryText)
            .lineLimit(1)
            .capCentered(style: .caption1, weight: .semibold)
    }
}

struct StatusPill: View {
    let text: String
    let live: Bool

    var body: some View {
        HStack(alignment: .capCenter, spacing: 5) {
            if live {
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
                    .alignmentGuide(.capCenter) { $0[VerticalAlignment.center] }
            }
            Text(text).capCentered(style: .caption1, weight: .medium)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Palette.secondaryText)
    }
}

struct StatRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Palette.secondaryText)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.callout)
        .popoverRow()
    }
}

struct ReviewLastGameRow: View {
    let model: AppModel

    var body: some View {
        if let hint = model.reviewHint {
            Button {
                model.reopenReview?()
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Review last game").font(.callout.weight(.medium))
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Review last game, \(hint)")
        }
    }
}
