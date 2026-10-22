// ContentView.swift
// The root routing view. Reads AuthViewModel state and decides which screen to show:
// onboarding (not logged in), a loading spinner (fetching profile), preference setup
// (logged in but no profile yet), or the main HomeView (fully set up).
// Also presents the AI hallucination warning sheet on every cold launch so users
// understand the limits of AI-generated recipes before they start cooking.

import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var authVM = AuthViewModel()
    @StateObject private var notificationManager = NotificationManager.shared
    @StateObject private var deepLinkRouter = ChefBuddyDeepLinkRouter.shared
    @State private var showHallucinationWarning = true

    var body: some View {
        Group {
            if authVM.userSession != nil {

                // Show a spinner while Firestore loads the profile. Skipping this state
                // would cause a brief flash of the setup screen for returning users.
                if authVM.isFetchingProfile {
                    KitchenLoadingView()
                // Profile is nil — user is logged in but hasn't completed setup yet.
                } else if authVM.currentUserProfile == nil {

                    InitialPreferencesView()
                        .environmentObject(authVM)
                        .environmentObject(notificationManager)
                } else if (authVM.currentUserProfile?.didCompleteNotificationOnboarding ?? false) == false {
                    NotificationPermissionView()
                        .environmentObject(authVM)
                        .environmentObject(notificationManager)
                } else {

                    MainTabShellView()
                        .environmentObject(authVM)
                        .environmentObject(notificationManager)
                }
            } else {

                OnboardingFlowView()
                    .environmentObject(authVM)
                    .environmentObject(notificationManager)
            }
        }
        .environmentObject(deepLinkRouter)

        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: authVM.userSession != nil)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: authVM.isFetchingProfile)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: authVM.currentUserProfile != nil)
        // Shown on every cold launch to remind users that AI recipes may contain
// errors. interactiveDismissDisabled prevents swiping it away without
// explicitly tapping "I Understand".
        .sheet(isPresented: $showHallucinationWarning) {
            AIWarningSheet(onDismiss: { showHallucinationWarning = false })
                .presentationDetents([.fraction(0.76)])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
        }
        .task(id: authVM.currentUserProfile?.id) {
            if let profile = authVM.currentUserProfile,
               let uid = authVM.userSession?.uid {
                await notificationManager.rescheduleNotificationsIfPossible(profile: profile, userId: uid)
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                notificationManager.clearBadgeCount()
            }
        }
    }
}

private struct KitchenLoadingView: View {
    @State private var orbit = false
    @State private var pulse = false

    private let orbitingIcons = ["basket.fill", "book.pages.fill", "calendar", "fork.knife"]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.20, green: 0.09, blue: 0.04), .black, Color(red: 0.03, green: 0.16, blue: 0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.orange.opacity(pulse ? 0.24 : 0.10))
                .frame(width: 340, height: 340)
                .blur(radius: 72)

            VStack(spacing: 30) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                        .frame(width: 248, height: 248)

                    ForEach(Array(orbitingIcons.enumerated()), id: \.offset) { index, icon in
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(index.isMultiple(of: 2) ? .orange : .green)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                            .offset(y: -124)
                            .rotationEffect(.degrees(-Double(index) * 90))
                    }
                    .rotationEffect(.degrees(orbit ? 360 : 0))

                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 152, height: 152)
                        .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))

                    Image("ChefBuddyLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 124, height: 124)
                        .offset(y: 4)
                        .scaleEffect(pulse ? 1.03 : 0.97)
                }

                VStack(spacing: 8) {
                    Text("SETTING THE TABLE")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.orange)

                    Text("Bringing your kitchen together")
                        .font(.system(size: 25, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)

                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(index == 1 ? Color.orange : Color.white.opacity(0.34))
                                .frame(width: 6, height: 6)
                                .scaleEffect(pulse && index == 1 ? 1.45 : 0.9)
                        }
                    }
                    .padding(.top, 7)
                }
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 36)
        }
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                orbit = true
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}


// The warning sheet itself. Uses a dark glassmorphism card with animated
// gradient glows. The dismiss button is disabled until the user ticks the
// acknowledgement checkbox, ensuring they actually read the warnings.
private struct AIWarningSheet: View {
    let onDismiss: () -> Void

