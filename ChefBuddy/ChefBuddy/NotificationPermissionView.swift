import SwiftUI
import FirebaseAuth

struct NotificationPermissionView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @EnvironmentObject var notificationManager: NotificationManager
    @Environment(\.dismiss) private var dismiss

    let isPresentedFromSettings: Bool

    @State private var isAnimating = false
    @State private var isRequesting = false
    @State private var showDeniedMessage = false

    init(isPresentedFromSettings: Bool = false) {
        self.isPresentedFromSettings = isPresentedFromSettings
    }

    var body: some View {
        ZStack {
            ChefBuddyBackground()

            Circle()
                .fill(Color.orange.opacity(isAnimating ? 0.18 : 0.08))
                .blur(radius: 100)
                .offset(x: -150, y: -220)
                .ignoresSafeArea()

            Circle()
                .fill(Color.purple.opacity(isAnimating ? 0.16 : 0.07))
                .blur(radius: 110)
                .offset(x: 170, y: 260)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    header
                    previewCard
                    benefitCards
                    actionButtons
                }
                .padding(.horizontal, 24)
                .padding(.top, isPresentedFromSettings ? 18 : 40)
                .padding(.bottom, 28)
            }
        }
        .navigationBarBackButtonHidden(!isPresentedFromSettings)
        .toolbar {
            if isPresentedFromSettings {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.18), lineWidth: 1)
                    .frame(width: 154, height: 154)
                    .scaleEffect(isAnimating ? 1 : 0.86)
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 112, height: 112)
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.orange, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .symbolEffect(.wiggle, options: .repeat(2), value: isAnimating)
            }
            .padding(.top, 12)

            VStack(spacing: 8) {
                Text(isPresentedFromSettings ? "Kitchen Reminders" : "A timely tap, not more noise.")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)

                Text("Choose helpful moments for planning, using what you have, and starting dinner. You stay in control.")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("One useful moment")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("Never a stream of noise")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("PREVIEW")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
            }

            HStack(spacing: 14) {
                Image("ChefBuddyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .padding(4)
                    .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("CHEFBUDDY")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .tracking(0.8)
                        Spacer()
                        Text("now")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("Dinner is already half planned")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Your pantry has everything for tonight’s best match.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(15)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var benefitCards: some View {
        HStack(spacing: 10) {
            compactBenefit(icon: "slider.horizontal.3", title: "Your timing", color: .orange)
            compactBenefit(icon: "sparkles", title: "Useful only", color: .purple)
            compactBenefit(icon: "hand.raised.fill", title: "Your control", color: .blue)
        }
    }

    private func compactBenefit(icon: String, title: String, color: Color) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.12), in: Circle())
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: enableNotifications) {
                HStack(spacing: 10) {
                    if isRequesting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "bell.badge.fill")
                    }

                    Text(isPresentedFromSettings ? "Enable Daily Nudges" : "Enable Notifications")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(
                    LinearGradient(colors: [.orange, .purple.opacity(0.90)], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
                .shadow(color: .orange.opacity(0.24), radius: 12, y: 7)
            }
            .buttonStyle(.plain)
            .disabled(isRequesting)

            Button(action: skipNotifications) {
                Text(showDeniedMessage ? "Continue for now" : "Not now")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isRequesting)

            if showDeniedMessage {
                Text("Notifications are currently blocked for ChefBuddy. You can still continue now and turn them on later from Settings.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .padding(.top, 4)
    }

    private func enableNotifications() {
        guard let profile = authVM.currentUserProfile,
              let userId = authVM.userSession?.uid else { return }

        isRequesting = true

        Task {
            let granted = await notificationManager.requestNotifications(for: profile, userId: userId)
            let status = await MainActor.run { notificationManager.authorizationStatusString }

            await MainActor.run {
                showDeniedMessage = !granted
            }

            authVM.completeNotificationOnboarding(enabled: granted, authorizationStatus: status)

            await MainActor.run {
                isRequesting = false
                if isPresentedFromSettings {
                    dismiss()
                }
            }
        }
    }

    private func skipNotifications() {
        Task {
            await notificationManager.disableNotifications()
            let status = await MainActor.run { notificationManager.authorizationStatusString }
            authVM.completeNotificationOnboarding(enabled: false, authorizationStatus: status)

            await MainActor.run {
                if isPresentedFromSettings {
                    dismiss()
                }
            }
        }
    }
}

private struct NotificationPreviewRow: View {
    let time: String
    let title: String
    let message: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 5) {
                Circle()
                    .fill(accent.opacity(0.18))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: "bell.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(accent)
                    )

                Text(time)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))

                Text(message)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct NotificationBenefitCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(color.opacity(0.15))
                    .frame(width: 52, height: 52)

                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

extension NotificationManager {
    var authorizationStatusString: String {
        switch authorizationStatus {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }
}
