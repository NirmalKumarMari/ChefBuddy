// ProfileSettingsView.swift
// Lets users view and update all their cooking preferences after onboarding.
// Changes are written back to Firestore via AuthViewModel so the AI assistant
// immediately picks them up on the next model setup call.

import SwiftUI
import FirebaseFirestore
import Combine
import FirebaseAuth


class ProfileFormState: ObservableObject {
    @Published var chefLevel: String = "🍳 Beginner"
    @Published var dietTags: Set<String> = []
    @Published var allergies: Set<String> = []
    @Published var macroTags: Set<String> = []


    @Published var age: Double = 25.0
    @Published var heightInches: Double = 67.0
    @Published var weight: Double = 150.0
    @Published var sex: String = "Male"

    @Published var targetGoal: String = "⚖️ Maintain"
    @Published var activityLevel: String = "🛋️ Sedentary"

    @Published var appliances: Set<String> = []
    @Published var cookTime: String = "⏱️ 15-30 mins"

    @Published var cuisines: Set<String> = []
    @Published var customCuisineInput: String = ""

    @Published var spiceTolerance: String = "🌶️ Medium"


    @Published var dislikesList: Set<String> = []
    @Published var customDislikeInput: String = ""


    @Published var customAllergyInput: String = ""
    @Published var customApplianceInput: String = ""

    @Published var servingSize: String = "👤 1 Person"
    @Published var budget: String = "💵 $$ (Standard)"
    @Published var measurementSystem: String = "🇺🇸 US cups & ounces"
    @Published var goalPace: String = "🌱 Steady"
    @Published var cookingFrequency: String = "📅 3–4 days/week"
    @Published var cleanupPreference: String = "🧽 Balanced cleanup"
    @Published var leftoverPreference: String = "🥡 Enjoy leftovers"
    @Published var aiCoachingStyle: String = "🎯 Direct & practical"
    @Published var aiCreativity: String = "✨ Balanced"
    @Published var dailyCalorieTarget: Double = 0
    @Published var notificationPreferences: [NotificationSlotPreference] = NotificationSlotPreference.defaults

    var resolvedDailyCalorieTarget: Int {
        Int(dailyCalorieTarget.rounded())
    }

    var changeFingerprint: String {
        [
            chefLevel,
            dietTags.sorted().joined(separator: "|"),
            allergies.sorted().joined(separator: "|"),
            macroTags.sorted().joined(separator: "|"),
            "\(Int(age))", "\(Int(heightInches))", "\(Int(weight))", sex,
            targetGoal, activityLevel,
            appliances.sorted().joined(separator: "|"),
            cookTime,
            cuisines.sorted().joined(separator: "|"),
            spiceTolerance,
            dislikesList.sorted().joined(separator: "|"),
            servingSize,
            budget,
            measurementSystem,
            goalPace,
            cookingFrequency,
            cleanupPreference,
            leftoverPreference,
            aiCoachingStyle,
            aiCreativity,
            "\(resolvedDailyCalorieTarget)",
            notificationPreferences.map { "\($0.slotId)-\($0.hour)-\($0.minute)-\($0.isEnabled)" }.joined(separator: "|")
        ].joined(separator: "•")
    }

    func load(from profile: DBUser?) {
        guard let profile = profile else { return }
        chefLevel = profile.chefLevel
        dietTags = Set(profile.dietTags)
        allergies = Set(profile.allergies)
        macroTags = Set(profile.macroTags)

        age = Double(profile.age) ?? 25.0
        heightInches = Double(profile.height) ?? 67.0
        weight = Double(profile.weight) ?? 150.0
        sex = profile.sex.isEmpty ? "Male" : profile.sex
        targetGoal = profile.targetGoal.isEmpty ? "⚖️ Maintain" : profile.targetGoal
        activityLevel = profile.activityLevel.isEmpty ? "🛋️ Sedentary" : profile.activityLevel

        appliances = Set(profile.appliances)
        cookTime = profile.cookTime.isEmpty ? "⏱️ 15-30 mins" : profile.cookTime

        cuisines = Set(profile.cuisines)
        spiceTolerance = profile.spiceTolerance.isEmpty ? "🌶️ Medium" : profile.spiceTolerance


        dislikesList = Set(
            profile.dislikes
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )

        servingSize = profile.servingSize.isEmpty ? "👤 1 Person" : profile.servingSize
        budget = profile.budget.isEmpty ? "💵 $$ (Standard)" : profile.budget
        measurementSystem = profile.measurementSystem ?? "🇺🇸 US cups & ounces"
        persistChefBuddyMeasurementSystem(measurementSystem)
        UserDefaults.standard.set(chefLevel, forKey: "chefBuddy.chefLevel")
        UserDefaults.standard.set(
            appliances.contains(where: { $0.localizedCaseInsensitiveContains("measuring cups") }),
            forKey: "chefBuddy.hasMeasuringTools"
        )
        goalPace = profile.goalPace ?? "🌱 Steady"
        cookingFrequency = profile.cookingFrequency ?? "📅 3–4 days/week"
        cleanupPreference = profile.cleanupPreference ?? "🧽 Balanced cleanup"
        leftoverPreference = profile.leftoverPreference ?? "🥡 Enjoy leftovers"
        aiCoachingStyle = profile.aiCoachingStyle ?? "🎯 Direct & practical"
        aiCreativity = profile.aiCreativity ?? "✨ Balanced"
        dailyCalorieTarget = Double(profile.dailyCalorieTarget ?? 2000)
        notificationPreferences = profile.notificationPreferences?.isEmpty == false
            ? profile.notificationPreferences!
            : NotificationSlotPreference.defaults
    }
}

private enum SettingsPanel: String, CaseIterable, Identifiable {
    case preferences = "Preferences"
    case logOut = "Log Out"
    var id: String { rawValue }
}

private enum ProfilePreferenceCategory: String, CaseIterable, Identifiable {
    case basics = "Basics"
    case bodyGoals = "Body & Goals"
    case kitchen = "Kitchen"
    case taste = "Taste"
    case notifications = "Notifications"
    case chefBuddyAI = "ChefBuddy AI"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .basics: return "person.text.rectangle"
        case .bodyGoals: return "figure.walk"
        case .kitchen: return "oven.fill"
        case .taste: return "fork.knife"
        case .notifications: return "bell.badge.fill"
        case .chefBuddyAI: return "sparkles"
        }
    }
}


