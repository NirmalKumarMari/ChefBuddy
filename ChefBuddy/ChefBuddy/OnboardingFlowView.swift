import SwiftUI

private struct OnboardingStory {
    let eyebrow: String
    let title: String
    let subtitle: String
    let icon: String
    let supportingIcons: [String]
    let accent: Color
    let secondary: Color
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case pantry
    case create
    case plan
    case liveCooking
    case account
}

struct OnboardingFlowView: View {
    @EnvironmentObject private var authVM: AuthViewModel
    @State private var step: OnboardingStep = .welcome
    @State private var showAuthSheet = false
    @State private var animateScene = false

    private let stories: [OnboardingStory] = [
        OnboardingStory(
            eyebrow: "WELCOME TO CHEFBUDDY",
            title: "Your kitchen can work as one.",
            subtitle: "Everything you need to plan, shop, and cook in one personal kitchen.",
            icon: "sparkles",
            supportingIcons: ["basket.fill", "book.pages.fill", "calendar"],
            accent: .orange,
            secondary: Color(red: 0.42, green: 0.16, blue: 0.50)
        ),
        OnboardingStory(
            eyebrow: "KNOW WHAT YOU HAVE",
            title: "A pantry with a memory.",
            subtitle: "Scan shelves, separate kitchen spaces, and let pantry stock shape every recommendation.",
            icon: "basket.fill",
            supportingIcons: ["camera.viewfinder", "refrigerator.fill", "arrow.left.and.right"],
            accent: .green,
            secondary: Color(red: 0.05, green: 0.30, blue: 0.25)
        ),
        OnboardingStory(
            eyebrow: "MAKE THE IDEA REAL",
            title: "Start with a craving, not a form.",
            subtitle: "Describe your mood, time, ingredients, or nutrition needs. ChefBuddy creates the recipe around you.",
            icon: "wand.and.stars",
            supportingIcons: ["text.bubble.fill", "fork.knife", "photo.stack.fill"],
            accent: .purple,
            secondary: Color(red: 0.36, green: 0.12, blue: 0.48)
        ),
        OnboardingStory(
            eyebrow: "PLAN AROUND REAL LIFE",
            title: "Meals that fit your week.",
            subtitle: "Build days around your preferences, schedule, pantry, calories, protein, sodium, and body goals.",
            icon: "calendar.badge.checkmark",
            supportingIcons: ["cart.fill", "chart.bar.fill", "fork.knife"],
            accent: .blue,
            secondary: Color(red: 0.07, green: 0.22, blue: 0.48)
        ),
        OnboardingStory(
            eyebrow: "LIVE COOKING HELP",
            title: "A calm voice at the counter.",
            subtitle: "Cook a saved recipe or show what you have. Ask questions by voice, text, or camera while you cook.",
            icon: "waveform.and.mic",
            supportingIcons: ["video.fill", "camera.viewfinder", "text.bubble.fill"],
            accent: .purple,
            secondary: Color(red: 0.18, green: 0.10, blue: 0.42)
        ),
        OnboardingStory(
            eyebrow: "YOUR KITCHEN, YOUR WAY",
            title: "Ready when you are.",
            subtitle: "Create an account to keep your pantry, cookbook, plans, cooking photos, preferences, and progress together.",
            icon: "person.crop.circle.badge.checkmark",
            supportingIcons: ["lock.shield.fill", "icloud.fill", "heart.fill"],
            accent: .orange,
            secondary: Color(red: 0.46, green: 0.12, blue: 0.20)
        )
    ]

    private var story: OnboardingStory {
        stories[step.rawValue]
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [story.secondary, .black, story.accent.opacity(0.34)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(story.accent.opacity(0.30))
                .frame(width: 360, height: 360)
                .blur(radius: 70)
                .offset(x: animateScene ? 150 : 80, y: animateScene ? -310 : -250)
                .animation(.easeInOut(duration: 5).repeatForever(autoreverses: true), value: animateScene)

            Image(systemName: "fork.knife")
                .font(.system(size: 220, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.035))
                .rotationEffect(.degrees(animateScene ? 12 : -8))
                .offset(x: -150, y: 250)

            Image(systemName: "leaf.fill")
                .font(.system(size: 130, weight: .ultraLight))
                .foregroundStyle(story.accent.opacity(0.055))
                .offset(x: animateScene ? 170 : 120, y: 130)

            VStack(spacing: 0) {
                topBar

                TabView(selection: $step) {
                    ForEach(Array(stories.enumerated()), id: \.offset) { index, item in
                        storyPage(item, isWelcome: index == 0, isAccount: index == stories.count - 1)
                            .tag(OnboardingStep(rawValue: index)!)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomDock
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            animateScene = true
        }
        .sheet(isPresented: $showAuthSheet) {
            AuthView(onAuthSuccess: {
                UserDefaults.standard.set(true, forKey: "hasOnboarded")
                showAuthSheet = false
            })
            .presentationDetents([.fraction(0.88), .large])
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text("CHEFBUDDY")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .tracking(1.5)
            Spacer()
            Text("\(step.rawValue + 1) / \(stories.count)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func storyPage(_ item: OnboardingStory, isWelcome: Bool, isAccount: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 16)

            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                ZStack {
                Circle()
                    .stroke(item.accent.opacity(0.25), lineWidth: 1)
                    .frame(width: 256, height: 256)
                    .scaleEffect(animateScene ? 1.06 : 0.94)

                RoundedRectangle(cornerRadius: 42, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 172, height: 172)
                    .overlay {
                        if isWelcome {
                            Image("ChefBuddyLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 142, height: 142)
                        } else {
                            Image(systemName: item.icon)
                                .font(.system(size: 64, weight: .bold))
                                .foregroundStyle(.white)
                                .symbolEffect(.breathe, options: .repeat(.continuous))
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 42).stroke(Color.white.opacity(0.20), lineWidth: 1))
                    .shadow(color: item.accent.opacity(0.32), radius: 32, y: 18)

                    ForEach(Array(item.supportingIcons.enumerated()), id: \.offset) { index, icon in
                        let angle = (phase * 0.24) + (Double(index) * (.pi * 2 / Double(item.supportingIcons.count)))
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(item.accent)
                            .frame(width: 48, height: 48)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
                            .offset(x: cos(angle) * 132, y: sin(angle) * 132)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 32)

            Text(item.eyebrow)
                .font(.system(size: 11, weight: .black, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(item.accent)

            Text(item.title)
                .font(.system(size: 39, weight: .heavy, design: .rounded))
                .lineSpacing(-3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)

            Text(item.subtitle)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            if isAccount {
                HStack(spacing: 15) {
                    Label("Private", systemImage: "lock.fill")
                    Label("Personal", systemImage: "slider.horizontal.3")
                    Label("In sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.70))
                .padding(.top, 20)
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
    }

    private var bottomDock: some View {
        HStack(spacing: 14) {
            Spacer()

            if step != .welcome {
                Button {
                    ChefBuddyHaptics.selection()
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        step = OnboardingStep(rawValue: step.rawValue - 1)!
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
            }

            Button {
                ChefBuddyHaptics.medium()
                if step == .account {
                    showAuthSheet = true
                } else {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        step = OnboardingStep(rawValue: step.rawValue + 1)!
                    }
                }
            } label: {
                Image(systemName: step == .account ? "person.crop.circle.fill" : "arrow.right")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}
