import AppKit
import SwiftUI

struct OnboardingHeroBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 54, height: 54)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: tint.opacity(0.35), radius: 10, x: 0, y: 5)
    }
}

struct OnboardingIconChip: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: 34, height: 34)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            )
    }
}

struct OnboardingCard<Content: View>: View {
    var highlighted = false
    var accent = Color.accentColor
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(highlighted ? accent.opacity(0.10) : Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(highlighted ? accent.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

struct OnboardingStepDots: View {
    let total: Int
    let index: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(total, 1), id: \.self) { position in
                Capsule()
                    .fill(position == index ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: position == index ? 18 : 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.22), value: index)
    }
}

struct OnboardingStatTile: View {
    let value: String
    let caption: String
    var onDark = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(onDark ? Color.white : Color.primary)
            Text(caption.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(onDark ? Color.white.opacity(0.75) : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OnboardingSavingsCard<Footer: View>: View {
    let amount: String
    let unit: String
    let caption: String
    let progress: Double?
    var muted = false
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(amount)
                    .font(.system(size: 50, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: amount)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .opacity(0.85)
                }
            }
            .foregroundStyle(foreground)
            Text(caption)
                .font(.callout)
                .foregroundStyle(muted ? Color.secondary : Color.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
            if let progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.28))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(5, geometry.size.width * min(max(progress, 0), 1)))
                            .animation(.easeOut(duration: 0.3), value: progress)
                    }
                }
                .frame(height: 6)
            }
            footer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .shadow(color: muted ? .clear : Color.green.opacity(0.22), radius: 12, x: 0, y: 6)
    }

    private var foreground: Color {
        muted ? .primary : .white
    }

    @ViewBuilder
    private var background: some View {
        if muted {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.green, Color.teal],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }
}

struct OnboardingSummaryRow: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