struct InitialPreferencesView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @StateObject private var formState = ProfileFormState()
    @State private var isSaving = false
    @State private var journeyPage = 0
    @State private var animateAura = false
    @State private var completedTopic: ProfilePreferenceCategory?

    private let journeyTopics: [ProfilePreferenceCategory] = [
        .basics,
        .bodyGoals,
        .kitchen,
        .taste
    ]

    var displayName: String {
        if let name = authVM.userSession?.displayName, !name.isEmpty {
            return String(name.split(separator: " ").first ?? "")
        } else if let email = authVM.userSession?.email {
            return String(email.split(separator: "@").first ?? "Chef")
        }
        return "Chef"
    }

    var body: some View {
        ZStack {
            ProfileBackground()

            Circle()
                .fill(currentTint.opacity(animateAura ? 0.18 : 0.08))
                .frame(width: 320, height: 320)
                .blur(radius: 78)
                .offset(x: 145, y: -330)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: animateAura)

            if let completedTopic {
                preferenceCompletionMoment(for: completedTopic)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    journeyHeader

                    Group {
                        if journeyPage == 0 {
                            journeyWelcome
                        } else {
                            PreferencesFormContent(
                                formState: formState,
                                title: "",
                                subtitle: "",
                                selectedCategory: journeyTopics[journeyPage - 1]
                            )
                            .id(journeyPage)
                            .transition(.asymmetric(
                                insertion: .modifier(
                                    active: BookPageTurnModifier(angle: -88),
                                    identity: BookPageTurnModifier(angle: 0)
                                ).combined(with: .opacity),
                                removal: .modifier(
                                    active: BookPageTurnModifier(angle: 88),
                                    identity: BookPageTurnModifier(angle: 0)
                                ).combined(with: .opacity)
                            ))
                        }
                    }
                    .rotation3DEffect(
                        .degrees(completedTopic == nil ? 0 : -7),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: .leading,
                        perspective: 0.42
                    )

                    journeyDock
                }
            }
        }
        .onAppear {
            animateAura = true
        }
    }

    private var currentTint: Color {
        switch journeyPage {
        case 1: return .orange
        case 2: return .green
        case 3: return .blue
        case 4: return .pink
        default: return .orange
        }
    }

    private var currentTitle: String {
        switch journeyPage {
        case 1: return "Your cooking identity"
        case 2: return "Your goals and rhythm"
        case 3: return "Meet your kitchen"
        case 4: return "The flavors you love"
        default: return "Let’s make ChefBuddy yours"
        }
    }

    private var currentSubtitle: String {
        switch journeyPage {
        case 1: return "The essentials every recipe should respect."
        case 2: return "Nutrition targets built around your body and routine."
        case 3: return "Tools and timing that make suggestions practical."
        case 4: return "Flavors, servings, and budget that feel like home."
        default: return "Four quick pages create your personal cooking profile."
        }
    }

    private var journeyHeader: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PERSONAL SETUP")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(currentTint)
                    Text(journeyPage == 0 ? "Welcome, \(displayName)" : "Topic \(journeyPage) of \(journeyTopics.count)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                }

                Spacer()

                Text("\(Int((Double(journeyPage) / Double(journeyTopics.count)) * 100))%")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(currentTint)
            }

            HStack(spacing: 7) {
                ForEach(0...journeyTopics.count, id: \.self) { index in
                    Capsule()
                        .fill(index <= journeyPage ? currentTint : Color.primary.opacity(0.10))
                        .frame(maxWidth: .infinity)
                        .frame(height: 6)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(currentTitle)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text(currentSubtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var journeyWelcome: some View {
        VStack(spacing: 18) {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 250, height: 250)
                        .blur(radius: 24)
                    Circle()
                        .stroke(Color.orange.opacity(0.28), lineWidth: 1)
                        .frame(width: 218, height: 218)
                    ForEach(Array(["fork.knife", "scope", "oven.fill"].enumerated()), id: \.offset) { index, icon in
                        let angle = phase * 0.24 + Double(index) * (.pi * 2 / 3)
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.orange)
                            .frame(width: 46, height: 46)
                            .background(.ultraThinMaterial, in: Circle())
                            .offset(x: cos(angle) * 110, y: sin(angle) * 110)
                    }
                    Image("ChefBuddyLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 150, height: 150)
                        .scaleEffect(animateAura ? 1.03 : 0.97)
                }
            }

            VStack(spacing: 10) {
                journeyPromise(icon: "fork.knife", title: "Taste", detail: "Recipes that respect the foods, cuisines, and dietary choices you enjoy.")
                journeyPromise(icon: "scope", title: "Goals", detail: "Meal plans shaped around calories, protein, sodium, schedule, and body goals.")
                journeyPromise(icon: "oven.fill", title: "Kitchen", detail: "Guidance that fits your experience, time, tools, and measuring equipment.")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private func journeyPromise(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: 50, height: 50)
                .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var journeyDock: some View {
        HStack(spacing: 12) {
            Spacer()

            if journeyPage > 0 {
                Button {
                    ChefBuddyHaptics.selection()
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        journeyPage -= 1
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)
            }

            Button {
                if journeyPage == journeyTopics.count {
                    finishSetup()
                } else if journeyPage == 0 {
                    ChefBuddyHaptics.success()
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                        journeyPage = 1
                    }
                } else {
                    ChefBuddyHaptics.success()
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                        completedTopic = journeyTopics[journeyPage - 1]
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                            completedTopic = nil
                            journeyPage += 1
                        }
                    }
                }
            } label: {
                Group {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: journeyPage == journeyTopics.count ? "checkmark" : "arrow.right")
                    }
                }
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(currentTint)
                .frame(width: 58, height: 58)
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
    }

    private func preferenceCompletionMoment(for topic: ProfilePreferenceCategory) -> some View {
        let presentation = completionPresentation(for: topic)

        return ZStack {
            LinearGradient(
                colors: [presentation.tint.opacity(0.52), .black, presentation.tint.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Image(systemName: presentation.symbol)
                .font(.system(size: 260, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.045))
                .rotationEffect(.degrees(animateAura ? 8 : -8))

            VStack(spacing: 22) {
                Spacer()

                ZStack {
                    Circle()
                        .stroke(presentation.tint.opacity(0.34), lineWidth: 1)
                        .frame(width: 230, height: 230)
                        .scaleEffect(animateAura ? 1.08 : 0.94)
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 166, height: 166)
                    Image(systemName: presentation.symbol)
                        .font(.system(size: 58, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.breathe, options: .repeat(.continuous))
                }

                Text(topic.rawValue.uppercased())
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(presentation.tint)

                Text(presentation.title)
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(presentation.detail)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.70))
                    .multilineTextAlignment(.center)

                Spacer()

                HStack(spacing: 8) {
                    ProgressView()
                        .tint(presentation.tint)
                    Text("Preparing what comes next")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                }
                .padding(.bottom, 38)
            }
            .padding(.horizontal, 34)
        }
        .ignoresSafeArea()
    }

    private func completionPresentation(for topic: ProfilePreferenceCategory) -> (title: String, detail: String, symbol: String, tint: Color) {
        switch topic {
        case .basics:
            return ("ChefBuddy knows your foundation.", "Measurements, experience, and dietary needs now travel with every recipe.", "person.crop.circle.badge.checkmark", .orange)
        case .bodyGoals:
            return ("Your goals have a compass.", "Plans can now balance everyday cooking with the nutrition rhythm you chose.", "scope", .green)
        case .kitchen:
            return ("Your kitchen just got smarter.", "Available tools and real cooking time will shape more practical suggestions.", "oven.fill", .blue)
        case .taste:
            return ("Your flavor map is ready.", "ChefBuddy can now suggest meals that feel much closer to you.", "fork.knife", .pink)
        default:
            return ("Saved.", "Your ChefBuddy profile is becoming more personal.", "checkmark", .orange)
        }
    }

    private func finishSetup() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isSaving = true
        authVM.saveUserPreferences(
            level: formState.chefLevel,
            diets: formState.dietTags,
            allergy: formState.allergies,
            macros: formState.macroTags,
            age: String(format: "%.0f", formState.age),
            height: String(format: "%.0f", formState.heightInches),
            weight: String(format: "%.0f", formState.weight),
            sex: formState.sex,
            targetGoal: formState.targetGoal,
            activity: formState.activityLevel,
            appliances: formState.appliances,
            cookTime: formState.cookTime,
            mealPrep: false,
            cuisines: formState.cuisines,
            spice: formState.spiceTolerance,
            dislikes: formState.dislikesList.joined(separator: ", "),
            servings: formState.servingSize,
            budget: formState.budget,
            measurementSystem: formState.measurementSystem,
            dailyCalorieTarget: formState.resolvedDailyCalorieTarget
        )
        persistChefBuddyMeasurementSystem(formState.measurementSystem)
        UserDefaults.standard.set(formState.chefLevel, forKey: "chefBuddy.chefLevel")
        UserDefaults.standard.set(
            formState.appliances.contains(where: { $0.localizedCaseInsensitiveContains("measuring cups") }),
            forKey: "chefBuddy.hasMeasuringTools"
        )
    }
}

private struct BookPageTurnModifier: ViewModifier {
    let angle: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 0, y: 1, z: 0),
                anchor: angle < 0 ? .trailing : .leading,
                perspective: 0.46
            )
            .shadow(color: .black.opacity(abs(angle) / 260), radius: 22, x: angle < 0 ? -12 : 12)
    }
}


