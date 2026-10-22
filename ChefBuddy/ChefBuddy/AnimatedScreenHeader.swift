import SwiftUI

struct AnimatedScreenHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    var badgeText: String? = nil

    @State private var animateOrb = false
    @State private var animateContent = false
    @State private var iconIndex = 0
    @State private var iconTimer: Timer?

    private var rotatingIcons: [String] {
        switch systemImage {
        case "calendar":
            return ["calendar", "calendar.badge.clock", "list.bullet.rectangle", "sparkles"]
        case "basket.fill":
            return ["basket.fill", "carrot.fill", "refrigerator.fill", "leaf.fill"]
        case "book.closed.fill":
            return ["book.closed.fill", "fork.knife", "sparkles", "menucard.fill"]
        case "house.fill":
            return ["house.fill", "fork.knife.circle.fill", "sun.max.fill", "sparkles"]
        default:
            return [systemImage]
        }
    }

    private var activeIcon: String {
        let icons = rotatingIcons
        guard icons.isEmpty == false else { return systemImage }
        return icons[iconIndex % icons.count]
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(animateOrb ? 0.20 : 0.10))
                    .frame(width: 72, height: 72)
                    .blur(radius: animateOrb ? 4 : 0)
                    .offset(x: animateOrb ? 3 : -3, y: animateOrb ? -4 : 4)

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.24), .green.opacity(0.12), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 60, height: 60)

                Image(systemName: activeIcon)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(accent)
                    .offset(y: animateOrb ? -1 : 1)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: activeIcon)
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .offset(y: animateContent ? 0 : 6)
            .opacity(animateContent ? 1 : 0.72)

            Spacer(minLength: 8)

            if let badgeText, !badgeText.isEmpty {
                Text(badgeText)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(accent.opacity(0.14), in: Capsule())
                    .opacity(animateContent ? 1 : 0)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                animateOrb = true
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.84).delay(0.05)) {
                animateContent = true
            }
            if rotatingIcons.count > 1, iconTimer == nil {
                iconTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { _ in
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        iconIndex = (iconIndex + 1) % rotatingIcons.count
                    }
                }
            }
        }
        .onDisappear {
            iconTimer?.invalidate()
            iconTimer = nil
        }
    }
}