    @State private var understood = false
    @State private var animateGlow = false

    var body: some View {
        ZStack(alignment: .bottom) {

            Color.black.opacity(0.35)
                .ignoresSafeArea()


            ZStack {
                Circle()
                    .fill(Color.orange.opacity(animateGlow ? 0.16 : 0.08))
                    .frame(width: 220, height: 220)
                    .blur(radius: 40)
                    .offset(x: -90, y: 40)

                Circle()
                    .fill(Color.green.opacity(animateGlow ? 0.14 : 0.06))
                    .frame(width: 180, height: 180)
                    .blur(radius: 35)
                    .offset(x: 110, y: 120)
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: animateGlow)

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 44, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 16)

                VStack(spacing: 18) {

                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .stroke(Color.orange.opacity(0.22), lineWidth: 9)
                                .frame(width: 82, height: 82)
                                .scaleEffect(animateGlow ? 1.08 : 0.94)
                                .opacity(animateGlow ? 0.34 : 0.82)

                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.orange.opacity(0.24),
                                            Color.green.opacity(0.18)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 68, height: 68)
                                .shadow(color: .orange.opacity(0.18), radius: 14, y: 6)

                            Image("ChefBuddyLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 52, height: 52)
                                .offset(y: 3)

                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.orange)
                                .background(Color.black.opacity(0.35), in: Circle())
                                .offset(x: 28, y: -26)
                        }
                        .animation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true), value: animateGlow)

                        VStack(spacing: 4) {
                            Text("AI-Generated Content")
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .multilineTextAlignment(.center)

                            Text("Double-check important details before cooking")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }


                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        CompactWarningRow(
                            icon: "brain.head.profile",
                            color: .orange,
                            title: "Verify recipe details"
                        )

                        CompactWarningRow(
                            icon: "allergens",
                            color: .red,
                            title: "Review allergens carefully"
                        )

                        CompactWarningRow(
                            icon: "flame.fill",
                            color: .orange,
                            title: "Confirm time and measurements"
                        )

                        CompactWarningRow(
                            icon: "cross.case.fill",
                            color: .green,
                            title: "Seek qualified medical guidance for health concerns"
                        )
                    }


                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            understood.toggle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(understood ? Color.green : Color.clear)
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(
                                                understood ? Color.green : Color.white.opacity(0.18),
                                                lineWidth: 1.5
                                            )
                                    )

                                if understood {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }

                            Text("I understand that I should verify important recipe details.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.92))
                                .multilineTextAlignment(.leading)

                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)


                    Button {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        onDismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 17, weight: .bold))

                            Text("I Understand")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            LinearGradient(
                                colors: understood
                                    ? [.orange, .green.opacity(0.9)]
                                    : [Color.white.opacity(0.12), Color.white.opacity(0.08)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(Capsule())
                        .shadow(
                            color: understood ? .orange.opacity(0.22) : .clear,
                            radius: 10,
                            y: 5
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!understood)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.14, green: 0.14, blue: 0.16),
                                Color(red: 0.10, green: 0.10, blue: 0.12)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .onAppear {
            animateGlow = true
        }
    }
}


// A single warning item — icon badge on the left, title text on the right.
// Reused four times in the warning sheet for consistent spacing and style.
private struct CompactWarningRow: View {
    let icon: String
    let color: Color
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(color.opacity(0.16))
                    .frame(width: 38, height: 38)

                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
            }

            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        )
    }
}

private struct WarningRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)
                .padding(.top, 1)

            Text(text)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


struct StandaloneAuthView: View {
    @EnvironmentObject var authVM: AuthViewModel
    var body: some View {
        AuthView(onAuthSuccess: {


        })
    }
}

struct MainAppPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("ChefBuddyLogo").resizable().scaledToFit().frame(width: 120, height: 120)
            Text("ChefBuddy").font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Home placeholder").foregroundStyle(.secondary)


            Button("Reset Onboarding") {
                UserDefaults.standard.set(false, forKey: "hasOnboarded")
            }.buttonStyle(.borderedProminent).tint(.orange).padding(.top, 20)
        }.padding()
    }
}