struct ProfileSettingsView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @EnvironmentObject var notificationManager: NotificationManager
    @Environment(\.dismiss) var dismiss
    var showsDismissButton = true
    var showsSignOutButton = false
    @StateObject private var formState = ProfileFormState()
    @State private var isSaving = false
    @State private var isResettingDiscovery = false
    @State private var selectedPanel: SettingsPanel = .preferences
    @State private var selectedCategory: ProfilePreferenceCategory = .basics
    @State private var initialFingerprint = ""
    @State private var saveSucceeded = false
    @State private var showLogOutConfirmation = false
    @State private var showDiscardConfirmation = false
    @State private var showAppTutorial = false

    private var hasUnsavedChanges: Bool {
        !initialFingerprint.isEmpty && formState.changeFingerprint != initialFingerprint
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ProfileBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your Kitchen Profile")
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                            Text("Tune the details ChefBuddy uses to plan, suggest, and personalize your meals.")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                        }

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)
                            ],
                            spacing: 12
                        ) {
                            ForEach(ProfilePreferenceCategory.allCases) { category in
                                NavigationLink(value: category) {
                                    preferenceDashboardCard(category)
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(TapGesture().onEnded {
                                    ChefBuddyHaptics.selection()
                                })
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Account")
                                .font(.system(size: 17, weight: .bold, design: .rounded))

                            HStack(spacing: 13) {
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .frame(width: 46, height: 46)
                                    .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(authVM.userSession?.email ?? "ChefBuddy account")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .lineLimit(1)
                                    Text("Recipes, meal plans, and pantry data stay saved.")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            Button {
                                ChefBuddyHaptics.medium()
                                showAppTutorial = true
                            } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(.purple)
                                        .frame(width: 46, height: 46)
                                        .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Replay ChefBuddy Tour")
                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                            .foregroundStyle(.primary)
                                        Text("Walk through Home, Pantry, Recipes, planning, Live Cooking, and your Journey.")
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    Spacer(minLength: 4)

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(13)
                                .background(
                                    LinearGradient(
                                        colors: [Color.purple.opacity(0.11), Color.blue.opacity(0.05)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)

                            Button {
                                showLogOutConfirmation = true
                            } label: {
                                Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, hasUnsavedChanges ? 100 : 28)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done", action: attemptDismiss)
                            .fontWeight(.semibold)
                    }
                }
            }
            .navigationDestination(for: ProfilePreferenceCategory.self) { category in
                ZStack {
                    ProfileBackground()
                    PreferencesFormContent(
                        formState: formState,
                        title: category.rawValue,
                        subtitle: subtitle(for: category),
                        selectedCategory: category,
                        isResettingDiscovery: isResettingDiscovery,
                        onResetDiscovery: resetDiscoveryPreferences
                    )
                }
                .navigationTitle(category.rawValue)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasUnsavedChanges {
                Button(action: saveChanges) {
                    HStack(spacing: 12) {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                                .frame(width: 38, height: 38)
                        } else {
                            Image(systemName: saveSucceeded ? "checkmark.circle.fill" : "checkmark.seal.fill")
                                .font(.system(size: 20, weight: .bold))
                                .frame(width: 38, height: 38)
                                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isSaving ? "Updating your kitchen…" : "Update Kitchen Profile")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                            Text("Apply these preferences across ChefBuddy")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(
                        AnyShapeStyle(LinearGradient(colors: [Color(red: 0.98, green: 0.48, blue: 0.20), Color(red: 0.54, green: 0.25, blue: 0.82)], startPoint: .leading, endPoint: .trailing)),
                        in: Capsule()
                    )
                    .shadow(color: .orange.opacity(0.20), radius: 12, y: 6)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
        .onAppear {
            formState.load(from: authVM.currentUserProfile)
            DispatchQueue.main.async {
                initialFingerprint = formState.changeFingerprint
            }
        }
        .onChange(of: formState.measurementSystem) { _, newValue in
            persistChefBuddyMeasurementSystem(newValue)
            NotificationCenter.default.post(name: .chefBuddyPreferencesDidChange, object: nil)
        }
        .sheet(isPresented: $showLogOutConfirmation) {
            LogoutConfirmationSheet(
                email: authVM.userSession?.email ?? "ChefBuddy account",
                onCancel: { showLogOutConfirmation = false },
                onConfirm: {
                    ChefBuddyHaptics.warning()
                    showLogOutConfirmation = false
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        authVM.signOut()
                    }
                }
            )
            .presentationDetents([.fraction(0.46)])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showAppTutorial) {
            ChefBuddyAppTutorialView {
                if let userId = authVM.userSession?.uid {
                    UserDefaults.standard.set(true, forKey: "chefbuddy.appTutorial.completed.\(userId)")
                }
                showAppTutorial = false
            }
        }
        .confirmationDialog("Save your changes?", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
            Button("Save and Close") {
                saveChanges()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    dismiss()
                }
            }
            Button("Discard Changes", role: .destructive) {
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You changed your kitchen profile. Choose whether to save those updates before closing.")
        }
    }

    private func preferenceDashboardCard(_ category: ProfilePreferenceCategory) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: category.icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(categoryTint(category).gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .shadow(color: categoryTint(category).opacity(0.22), radius: 10, y: 5)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(categoryTint(category))
                    .frame(width: 30, height: 30)
                    .background(categoryTint(category).opacity(0.10), in: Circle())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(category.rawValue)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary)
                Text(subtitle(for: category))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .padding(14)
        .background(
            LinearGradient(
                colors: [categoryTint(category).opacity(0.12), Color.primary.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(categoryTint(category).opacity(0.18), lineWidth: 1)
        )
    }

    private func categoryTint(_ category: ProfilePreferenceCategory) -> Color {
        switch category {
        case .basics: return .orange
        case .bodyGoals: return .green
        case .kitchen: return .blue
        case .taste: return .pink
        case .notifications: return .purple
        case .chefBuddyAI: return .indigo
        }
    }

    private func attemptDismiss() {
        if hasUnsavedChanges {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private var preferenceCategoryStrip: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
            ForEach(ProfilePreferenceCategory.allCases) { category in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        selectedCategory = category
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: category.icon)
                        Text(category.rawValue)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(selectedCategory == category ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(
                        selectedCategory == category ? Color.orange : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var categorySubtitle: String {
        subtitle(for: selectedCategory)
    }

    private func subtitle(for category: ProfilePreferenceCategory) -> String {
        switch category {
        case .basics: return "Cooking experience, dietary preferences, allergies, and macro priorities."
        case .bodyGoals: return "Body details, activity, goals, and ChefBuddy’s calorie planning target."
        case .kitchen: return "Your appliances and the amount of time you usually have to cook."
        case .taste: return "Favorite cuisines, spice, dislikes, household size, and budget."
        case .notifications: return "Choose which helpful ChefBuddy nudges you want and when they arrive."
        case .chefBuddyAI: return "Control and reset the taste signals used by recipe discovery."
        }
    }

    private var logOutPanel: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "person.crop.circle.badge.xmark")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 110, height: 110)
                    .background(Color.red.opacity(0.10), in: Circle())

                VStack(spacing: 7) {
                    Text("Account & Session")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                    Text(authVM.userSession?.email ?? "ChefBuddy account")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("Your saved recipes remain in your account", systemImage: "checkmark.circle.fill")
                    Label("Meal plans and pantry items stay synced", systemImage: "checkmark.circle.fill")
                    Label("You can sign back in at any time", systemImage: "checkmark.circle.fill")
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Button {
                    showLogOutConfirmation = true
                } label: {
                    Label("Log Out of ChefBuddy", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
    }

    private func saveChanges() {
        ChefBuddyHaptics.medium()
        isSaving = true
        authVM.updateUserPreferences(
            level: formState.chefLevel,
            diets: formState.dietTags,
            allergy: formState.allergies,
            macros: formState.macroTags,
            age: String(format: "%.0f", formState.age),
            height: String(format: "%.0f", formState.heightInches),
            weight: String(format: "%.0f", formState.weight),
            sex: formState.sex,
            targetGoal: formState.targetGoal,
            activity: formState.activityLevel,
            appliances: formState.appliances,
            cookTime: formState.cookTime,
            mealPrep: false,
            cuisines: formState.cuisines,
            spice: formState.spiceTolerance,
            dislikes: formState.dislikesList.joined(separator: ", "),
            servings: formState.servingSize,
            budget: formState.budget,
            dailyCalorieTarget: formState.resolvedDailyCalorieTarget,
            activePantryId: authVM.currentUserProfile?.activePantryId,
            measurementSystem: formState.measurementSystem,
            goalPace: formState.goalPace,
            cookingFrequency: formState.cookingFrequency,
            cleanupPreference: formState.cleanupPreference,
            leftoverPreference: formState.leftoverPreference,
            aiCoachingStyle: formState.aiCoachingStyle,
            aiCreativity: formState.aiCreativity
        )
        authVM.updateNotificationPreferences(
            enabled: formState.notificationPreferences.contains(where: \.isEnabled),
            authorizationStatus: notificationManager.authorizationStatusString,
            preferences: formState.notificationPreferences
        )
        UserDefaults.standard.set(formState.chefLevel, forKey: "chefBuddy.chefLevel")
        UserDefaults.standard.set(
            formState.appliances.contains(where: { $0.localizedCaseInsensitiveContains("measuring cups") }),
            forKey: "chefBuddy.hasMeasuringTools"
        )
        if let userId = authVM.userSession?.uid,
           var profile = authVM.currentUserProfile {
            profile.dailyCalorieTarget = formState.resolvedDailyCalorieTarget
            profile.cuisines = Array(formState.cuisines)
            profile.servingSize = formState.servingSize
            profile.notificationPreferences = formState.notificationPreferences
            profile.notificationsEnabled = formState.notificationPreferences.contains(where: \.isEnabled)

            Task {
                await notificationManager.updatePreferences(
                    profile: profile,
                    userId: userId,
                    preferences: formState.notificationPreferences,
                    isEnabled: formState.notificationPreferences.contains(where: \.isEnabled)
                )
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isSaving = false
            initialFingerprint = formState.changeFingerprint
            saveSucceeded = true
            ChefBuddyHaptics.success()
            NotificationCenter.default.post(name: .chefBuddyPreferencesDidChange, object: nil)
        }
    }

    private func resetDiscoveryPreferences() {
        guard let uid = authVM.userSession?.uid, !isResettingDiscovery else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isResettingDiscovery = true

        Task {
            do {
                let db = Firestore.firestore()

                while true {
                    let snapshot = try await db.collection("users")
                        .document(uid)
                        .collection("discoveryFeedback")
                        .limit(to: 200)
                        .getDocuments()

                    if snapshot.documents.isEmpty {
                        break
                    }

                    let batch = db.batch()
                    snapshot.documents.forEach { batch.deleteDocument($0.reference) }
                    try await batch.commit()
                }

                await MainActor.run {
                    isResettingDiscovery = false
                    NotificationCenter.default.post(name: Notification.Name("DiscoveryFeedbackDidReset"), object: nil)
                }
            } catch {
                await MainActor.run {
                    isResettingDiscovery = false
                    authVM.errorMessage = "Failed to reset AI discovery: \(error.localizedDescription)"
                }
            }
        }
    }
}


private struct PreferencesFormContent: View {
    @EnvironmentObject var notificationManager: NotificationManager
    @ObservedObject var formState: ProfileFormState
    let title: String
    let subtitle: String
    var selectedCategory: ProfilePreferenceCategory? = nil
    var isResettingDiscovery: Bool = false
    var onResetDiscovery: (() -> Void)? = nil

    @State private var activeSheet: ActiveSheet? = nil
    @State private var showSections: [Bool] = Array(repeating: false, count: 13)

    var bmi: Double {
        let h = formState.heightInches
        let w = formState.weight
        return h > 0 ? (w / (h * h)) * 703 : 0
    }

    var bmiCategory: String {
        if bmi < 18.5 { return "Underweight" }
        else if bmi < 25 { return "Normal" }
        else if bmi < 30 { return "Overweight" }
        else { return "Obese" }
    }

    var bmiColor: Color {
        if bmi < 18.5 { return .blue }
        else if bmi < 25 { return .green }
        else if bmi < 30 { return .orange }
        else { return .red }
    }


    var estimatedCalories: Int {
        let weightKg = formState.weight * 0.453592
        let heightCm = formState.heightInches * 2.54
        let age = max(formState.age, 10)

        let bmr: Double

        if formState.sex == "Male" {
            bmr = (10 * weightKg) + (6.25 * heightCm) - (5 * age) + 5
        } else {
            bmr = (10 * weightKg) + (6.25 * heightCm) - (5 * age) - 161
        }

        let activityMultiplier: Double

        switch formState.activityLevel {
        case "🛋️ Sedentary":
            activityMultiplier = 1.2
        case "🚶 Lightly Active":
            activityMultiplier = 1.375
        case "🏃 Active":
            activityMultiplier = 1.55
        case "🏋️ Athlete":
            activityMultiplier = 1.725
        default:
            activityMultiplier = 1.2
        }

        let maintenanceCalories = bmr * activityMultiplier
        var calories = maintenanceCalories

        switch formState.targetGoal {
        case "📉 Weight Loss":
            calories -= min(max(maintenanceCalories * 0.18, 275), 550)
        case "💪 Muscle Gain":
            calories += min(max(maintenanceCalories * 0.10, 175), 325)
        default:
            break
        }

        let clamped = max(1200, min(calories, 4500))
        return Int(clamped.rounded())
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {


                VStack(alignment: .leading, spacing: 16) {
                    if selectedCategory == nil {
                        HStack {
                            Spacer()
                            ProfileSequentialIconView()
                                .scaleEffect(0.6)
                                .frame(height: 100)
                            Spacer()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(title)
                                .font(.system(size: 34, weight: .heavy, design: .rounded))
                            Text(subtitle)
                                .font(.system(size: 17))
                                .foregroundStyle(.secondary)
                                .lineSpacing(4)
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.top, selectedCategory == nil ? 20 : 12)


                if selectedCategory == nil || selectedCategory == .basics {
                    AnimatedSection(isVisible: showSections[0]) {
                    VStack(alignment: .leading, spacing: 28) {
                        if selectedCategory == nil {
                            ProfileSectionHeader(title: "The Basics", icon: "person.text.rectangle")
                        }

                        ProfileSinglePreference(
                            title: "Experience Level",
                            options: levelsList,
                            selected: $formState.chefLevel
                        ) {
                            activeSheet = .level
                        }

                        ProfileSinglePreference(
                            title: "Recipe Measurements",
                            options: measurementSystemsList,
                            selected: $formState.measurementSystem
                        ) {
                            activeSheet = .measurements
                        }

                        ProfileMultiPreference(
                            title: "Dietary Preferences",
                            options: dietsList,
                            selected: $formState.dietTags
                        ) {
                            activeSheet = .diet
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            ProfileMultiPreference(
                                title: "Avoid (Allergies)",
                                options: allergiesList,
                                selected: $formState.allergies
                            ) {
                                activeSheet = .allergy
                            }

                            let customAllergies = formState.allergies.filter { !allergiesList.contains($0) }.sorted()
                            if !customAllergies.isEmpty {
                                RemovablePreferenceChips(items: customAllergies, tint: .red) { item in
                                    withAnimation {
                                        _ = formState.allergies.remove(item)
                                    }
                                }
                                .padding(.horizontal, 24)
                            }

                            HStack(spacing: 12) {
                                ProfileTextField(
                                    placeholder: "Add a custom allergy...",
                                    text: $formState.customAllergyInput
                                )

                                Button(action: {
                                    let input = formState.customAllergyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !input.isEmpty {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        let newItem = "🚫 " + input
                                        withAnimation {
                                            _ = formState.allergies.insert(newItem)
                                        }
                                        formState.customAllergyInput = ""
                                    }
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(formState.customAllergyInput.isEmpty ? Color.gray.opacity(0.3) : Color.red)
                                }
                            }
                            .padding(.horizontal, 24)
                        }

                        ProfileMultiPreference(
                            title: "Macro Goals",
                            options: macrosList,
                            selected: $formState.macroTags
                        ) {
                            activeSheet = .macro
                        }
                    }
                    }
                }


                if selectedCategory == nil || selectedCategory == .bodyGoals {
                    AnimatedSection(isVisible: showSections[1]) {
                    VStack(alignment: .leading, spacing: 28) {
                        if selectedCategory == nil {
                            ProfileSectionHeader(title: "Body & Goals", icon: "figure.walk")
                        }

                        ProfileSinglePreference(
                            title: "Sex",
                            options: sexList,
                            selected: $formState.sex
                        ) {
                            activeSheet = .sex
                        }

                        VStack(spacing: 32) {
                            MetricStepperCard(
                                title: "Age",
                                value: $formState.age,
                                range: 10...100,
                                step: 1,
                                suffix: "yrs"
                            ) {
                                activeSheet = .physical
                            }

                            HeightStepperCard(
                                title: "Height",
                                inches: $formState.heightInches
                            ) {
                                activeSheet = .physical
                            }

                            MetricStepperCard(
                                title: "Weight",
                                value: $formState.weight,
                                range: 50...400,
                                step: 1,
                                suffix: "lbs"
                            ) {
                                activeSheet = .physical
                            }


                            HStack {
                                Text("Calculated BMI")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f", bmi))
                                    .font(.system(size: 18, weight: .heavy, design: .monospaced))
                                Text(bmiCategory)
                                    .font(.system(size: 14, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(bmiColor.opacity(0.15))
                                    .foregroundStyle(bmiColor)
                                    .clipShape(Capsule())
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                            )

                        }
                        .padding(.horizontal, 24)

                        ProfileSinglePreference(
                            title: "Target Goal",
                            options: goalsList,
                            selected: $formState.targetGoal
                        ) {
                            activeSheet = .goal
                        }

                        ProfileSinglePreference(
                            title: "Goal Pace",
                            options: goalPacesList,
                            selected: $formState.goalPace
                        ) {
                            activeSheet = .goalPace
                        }

                        ProfileSinglePreference(
                            title: "Activity Level",
                            options: activityList,
                            selected: $formState.activityLevel
                        ) {
                            activeSheet = .activity
                        }


                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text("Recommended Daily Calories")
                                            .font(.system(size: 16, weight: .bold, design: .rounded))
                                            .foregroundStyle(.secondary)

                                        Button(action: {
                                            activeSheet = .calories
                                        }) {
                                            Image(systemName: "info.circle.fill")
                                                .foregroundStyle(Color.primary.opacity(0.4))
                                        }
                                    }

                                    Text("\(estimatedCalories) cal/day")
                                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                                        .foregroundStyle(.orange)
                                }

                                Spacer()

                                Image(systemName: "flame.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.orange)
                                    .padding(14)
                                    .background(Color.orange.opacity(0.12))
                                    .clipShape(Circle())
                            }

                            Text("This is a general recommendation based on your sex, age, height, weight, target goal, and activity level.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Your AI planning target")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(formState.resolvedDailyCalorieTarget) cal/day")
                                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                                        .foregroundStyle(.green)
                                }

                                HStack(spacing: 12) {
                                    Button(action: {
                                        formState.dailyCalorieTarget = max(1200, formState.dailyCalorieTarget - 50)
                                    }) {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 26))
                                            .foregroundStyle(.orange)
                                    }
                                    .buttonStyle(.plain)

                                    Slider(value: $formState.dailyCalorieTarget, in: 1200...4500, step: 25)
                                        .tint(.green)

                                    Button(action: {
                                        formState.dailyCalorieTarget = min(4500, formState.dailyCalorieTarget + 50)
                                    }) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 26))
                                            .foregroundStyle(.green)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Button("Use Recommended Calories") {
                                    formState.dailyCalorieTarget = Double(estimatedCalories)
                                }
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                            }
                            .padding(14)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .padding(.top, 2)

                                Text("App recommendation only — please check with a registered dietitian or healthcare professional for personalized nutrition advice.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(3)
                            }
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                        )
                        .padding(.horizontal, 24)
                    }
                    }
                }


                if selectedCategory == nil || selectedCategory == .kitchen {
                    AnimatedSection(isVisible: showSections[2]) {
                    VStack(alignment: .leading, spacing: 28) {
                        if selectedCategory == nil {
                            ProfileSectionHeader(title: "Kitchen & Time", icon: "timer")
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            ProfileMultiPreference(
                                title: "Appliances You Own",
                                options: appliancesList,
                                selected: $formState.appliances,
                                previewLimit: 6
                            ) {
                                activeSheet = .appliances
                            }

                            let customAppliances = formState.appliances.filter { !appliancesList.contains($0) }.sorted()
                            if !customAppliances.isEmpty {
                                RemovablePreferenceChips(
                                    items: customAppliances,
                                    tint: .green
                                ) { item in
                                    withAnimation {
                                        _ = formState.appliances.remove(item)
                                    }
                                }
                                .padding(.horizontal, 24)
                            }

                            HStack(spacing: 12) {
                                ProfileTextField(
                                    placeholder: "Add a custom appliance...",
                                    text: $formState.customApplianceInput
                                )

                                Button(action: {
                                    let input = formState.customApplianceInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !input.isEmpty {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        let newItem = "🔧 " + input
                                        withAnimation {
                                            _ = formState.appliances.insert(newItem)
                                        }
                                        formState.customApplianceInput = ""
                                    }
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(formState.customApplianceInput.isEmpty ? Color.gray.opacity(0.3) : Color.green)
                                }
                            }
                            .padding(.horizontal, 24)
                        }

                        ProfileSinglePreference(
                            title: "Typical Cook Time",
                            options: cookTimesList,
                            selected: $formState.cookTime
                        ) {
                            activeSheet = .cookTime
                        }

                        ProfileSinglePreference(
                            title: "How Often You Cook",
                            options: cookingFrequencyList,
                            selected: $formState.cookingFrequency
                        ) {
                            activeSheet = .cookingFrequency
                        }
                    }
                    }
                }


                if selectedCategory == nil || selectedCategory == .taste {
                    AnimatedSection(isVisible: showSections[3]) {
                    VStack(alignment: .leading, spacing: 28) {
                        if selectedCategory == nil {
                            ProfileSectionHeader(title: "Taste & Household", icon: "fork.knife")
                        }


                        VStack(alignment: .leading, spacing: 12) {
                            ProfileMultiPreference(
                                title: "Favorite Cuisines",
                                options: cuisinesList,
                                selected: $formState.cuisines,
                                previewLimit: 6
                            ) {
                                activeSheet = .cuisines
                            }

                            let customCuisines = formState.cuisines.filter { !cuisinesList.contains($0) }.sorted()
                            if !customCuisines.isEmpty {
                                RemovablePreferenceChips(
                                    items: customCuisines,
                                    tint: .green
                                ) { item in
                                    withAnimation {
                                        _ = formState.cuisines.remove(item)
                                    }
                                }
                                .padding(.horizontal, 24)
                            }

                            HStack(spacing: 12) {
                                ProfileTextField(
                                    placeholder: "Add a custom cuisine...",
                                    text: $formState.customCuisineInput
                                )
                                Button(action: {
                                    let input = formState.customCuisineInput.trimmingCharacters(in: .whitespaces)
                                    if !input.isEmpty {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        let newItem = "🍽️ " + input
                                        withAnimation {
                                            _ = formState.cuisines.insert(newItem)
                                        }
                                        formState.customCuisineInput = ""
                                    }
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(formState.customCuisineInput.isEmpty ? Color.gray.opacity(0.3) : Color.green)
                                }
                            }
                            .padding(.horizontal, 24)
                        }

                        ProfileSinglePreference(
                            title: "Spice Tolerance",
                            options: spiceList,
                            selected: $formState.spiceTolerance
                        ) {
                            activeSheet = .spice
                        }


                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Ingredients to Avoid")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                Button(action: { activeSheet = .dislikes }) {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundStyle(Color.primary.opacity(0.4))
                                }
                            }
                            .padding(.horizontal, 24)

                            if !formState.dislikesList.isEmpty {
                                RemovablePreferenceChips(items: Array(formState.dislikesList).sorted(), tint: .red) { item in
                                    withAnimation {
                                        _ = formState.dislikesList.remove(item)
                                    }
                                }
                                .padding(.horizontal, 24)
                            }

                            HStack(spacing: 12) {
                                ProfileTextField(
                                    placeholder: "e.g. Cilantro, Olives...",
                                    text: $formState.customDislikeInput
                                )
                                Button(action: {
                                    let input = formState.customDislikeInput.trimmingCharacters(in: .whitespaces)
                                    if !input.isEmpty {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        withAnimation {
                                            _ = formState.dislikesList.insert(input)
                                        }
                                        formState.customDislikeInput = ""
                                    }
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(formState.customDislikeInput.isEmpty ? Color.gray.opacity(0.3) : Color.red)
                                }
                            }
                            .padding(.horizontal, 24)
                        }

                        ProfileSinglePreference(
                            title: "Typical Serving Size",
                            options: servingsList,
                            selected: $formState.servingSize
                        ) {
                            activeSheet = .serving
                        }

                        ProfileSinglePreference(
                            title: "Budget",
                            options: budgetList,
                            selected: $formState.budget
                        ) {
                            activeSheet = .budget
                        }

                        ProfileSinglePreference(
                            title: "Leftovers",
                            options: leftoverPreferencesList,
                            selected: $formState.leftoverPreference
                        ) {
                            activeSheet = .leftovers
                        }
                    }
                    }
                }

                if selectedCategory == nil || selectedCategory == .notifications {
                    AnimatedSection(isVisible: showSections[4]) {
                    VStack(alignment: .leading, spacing: 22) {
                        if selectedCategory == nil {
                            ProfileSectionHeader(title: "Notifications", icon: "bell.badge")
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Smart Notification Plan")
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                    Text(notificationManager.notificationsEnabled ? "Three smart slots, fully adjustable." : "Enable notifications to personalize your nudges.")
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: notificationManager.notificationsEnabled ? "bell.badge.fill" : "bell.slash.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(notificationManager.notificationsEnabled ? .orange : .secondary)
                                    .padding(12)
                                    .background(Color.orange.opacity(notificationManager.notificationsEnabled ? 0.12 : 0.06))
                                    .clipShape(Circle())
                            }

                            Button {
                                ChefBuddyHaptics.medium()
                                let enableAll = !formState.notificationPreferences.contains(where: \.isEnabled)
                                for index in formState.notificationPreferences.indices {
                                    formState.notificationPreferences[index].isEnabled = enableAll
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(formState.notificationPreferences.contains(where: \.isEnabled) ? "Notifications are active" : "Notifications are paused")
                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                        Text("Turn every ChefBuddy reminder on or off together.")
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: formState.notificationPreferences.contains(where: \.isEnabled) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundStyle(formState.notificationPreferences.contains(where: \.isEnabled) ? .green : .secondary)
                                }
                                .padding(14)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            ForEach($formState.notificationPreferences) { $preference in
                                NotificationPreferenceCard(preference: $preference)
                            }
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                        )
                        .padding(.horizontal, 24)
                    }
                    }
                }

                if (selectedCategory == nil || selectedCategory == .chefBuddyAI), let onResetDiscovery {
                    AnimatedSection(isVisible: showSections[5]) {
                        VStack(alignment: .leading, spacing: 22) {
                            if selectedCategory == nil {
                                ProfileSectionHeader(title: "AI Discovery", icon: "sparkles")
                            }

                            ProfileSinglePreference(
                                title: "Coaching Style",
                                options: aiCoachingStylesList,
                                selected: $formState.aiCoachingStyle
                            ) {
                                activeSheet = .aiCoaching
                            }

                            ProfileSinglePreference(
                                title: "Recipe Creativity",
                                options: aiCreativityList,
                                selected: $formState.aiCreativity
                            ) {
                                activeSheet = .aiCreativity
                            }

                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "wand.and.stars.inverse")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(.orange)
                                        .frame(width: 42, height: 42)
                                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Reset ChefBuddy’s discovery memory")
                                            .font(.system(size: 18, weight: .bold, design: .rounded))

                                        Text("Clear saved swipe, save, and skip feedback so discovery starts learning from a fresh slate while keeping your saved recipes intact.")
                                            .font(.system(size: 14, weight: .medium, design: .rounded))
                                            .foregroundStyle(.secondary)
                                            .lineSpacing(3)
                                    }
                                }

                                Button(action: onResetDiscovery) {
                                    HStack(spacing: 10) {
                                        if isResettingDiscovery {
                                            ProgressView()
                                                .tint(.white)
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                                .font(.system(size: 16, weight: .bold))
                                        }

                                        Text(isResettingDiscovery ? "Resetting Discovery..." : "Clear AI Suggestions")
                                            .font(.system(size: 15, weight: .bold, design: .rounded))
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 15)
                                    .background(
                                        LinearGradient(
                                            colors: [.orange, .red.opacity(0.85)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(isResettingDiscovery)
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                            )
                            .padding(.horizontal, 24)
                        }
                    }
                }

                Spacer(minLength: selectedCategory == nil ? 120 : 28)
            }
        }
        .onAppear {
            syncDailyCaloriesIfNeeded(force: formState.dailyCalorieTarget <= 0)
            for i in 0..<showSections.count {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(i) * 0.15)) {
                    showSections[i] = true
                }
            }
        }
        .onChange(of: estimatedCalories) { newValue in
            if abs(formState.resolvedDailyCalorieTarget - newValue) <= 80 || formState.dailyCalorieTarget <= 0 {
                formState.dailyCalorieTarget = Double(newValue)
            }
        }
        .sheet(item: $activeSheet) { sheetType in
            SheetRouter(sheetType: sheetType)
        }
    }

    private func syncDailyCaloriesIfNeeded(force: Bool = false) {
        if force || formState.dailyCalorieTarget <= 0 {
            formState.dailyCalorieTarget = Double(estimatedCalories)
        }
    }
}


private let levelsList = ["🍳 Beginner", "👨‍🍳 Intermediate", "🔪 Advanced", "🌟 Masterchef"]
private let measurementSystemsList = ["🇺🇸 US cups & ounces", "🌍 Metric grams & ml"]
private let dietsList = ["🥗 Vegetarian", "🌿 Vegan", "🐟 Pescatarian", "🥩 Keto", "🍖 Paleo", "☪️ Halal", "✡️ Kosher"]
private let allergiesList = ["🥜 Peanuts", "🌳 Tree Nuts", "🥛 Dairy", "🥚 Eggs", "🦐 Shellfish", "🫘 Soy", "🌾 Gluten"]
private let macrosList = ["⚖️ Balanced", "💪 High Protein", "🔥 Low Calorie", "🍞 Low Carb"]
private let sexList = ["Male", "Female"]
private let goalsList = ["📉 Weight Loss", "⚖️ Maintain", "💪 Muscle Gain"]
private let goalPacesList = ["🌱 Steady", "⚡ Focused", "🧘 Flexible"]
private let activityList = ["🛋️ Sedentary", "🚶 Lightly Active", "🏃 Active", "🏋️ Athlete"]
private let appliancesList = ["🥄 Measuring Cups & Spoons", "♨️ Stove", "🍳 Oven", "🍚 Rice Cooker", "🌪️ Air Fryer", "🍲 Slow Cooker", "🥤 Blender", "🔪 Food Processor", "⏲️ Microwave", "🥘 Cast Iron", "🔥 Grill", "🧇 Waffle Maker", "🥪 Panini Press", "🍜 Pressure Cooker", "🫕 Dutch Oven", "🥣 Stand Mixer", "🫓 Toaster Oven", "🫙 Instant Pot"]
private let cookTimesList = ["⚡ < 15 mins", "⏱️ 15-30 mins", "⏳ 30-60 mins", "🕰️ 1 hr+"]
private let cookingFrequencyList = ["🌙 1–2 days/week", "📅 3–4 days/week", "🔥 5+ days/week", "🧺 Mostly meal prep"]
private let cleanupPreferencesList = ["🍳 One-pan preferred", "🧽 Balanced cleanup", "👨‍🍳 Cleanup is no issue"]
private let cuisinesList = ["🇮🇹 Italian", "🇲🇽 Mexican", "🇨🇳 Chinese", "🇯🇵 Japanese", "🇰🇷 Korean", "🇹🇭 Thai", "🇮🇳 Indian", "🇬🇷 Mediterranean", "🇺🇸 American", "🇫🇷 French", "🇪🇸 Spanish", "🇹🇷 Turkish", "🇻🇳 Vietnamese", "🇱🇧 Lebanese", "🇧🇷 Brazilian", "🇲🇦 Moroccan"]
private let spiceList = ["🌿 Mild", "🌶️ Medium", "🔥 Spicy", "🌋 Extra Spicy"]
private let servingsList = ["👤 1 Person", "👥 2 People", "👨‍👩‍👧‍👦 3-4 People", "🏠 5+ People"]
private let budgetList = ["🪙 $ (Budget)", "💵 $$ (Standard)", "💰 $$$ (Gourmet)"]
private let leftoverPreferencesList = ["🥡 Enjoy leftovers", "🍽️ Fresh meals only", "🧊 Cook once, eat twice"]
private let aiCoachingStylesList = ["🎯 Direct & practical", "🧑‍🏫 Explain the why", "💬 Friendly & encouraging"]
private let aiCreativityList = ["🛟 Familiar favorites", "✨ Balanced", "🚀 Surprise me"]

private struct AnimatedSection<Content: View>: View {
    var isVisible: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .opacity(isVisible ? 1.0 : 0.0)
        .offset(y: isVisible ? 0 : 30)
    }
}

private struct NotificationPreferenceCard: View {
    @Binding var preference: NotificationSlotPreference

    private var bindingDate: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = preference.hour
                components.minute = preference.minute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                preference.hour = components.hour ?? preference.hour
                preference.minute = components.minute ?? preference.minute
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: preference.kind.settingsIcon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(preference.isEnabled ? .orange : .secondary)
                    .frame(width: 42, height: 42)
                    .background((preference.isEnabled ? Color.orange : Color.primary).opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(preference.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(preference.kind.title)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $preference.isEnabled)
                    .labelsHidden()
                    .tint(.green)
                    .onChange(of: preference.isEnabled) { _, _ in
                        ChefBuddyHaptics.selection()
                    }
            }

            HStack(spacing: 10) {
                DatePicker("", selection: bindingDate, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .disabled(!preference.isEnabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.055), in: Capsule())

                Menu {
                    ForEach(NotificationSlotKind.allCases, id: \.self) { kind in
                        Button {
                            ChefBuddyHaptics.light()
                            preference.kind = kind
                        } label: {
                            Label(kind.title, systemImage: kind.settingsIcon)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: preference.kind.settingsIcon)
                            .font(.system(size: 11, weight: .bold))
                        Text(preference.kind.title)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(preference.isEnabled ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.055), in: Capsule())
                }
                .disabled(!preference.isEnabled)
            }
        }
        .padding(15)
        .background(
            LinearGradient(
                colors: [
                    Color.primary.opacity(preference.isEnabled ? 0.055 : 0.032),
                    Color.orange.opacity(preference.isEnabled ? 0.07 : 0.015)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(preference.isEnabled ? Color.orange.opacity(0.15) : Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

private extension NotificationSlotKind {
    var settingsIcon: String {
        switch self {
        case .pantry: return "basket.fill"
        case .mealPlan: return "calendar.badge.clock"
        case .inspiration: return "sparkles"
        }
    }
}

private struct MetricStepperCard: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    let onInfo: () -> Void

    private var displayedValue: String {
        "\(Int(value.rounded())) \(suffix)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                Button(action: onInfo) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                stepButton(systemImage: "minus") {
                    value = max(range.lowerBound, value - step)
                }

                Text(displayedValue)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                stepButton(systemImage: "plus") {
                    value = min(range.upperBound, value + step)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func stepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            ChefBuddyHaptics.light()
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                action()
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color.orange, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct HeightStepperCard: View {
    let title: String
    @Binding var inches: Double
    let onInfo: () -> Void

    private var feet: Int { Int(inches.rounded()) / 12 }
    private var remainingInches: Int { Int(inches.rounded()) % 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                Button(action: onInfo) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                heightButton(systemImage: "minus") {
                    inches = max(36, inches - 1)
                }

                VStack(spacing: 2) {
                    Text("\(feet)′ \(remainingInches)″")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                    Text("\(Int(inches.rounded())) inches")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                heightButton(systemImage: "plus") {
                    inches = min(96, inches + 1)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func heightButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            ChefBuddyHaptics.light()
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                action()
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color.orange, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct LogoutConfirmationSheet: View {
    let email: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            ProfileBackground()

            VStack(spacing: 18) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.red)
                    .frame(width: 78, height: 78)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(spacing: 6) {
                    Text("Log out of ChefBuddy?")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                    Text(email)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 9) {
                    Label("Recipes, pantry spaces, and meal plans stay saved", systemImage: "checkmark.circle.fill")
                    Label("You can sign back in whenever you need", systemImage: "checkmark.circle.fill")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(action: onConfirm) {
                        Text("Log Out")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
    }
}

private struct ProfileBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Circle()
                .fill(Color.orange.opacity(0.12))
                .blur(radius: 80)
                .offset(x: -150, y: -300)
            Circle()
                .fill(Color.green.opacity(0.1))
                .blur(radius: 80)
                .offset(x: 150, y: 300)
        }
    }
}

private struct ProfileSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack {
                Divider()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }
}

private struct ProfileTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(keyboardType)
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }
}

private struct ProfileSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    let onInfoTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                    Button(action: onInfoTap) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color.primary.opacity(0.4))
                    }
                }
                Spacer()
                Text(String(format: format, value))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            Slider(value: $value, in: range, step: 1.0).tint(.orange)
        }
    }
}

private struct ProfileHeightSlider: View {
    let title: String
    @Binding var inches: Double
    let onInfoTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                    Button(action: onInfoTap) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color.primary.opacity(0.4))
                    }
                }
                Spacer()
                Text("\(Int(inches) / 12) ft  \(Int(inches) % 12) in")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)
            }
            Slider(value: $inches, in: 48...84, step: 1.0).tint(.green)
        }
    }
}

private struct ProfileSinglePreference: View {
    let title: String
    let options: [String]
    @Binding var selected: String
    var onInfoTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                    if let onInfoTap = onInfoTap {
                        Button(action: onInfoTap) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(Color.primary.opacity(0.4))
                        }
                    }
                }
                Spacer()
                Text("Choose one")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ForEach(options, id: \.self) { option in
                    let isSelected = selected == option
                    Button {
                        ChefBuddyHaptics.selection()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                            selected = option
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "checkmark.seal.fill" : "circle")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(isSelected ? .orange : .secondary.opacity(0.42))
                            Text(option)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.80)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .background(
                            isSelected
                                ? AnyShapeStyle(LinearGradient(colors: [Color.orange.opacity(0.22), Color.purple.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(Color.primary.opacity(0.035)),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(isSelected ? Color.orange.opacity(0.40) : Color.primary.opacity(0.055), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }
}

private struct ProfileMultiPreference: View {
    let title: String
    let options: [String]
    @Binding var selected: Set<String>
    var previewLimit: Int? = nil
    var onInfoTap: (() -> Void)? = nil
    private var visibleOptions: [String] {
        options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                    if let onInfoTap = onInfoTap {
                        Button(action: onInfoTap) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(Color.primary.opacity(0.4))
                        }
                    }
                }
                Spacer()
                Text("\(selected.count) selected")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ForEach(visibleOptions, id: \.self) { option in
                    let isSelected = selected.contains(option)
                    Button {
                        ChefBuddyHaptics.selection()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                            if isSelected {
                                _ = selected.remove(option)
                            } else {
                                _ = selected.insert(option)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(option)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.84)
                            Spacer(minLength: 2)
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(isSelected ? .green : .secondary.opacity(0.45))
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(
                            isSelected
                                ? AnyShapeStyle(LinearGradient(colors: [Color.green.opacity(0.20), Color.blue.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(Color.primary.opacity(0.035)),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(isSelected ? Color.green.opacity(0.34) : Color.primary.opacity(0.05), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }
}

private struct RemovablePreferenceChips: View {
    let items: [String]
    let tint: Color
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(items, id: \.self) { item in
                Button {
                    onRemove(item)
                } label: {
                    HStack(spacing: 6) {
                        Text(item)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .lineLimit(2)
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(tint)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ProfileSequentialIconView: View {
    let icons = ["slider.horizontal.3", "heart.circle.fill", "flame.fill"]
    @State private var currentIndex = 0
    @State private var isAnimating = false
    let timer = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.orange.opacity(0.15), .green.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 180, height: 180)
                .scaleEffect(isAnimating ? 1.0 : 0.8)

            Image(systemName: icons[currentIndex])
                .font(.system(size: 70, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .green],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .scaleEffect(isAnimating ? 1.0 : 0.5)
                .opacity(isAnimating ? 1.0 : 0.0)
                .id(currentIndex)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) {
                isAnimating = true
            }
        }
        .onReceive(timer) { _ in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isAnimating = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    currentIndex = (currentIndex + 1) % icons.count
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) {
                        isAnimating = true
                    }
                }
            }
        }
    }
}


private enum ActiveSheet: String, Identifiable {
    case level
    case diet
    case allergy
    case macro
    case measurements
    case physical
    case sex
    case calories
    case goal
    case goalPace
    case activity
    case appliances
    case cookTime
    case cookingFrequency
    case cuisines
    case spice
    case dislikes
    case serving
    case budget
    case leftovers
    case aiCoaching
    case aiCreativity

    var id: String { self.rawValue }
}

private struct SheetRouter: View {
    let sheetType: ActiveSheet

    var body: some View {
        switch sheetType {
        case .level:
            ProfileDetailedInfoSheet(title: "Chef Levels", subtitle: "Tell us your comfort level in the kitchen.", items: [
                ("🍳", "Beginner", "You need step-by-step help, clear instructions, and simple recipes."),
                ("👨‍🍳", "Intermediate", "Comfortable with basics and looking to expand your skills."),
                ("🔪", "Advanced", "Confident cook who handles complex techniques and timing."),
                ("🌟", "Masterchef", "An expert looking for culinary challenges and inspiration.")
            ])
            .presentationDetents([.fraction(0.55)])

        case .diet:
            ProfileDetailedInfoSheet(title: "Dietary Preferences", subtitle: "We filter out recipes that don't fit these rules.", items: [
                ("🥗", "Vegetarian", "No meat or poultry."),
                ("🌿", "Vegan", "No animal products whatsoever."),
                ("🐟", "Pescatarian", "Vegetarian plus seafood."),
                ("🥩", "Keto", "High fat, very low carb."),
                ("🍖", "Paleo", "Whole foods, no grains/dairy."),
                ("☪️", "Halal", "Prepared according to Islamic law."),
                ("✡️", "Kosher", "Prepared according to Jewish dietary laws.")
            ])
            .presentationDetents([.fraction(0.7)])

        case .allergy:
            ProfileDetailedInfoSheet(title: "Allergies", subtitle: "ChefBuddy will strictly exclude these ingredients.", items: [
                ("🥜", "Peanuts", "Avoids all peanut products."),
                ("🌳", "Tree Nuts", "Almonds, walnuts, pecans, etc."),
                ("🥛", "Dairy", "Milk, cheese, butter, yogurt."),
                ("🥚", "Eggs", "All egg products."),
                ("🦐", "Shellfish", "Shrimp, crab, lobster, etc."),
                ("🫘", "Soy", "Tofu, soy sauce, edamame."),
                ("🌾", "Gluten", "Wheat, barley, rye.")
            ])
            .presentationDetents([.fraction(0.7)])

        case .macro:
            ProfileDetailedInfoSheet(title: "Macro Goals", subtitle: "AI prioritizes recipes that fit your needs.", items: [
                ("⚖️", "Balanced", "A well-rounded ratio of proteins, fats, and carbs."),
                ("💪", "High Protein", "Prioritizes muscle growth and recovery."),
                ("🔥", "Low Calorie", "Focuses on meals for weight management."),
                ("🍞", "Low Carb", "Minimizes carbohydrates for specialized diets.")
            ])
            .presentationDetents([.fraction(0.55)])

        case .measurements:
            ProfileSimpleInfoSheet(
                title: "Recipe Measurements",
                message: "Choose whether ChefBuddy should write ingredient quantities in US-style cups and tablespoons or metric grams and milliliters when it can."
            )
            .presentationDetents([.fraction(0.34)])

        case .physical:
            ProfileSimpleInfoSheet(
                title: "Body Metrics",
                message: "We use your age, height, weight, sex, target goal, and activity level to estimate your daily calorie needs. BMI is shown as a simple weight-to-height ratio, and calorie needs are estimated separately using the Mifflin-St Jeor equation plus an activity multiplier."
            )
            .presentationDetents([.fraction(0.42)])

        case .sex:
            ProfileSimpleInfoSheet(
                title: "Sex",
                message: "Sex is included because the calorie estimate uses the Mifflin-St Jeor equation, which uses slightly different constants for male and female metabolism estimates."
            )
            .presentationDetents([.fraction(0.32)])

        case .calories:
            ProfileDetailedInfoSheet(
                title: "How Calories Are Calculated",
                subtitle: "A quick overview of the recommendation logic.",
                items: [
                    ("1️⃣", "Base Metabolism (BMR)", "We estimate your baseline burn using age, height, weight, and sex with the Mifflin-St Jeor equation."),
                    ("2️⃣", "Activity Multiplier", "We multiply BMR by your activity level: Sedentary 1.2, Lightly Active 1.375, Active 1.55, Athlete 1.725."),
                    ("3️⃣", "Goal Adjustment", "Weight Loss: -400 kcal, Maintain: no change, Muscle Gain: +250 kcal."),
                    ("⚠️", "Important", "This is a general app estimate and not a medical diagnosis or personalized clinical advice.")
                ]
            )
            .presentationDetents([.fraction(0.72)])

        case .goal:
            ProfileDetailedInfoSheet(title: "Target Goal", subtitle: "Adjusts meal portions accordingly.", items: [
                ("📉", "Weight Loss", "Caloric deficit for shedding pounds."),
                ("⚖️", "Maintain", "Maintenance calories to stay exactly where you are."),
                ("💪", "Muscle Gain", "Caloric surplus focused on protein intake.")
            ])
            .presentationDetents([.fraction(0.45)])

        case .goalPace:
            ProfileDetailedInfoSheet(title: "Goal Pace", subtitle: "Controls how assertively ChefBuddy adjusts calorie recommendations.", items: [
                ("🌱", "Steady", "Small, sustainable adjustments around your saved goal."),
                ("⚡", "Focused", "More direct recommendations for faster progress."),
                ("🧘", "Flexible", "Keeps suggestions gentler when life or schedule varies.")
            ])
            .presentationDetents([.fraction(0.48)])

        case .activity:
            ProfileDetailedInfoSheet(title: "Activity Level", subtitle: "Helps calculate daily energy expenditure.", items: [
                ("🛋️", "Sedentary", "Little to no exercise, desk job."),
                ("🚶", "Lightly Active", "Light exercise/sports 1-3 days a week."),
                ("🏃", "Active", "Moderate exercise/sports 3-5 days a week."),
                ("🏋️", "Athlete", "Hard exercise/sports 6-7 days a week.")
            ])
            .presentationDetents([.fraction(0.55)])

        case .appliances:
            ProfileDetailedInfoSheet(title: "Appliances", subtitle: "We'll only suggest meals you can actually cook.", items: [
                ("♨️", "Stove", "Standard stovetop cooking."),
                ("🍳", "Oven", "Baking and roasting."),
                ("🍚", "Rice Cooker", "Automated rice and grain cooking."),
                ("🌪️", "Air Fryer", "High-heat convection cooking."),
                ("🍲", "Slow Cooker", "Low-temperature, long-duration cooking."),
                ("🥤", "Blender", "Smoothies and purees."),
                ("🔪", "Food Processor", "Chopping and mixing dense ingredients."),
                ("⏲️", "Microwave", "Quick reheating and steaming."),
                ("🥘", "Cast Iron", "High-heat searing and stovetop-to-oven.")
            ])
            .presentationDetents([.fraction(0.85)])

        case .cookTime:
            ProfileDetailedInfoSheet(title: "Cook Time", subtitle: "How long do you want to spend?", items: [
                ("⚡", "< 15 mins", "Lightning fast, minimal prep."),
                ("⏱️", "15-30 mins", "Standard weeknight dinner."),
                ("⏳", "30-60 mins", "A bit more involved, great for weekends."),
                ("🕰️", "1 hr+", "Slow roasting, braising, or complex meals.")
            ])
            .presentationDetents([.fraction(0.55)])

        case .cookingFrequency:
            ProfileDetailedInfoSheet(title: "Cooking Frequency", subtitle: "Helps ChefBuddy decide how often to suggest fresh plans versus repeats.", items: [
                ("🌙", "Rarely", "More beginner-friendly and lower-pressure ideas."),
                ("📅", "Weekly", "Balanced meal planning with practical leftovers."),
                ("🔥", "Most days", "More variety and faster rotation."),
                ("👨‍🍳", "Daily", "Assumes cooking is part of your normal rhythm.")
            ])
            .presentationDetents([.fraction(0.55)])

        case .cuisines:
            ProfileSimpleInfoSheet(
                title: "Cuisines",
                message: "Select your favorite flavors, or add your own custom cuisines using the text box. We'll tailor recipe styles to match your cravings."
            )
            .presentationDetents([.fraction(0.35)])

        case .spice:
            ProfileDetailedInfoSheet(title: "Spice Tolerance", subtitle: "How much heat can you handle?", items: [
                ("🌿", "Mild", "No heat, focus on herbs and aromatics."),
                ("🌶️", "Medium", "A little kick, family-friendly."),
                ("🔥", "Spicy", "Noticeable burn, jalapeño level."),
                ("🌋", "Extra Spicy", "Bring on the habaneros and ghost peppers.")
            ])
            .presentationDetents([.fraction(0.55)])

        case .dislikes:
            ProfileSimpleInfoSheet(
                title: "Ingredients to Avoid",
                message: "Not an allergy, just a preference. If you hate cilantro or mushrooms, put them here and you won't see them in recipes."
            )
            .presentationDetents([.fraction(0.35)])

        case .serving:
            ProfileDetailedInfoSheet(title: "Serving Size", subtitle: "Auto-scales ingredient measurements.", items: [
                ("👤", "1 Person", "Single portions, minimal leftovers."),
                ("👥", "2 People", "Perfect for couples."),
                ("👨‍👩‍👧‍👦", "3-4 People", "Standard family dinners."),
                ("🏠", "5+ People", "Large batches and gatherings.")
            ])
            .presentationDetents([.fraction(0.55)])

        case .budget:
            ProfileDetailedInfoSheet(title: "Budget", subtitle: "Controls the cost of suggested ingredients.", items: [
                ("🪙", "$ (Budget)", "Affordable staples: beans, rice, chicken thighs."),
                ("💵", "$$ (Standard)", "Everyday grocery items."),
                ("💰", "$$$ (Gourmet)", "Premium cuts, saffron, fresh seafood.")
            ])
            .presentationDetents([.fraction(0.45)])

        case .leftovers:
            ProfileDetailedInfoSheet(title: "Leftovers", subtitle: "Guides whether ChefBuddy should plan intentional extra servings.", items: [
                ("🚫", "Avoid leftovers", "Favors smaller recipes and fresher meals."),
                ("⚖️", "Some leftovers", "Allows practical extras without filling the fridge."),
                ("📦", "Meal prep friendly", "Leans into batch cooking and repeatable lunches.")
            ])
            .presentationDetents([.fraction(0.48)])

        case .aiCoaching:
            ProfileDetailedInfoSheet(title: "Coaching Style", subtitle: "Changes how direct ChefBuddy sounds when guiding you.", items: [
                ("🤝", "Gentle", "More encouragement and lower-pressure suggestions."),
                ("🎯", "Direct", "Clear recommendations with less extra explanation."),
                ("🧠", "Detailed", "More context, tradeoffs, and cooking reasoning.")
            ])
            .presentationDetents([.fraction(0.48)])

        case .aiCreativity:
            ProfileDetailedInfoSheet(title: "Recipe Creativity", subtitle: "Controls how adventurous discovery and generated recipes should feel.", items: [
                ("🛟", "Familiar favorites", "Safer, recognizable meals."),
                ("✨", "Balanced", "A mix of comfortable and fresh ideas."),
                ("🚀", "Surprise me", "More unusual pairings and cuisines.")
            ])
            .presentationDetents([.fraction(0.48)])
        }
    }
}

private struct ProfileDetailedInfoSheet: View {
    let title: String
    let subtitle: String?
    let items: [(String, String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(items, id: \.1) { item in
                        HStack(alignment: .top, spacing: 16) {
                            Text(item.0).font(.title)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.1).font(.headline.bold())
                                Text(item.2)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(24)
        .padding(.top, 16)
        .presentationDragIndicator(.visible)
    }
}

private struct ProfileSimpleInfoSheet: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
            }

            Text(message)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .lineSpacing(4)

            Spacer()
        }
        .padding(24)
        .padding(.top, 16)
        .presentationDragIndicator(.visible)
    }
}
