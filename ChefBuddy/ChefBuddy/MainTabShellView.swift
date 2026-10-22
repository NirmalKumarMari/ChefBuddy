import SwiftUI
import FirebaseFirestore
import FirebaseAuth
import UIKit
import Combine

enum AppTab: Hashable {
    case plan
    case pantry
    case home
    case recipes
    case profile
}

enum ChefBuddyHaptics {
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.72)
    }

    static func medium() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.86)
    }

    static func heavy() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }
}

extension Notification.Name {
    static let chefBuddyPreferencesDidChange = Notification.Name("ChefBuddyPreferencesDidChange")
}

struct MainTabShellView: View {
    @EnvironmentObject private var authVM: AuthViewModel
    @EnvironmentObject private var deepLinkRouter: ChefBuddyDeepLinkRouter
    @StateObject private var assistant = CookingAssistant()
    @State private var selectedTab: AppTab = .home
    @State private var showGroceryList = false
    @State private var showRecipePicker = false
    @State private var selectedLiveRecipe: Recipe? = nil
    @State private var showOpenKitchen = false
    @State private var savedRecipes: [Recipe] = []
    @State private var recipesListener: ListenerRegistration? = nil
    @StateObject private var quickGenerateVM = RecipesViewModel()
    @State private var showQuickGenerate = false
    @State private var sharedRecipePreview: SharedRecipeSnapshot?
    @State private var sharedRecipeError: String?
    @State private var showAppTutorial = false
    @State private var tutorialCheckedUserId = ""

    private var userId: String? {
        authVM.userSession?.uid
    }

    private var budgetPreference: String {
        authVM.currentUserProfile?.budget ?? "💵 $$ (Standard)"
    }

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().isHidden = true
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                PlanTabRootView(assistant: assistant)
            }
            .tag(AppTab.plan)
            .tabItem {
                Label("Plan", systemImage: "calendar")
            }

            NavigationStack {
                PantryTabRootView(
                    assistant: assistant,
                    onOpenGrocery: { showGroceryList = true }
                )
            }
            .tag(AppTab.pantry)
            .tabItem {
                Label("Pantry", systemImage: "basket.fill")
            }

            NavigationStack {
                ImmersiveHomeView(
                    assistant: assistant,
                    savedRecipes: savedRecipes,
                    selectedTab: $selectedTab,
                    onOpenGrocery: { showGroceryList = true },
                    onOpenQuickGenerate: { showQuickGenerate = true },
                    onOpenLiveCookingPicker: { showRecipePicker = true }
                )
            }
            .tag(AppTab.home)
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }

            NavigationStack {
                RecipesTabRootView(
                    assistant: assistant,
                    savedRecipes: savedRecipes,
                    onOpenLiveCookingPicker: { showRecipePicker = true }
                )
            }
            .tag(AppTab.recipes)
            .tabItem {
                Label("Recipes", systemImage: "book.closed.fill")
            }

            NavigationStack {
                ProfileTabRootView()
            }
            .tag(AppTab.profile)
            .tabItem {
                Label("Profile", systemImage: "person.crop.circle")
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectedTab != .home {
                Color.clear.frame(height: 86)
            }
        }
        .overlay(alignment: .bottom) {
            FloatingShellTabBar(selectedTab: $selectedTab)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
        }
        .tint(.orange)
        .task(id: userId) {
            guard let userId else {
                stopRecipesListener()
                savedRecipes = []
                return
            }

            await assistant.setupAssistant(userId: userId)
            startRecipesListener(userId: userId)
            quickGenerateVM.startListening(userId: userId)

            if tutorialCheckedUserId != userId {
                tutorialCheckedUserId = userId
                let tutorialKey = "chefbuddy.appTutorial.completed.\(userId)"
                if !UserDefaults.standard.bool(forKey: tutorialKey) {
                    showAppTutorial = true
                }
            }
        }
        .task(id: deepLinkRouter.pendingShareID) {
            guard userId != nil, authVM.currentUserProfile != nil,
                  let shareID = deepLinkRouter.pendingShareID else { return }
            do {
                sharedRecipePreview = try await RecipeShareService.shared.fetchSnapshot(id: shareID)
            } catch {
                sharedRecipeError = error.localizedDescription
                deepLinkRouter.clear()
            }
        }
        .onDisappear {
            stopRecipesListener()
            quickGenerateVM.stopListening()
        }
        .onReceive(NotificationCenter.default.publisher(for: .chefBuddyPreferencesDidChange)) { _ in
            guard let userId else { return }
            Task {
                await assistant.setupAssistant(userId: userId)
            }
        }
        .sheet(isPresented: $showGroceryList) {
            NavigationStack {
                if let userId {
                    GroceryListView(
                        userId: userId,
                        assistant: assistant,
                        budgetPreference: budgetPreference
                    )
                } else {
                    Text("Sign in to view your grocery list.")
                        .padding()
                }
            }
        }
        .sheet(isPresented: $showRecipePicker) {
            RecipePickerSheet(
                recipes: savedRecipes,
                onOpenKitchen: {
                    showRecipePicker = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showOpenKitchen = true
                    }
                }
            ) { recipe in
                selectedLiveRecipe = recipe
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showQuickGenerate) {
            if let userId {
                GenerateRecipeSheet(
                    vm: quickGenerateVM,
                    assistant: assistant,
                    userId: userId,
                    title: "What’s on Your Mind?",
                    subtitle: "Describe what sounds good right now and ChefBuddy will turn it into a complete recipe."
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $sharedRecipePreview, onDismiss: {
            deepLinkRouter.clear()
        }) { snapshot in
            SharedRecipeImportView(
                snapshot: snapshot,
                alreadySaved: savedRecipes.contains {
                    RecipeShareService.isEquivalent($0, snapshot.recipe)
                },
                onSave: {
                    guard let userId else { return }
                    do {
                        _ = try await RecipeShareService.shared.importSnapshot(snapshot, userId: userId)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        await MainActor.run {
                            sharedRecipePreview = nil
                            deepLinkRouter.clear()
                        }
                    } catch {
                        await MainActor.run {
                            sharedRecipeError = error.localizedDescription
                        }
                    }
                },
                onDismiss: {
                    sharedRecipePreview = nil
                    deepLinkRouter.clear()
                }
            )
        }
        .alert("Shared Recipe", isPresented: Binding(
            get: { sharedRecipeError != nil },
            set: { if !$0 { sharedRecipeError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sharedRecipeError ?? "")
        }
        .sheet(item: $quickGenerateVM.justGeneratedRecipe) { recipe in
            RecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                onFavorite: {
                    quickGenerateVM.toggleFavorite(recipe, userId: userId ?? "")
                },
                onDelete: {
                    quickGenerateVM.deleteRecipe(recipe, userId: userId ?? "")
                    quickGenerateVM.justGeneratedRecipe = nil
                },
                userId: userId ?? "",
                onRecipeUpdated: { updated in
                    quickGenerateVM.updateRecipeAfterReview(updated, userId: userId ?? "")
                    quickGenerateVM.justGeneratedRecipe = updated
                },
                onLiveHelp: {
                    quickGenerateVM.justGeneratedRecipe = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        selectedLiveRecipe = recipe
                    }
                }
            )
        }
        .fullScreenCover(item: $selectedLiveRecipe) { recipe in
            if let userId {
                LiveCookingView(recipe: recipe, assistant: assistant, userId: userId)
            } else {
                Text("Sign in to use Live Cooking Help.")
            }
        }
        .fullScreenCover(isPresented: $showOpenKitchen) {
            if let userId {
                OpenKitchenLiveView(assistant: assistant, userId: userId)
            } else {
                Text("Sign in to use Live Cooking Help.")
            }
        }
        .fullScreenCover(isPresented: $showAppTutorial) {
            ChefBuddyAppTutorialView {
                if let userId {
                    UserDefaults.standard.set(true, forKey: "chefbuddy.appTutorial.completed.\(userId)")
                }
                showAppTutorial = false
            }
        }
    }

    private func startRecipesListener(userId: String) {
        recipesListener?.remove()
        recipesListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("recipes")
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }
                DispatchQueue.main.async {
                    savedRecipes = documents.compactMap { try? $0.data(as: Recipe.self) }
                }
            }
    }

    private func stopRecipesListener() {
        recipesListener?.remove()
        recipesListener = nil
    }
}

private struct ChefBuddyTutorialStep: Identifiable {
    let id: Int
    let eyebrow: String
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let highlights: [(String, String)]
}

struct ChefBuddyAppTutorialView: View {
    let onFinish: () -> Void

    @State private var page = 0
    @State private var animateGlow = false

    private let steps: [ChefBuddyTutorialStep] = [
        ChefBuddyTutorialStep(
            id: 0,
            eyebrow: "YOUR KITCHEN, CONNECTED",
            title: "Everything starts together.",
            subtitle: "One personal flow from ingredients to the finished plate.",
            icon: "sparkles",
            tint: .orange,
            highlights: [
                ("Personal by design", ""),
                ("Ready for real life", "")
            ]
        ),
        ChefBuddyTutorialStep(
            id: 1,
            eyebrow: "IDEA TO RECIPE",
            title: "Say what sounds good.",
            subtitle: "A craving, a time limit, or what is already in the fridge is enough.",
            icon: "wand.and.stars",
            tint: .purple,
            highlights: [
                ("What’s on your mind", ""),
                ("Pantry based ideas", "")
            ]
        ),
        ChefBuddyTutorialStep(
            id: 2,
            eyebrow: "PANTRY AND RECIPES",
            title: "Cook from your real kitchen.",
            subtitle: "Stocked ingredients shape discovery, saved recipes, and the grocery list.",
            icon: "basket.fill",
            tint: .green,
            highlights: [
                ("Swipe kitchen spaces", ""),
                ("Save what fits", "")
            ]
        ),
        ChefBuddyTutorialStep(
            id: 3,
            eyebrow: "PLAN AND SHOP",
            title: "Let the week work as one.",
            subtitle: "Meals follow your preferences and body goals. The list keeps only what is missing.",
            icon: "calendar.badge.checkmark",
            tint: .blue,
            highlights: [
                ("Nutrition aware plans", ""),
                ("Shared ingredients sync", "")
            ]
        ),
        ChefBuddyTutorialStep(
            id: 4,
            eyebrow: "LIVE COOKING",
            title: "Help while your hands are busy.",
            subtitle: "Talk, type, or use the camera while ChefBuddy guides the next step.",
            icon: "waveform.and.mic",
            tint: .purple,
            highlights: [
                ("Recipe optional", ""),
                ("Camera guidance", "")
            ]
        ),
        ChefBuddyTutorialStep(
            id: 5,
            eyebrow: "YOUR COOKING STORY",
            title: "See the kitchen you are building.",
            subtitle: "Photos, streaks, cooking time, and badges turn everyday progress into something visible.",
            icon: "trophy.fill",
            tint: .yellow,
            highlights: [
                ("Cookbook memories", ""),
                ("Milestones that matter", "")
            ]
        )
    ]

    private var currentStep: ChefBuddyTutorialStep {
        steps[min(max(page, 0), steps.count - 1)]
    }

    var body: some View {
        ZStack {
            ChefBuddyBackground()

            Circle()
                .fill(currentStep.tint.opacity(animateGlow ? 0.19 : 0.10))
                .frame(width: 330, height: 330)
                .blur(radius: 70)
                .offset(x: 135, y: -280)
                .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: animateGlow)

            Image(systemName: currentStep.icon)
                .font(.system(size: 270, weight: .ultraLight))
                .foregroundStyle(Color.white.opacity(0.025))
                .rotationEffect(.degrees(animateGlow ? 10 : -8))
                .offset(x: -150, y: 250)

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CHEFBUDDY TOUR")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .tracking(1)
                            .foregroundStyle(currentStep.tint)
                        Text("\(page + 1) of \(steps.count)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }

                    ProgressView(value: Double(page + 1), total: Double(steps.count))
                        .tint(currentStep.tint)

                    Button("Skip") {
                        ChefBuddyHaptics.light()
                        onFinish()
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 10)

                TabView(selection: $page) {
                    ForEach(steps) { step in
                        tutorialPage(step)
                            .tag(step.id)
                            .padding(.horizontal, 22)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 12) {
                    Spacer()

                    if page > 0 {
                        Button {
                            ChefBuddyHaptics.selection()
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                page -= 1
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 50, height: 50)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        ChefBuddyHaptics.medium()
                        if page == steps.count - 1 {
                            ChefBuddyHaptics.success()
                            onFinish()
                        } else {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                page += 1
                            }
                        }
                    } label: {
                        Image(systemName: page == steps.count - 1 ? "checkmark" : "chevron.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(currentStep.tint)
                        .frame(width: 58, height: 58)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
        .onAppear {
            animateGlow = true
        }
        .animation(.easeInOut(duration: 0.24), value: page)
    }

    private func tutorialPage(_ step: ChefBuddyTutorialStep) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            Spacer(minLength: 18)

            ZStack {
                Circle()
                    .fill(step.tint.opacity(0.13))
                    .frame(width: 286, height: 286)
                    .blur(radius: 24)

                Circle()
                    .stroke(step.tint.opacity(0.26), lineWidth: 1)
                    .frame(width: 250, height: 250)

                ForEach(0..<3, id: \.self) { index in
                    let angle = (-Double.pi / 2) + (Double(index) * (.pi * 2 / 3))
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 46, height: 46)
                        .overlay(
                            Image(systemName: index == 0 ? "sparkles" : index == 1 ? "checkmark" : "arrow.triangle.2.circlepath")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(step.tint)
                        )
                        .overlay(Circle().stroke(Color.white.opacity(0.13), lineWidth: 1))
                        .offset(x: cos(angle) * 125, y: sin(angle) * 125)
                }

                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 156, height: 156)
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [step.tint.opacity(0.30), step.tint.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 156, height: 156)
                Image(systemName: step.icon)
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(step.tint)
                    .symbolEffect(.bounce, value: page)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    .frame(width: 286, height: 286)
            )

            VStack(alignment: .leading, spacing: 9) {
                Text(step.eyebrow)
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(step.tint)
                Text(step.title)
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.subtitle)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 9) {
                ForEach(Array(step.highlights.enumerated()), id: \.offset) { index, highlight in
                    HStack(spacing: 7) {
                        Image(systemName: index == 0 ? "sparkle" : "checkmark.seal.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(step.tint)
                        Text(highlight.0)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 13)
                    .background(step.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }

            Spacer(minLength: 24)
        }
    }
}

private struct HomeInspirationSlide: Identifiable {
    let id: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let icon: String
    let colors: [Color]
    let badge: String
    var opensCreator = false
}

struct HomeDashboardView: View {
    @EnvironmentObject private var authVM: AuthViewModel
    @ObservedObject var assistant: CookingAssistant
    let savedRecipes: [Recipe]
    @Binding var selectedTab: AppTab
    let onOpenGrocery: () -> Void
    let onOpenQuickGenerate: () -> Void
    let onOpenLiveCookingPicker: () -> Void

    @State private var pantrySpaces: [SimplePantrySpace] = []
    @State private var weeklySlots: [MealPlanSlot] = []
    @State private var pantryListener: ListenerRegistration? = nil
    @State private var mealPlanListener: ListenerRegistration? = nil
    @State private var greetingText = ""
    @State private var dailyPrompt = "What are we cooking today? 🍳"
    @State private var homeCarouselIndex = 0
    @State private var aiKitchenIdea = "ChefBuddy is finding an idea that fits your kitchen."
    @State private var isLoadingKitchenIdea = false
    @State private var personalizedKitchenTip = "ChefBuddy is preparing a tip for your kitchen."
    @State private var isLoadingKitchenTip = false
    @State private var inspirationOrder: [String] = []
    private let homeCarouselTimer = Timer.publish(every: 6.5, on: .main, in: .common).autoconnect()

    private let mealTypeOrder = ["Breakfast", "Lunch", "Dinner"]

    private var userId: String {
        authVM.userSession?.uid ?? ""
    }

    private var displayName: String {
        if let name = authVM.userSession?.displayName, !name.isEmpty {
            return String(name.split(separator: " ").first ?? "")
        } else if let email = authVM.userSession?.email {
            return String(email.split(separator: "@").first ?? "Chef")
        }
        return "Chef"
    }

    private var pantryItemCount: Int {
        pantrySpaces.reduce(0) { $0 + $1.ingredients.count }
    }

    private var plannedSlotCount: Int {
        weeklySlots.filter { !$0.displayTitle.isEmpty }.count
    }

    private var todayName: String {
        let weekday = Calendar.current.component(.weekday, from: Date())
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[max(0, min(names.count - 1, weekday - 1))]
    }

    private var todaySlots: [MealPlanSlot] {
        mealTypeOrder.compactMap { mealType in
            weeklySlots.first {
                $0.day == todayName && $0.mealType == mealType && !$0.displayTitle.isEmpty
            }
        }
    }

    private var todayCaloriesTotal: Int {
        Int(todaySlots.reduce(0) { partial, slot in
            partial + numericValue(from: slot.plannedRecipe?.calories ?? "")
        }.rounded())
    }

    private var todayPlanSubtitle: String {
        if todaySlots.isEmpty {
            return "No meals are locked in for \(todayName) yet."
        }

        if todayCaloriesTotal > 0 {
            return "\(todaySlots.count) meal\(todaySlots.count == 1 ? "" : "s") lined up for today • about \(todayCaloriesTotal) kcal."
        }

        return "\(todaySlots.count) meal\(todaySlots.count == 1 ? "" : "s") lined up for today."
    }

    private var homeInsight: String {
        if pantryItemCount == 0 {
            return "Scan your pantry once and ChefBuddy can stop guessing what’s actually in your kitchen."
        }
        if savedRecipes.isEmpty {
            return "Save a couple of recipes and Live Cooking gets much more useful on busy nights."
        }
        if todaySlots.isEmpty {
            return "You’ve got the tools ready. A quick day plan makes dinner feel way less random."
        }
        return "Your kitchen is in a good spot today. Keep it simple and cook what already fits the moment."
    }

    private var inspirationSlides: [HomeInspirationSlide] {
        let profile = authVM.currentUserProfile
        let firstCuisine = profile?.cuisines.first
        let firstDiet = profile?.dietTags.first
        let firstAppliance = profile?.appliances.first
        let firstMacro = profile?.macroTags.first
        let pantryPreview = pantrySpaces.flatMap(\.ingredients).prefix(3).joined(separator: ", ")

        var slides: [HomeInspirationSlide] = [
            HomeInspirationSlide(
                id: "ai-idea",
                eyebrow: "AI IDEA FOR YOU",
                title: aiKitchenIdea,
                subtitle: isLoadingKitchenIdea ? "Reading your preferences…" : "Tap to turn this into a complete recipe",
                icon: "sparkles",
                colors: [Color(red: 0.82, green: 0.34, blue: 0.14), Color(red: 0.26, green: 0.35, blue: 0.22)],
                badge: "Personalized",
                opensCreator: true
            ),
            HomeInspirationSlide(
                id: "ai-tip",
                eyebrow: "YOUR KITCHEN COACH",
                title: personalizedKitchenTip,
                subtitle: isLoadingKitchenTip ? "Looking at your pantry and preferences…" : "A practical tip shaped around your kitchen",
                icon: "lightbulb.max.fill",
                colors: [Color(red: 0.27, green: 0.35, blue: 0.24), Color(red: 0.12, green: 0.15, blue: 0.13)],
                badge: "AI kitchen tip"
            ),
            HomeInspirationSlide(
                id: "stats-pantry",
                eyebrow: "YOUR KITCHEN PULSE",
                title: "\(pantryItemCount) ingredients ready • \(savedRecipes.count) recipes saved",
                subtitle: pantryItemCount == 0 ? "Add pantry items to make ChefBuddy more personal." : "Your stocked kitchen is powering smarter ideas.",
                icon: "chart.bar.fill",
                colors: [Color(red: 0.20, green: 0.34, blue: 0.28), Color(red: 0.12, green: 0.15, blue: 0.14)],
                badge: "Your stats"
            ),
            HomeInspirationSlide(
                id: "stats-week",
                eyebrow: "THIS WEEK",
                title: "\(plannedSlotCount) meals planned and ready to cook",
                subtitle: plannedSlotCount == 0 ? "Open Meal Plan to give the week a little shape." : "A little planning now means fewer decisions later.",
                icon: "calendar.badge.checkmark",
                colors: [Color(red: 0.31, green: 0.27, blue: 0.20), Color(red: 0.14, green: 0.14, blue: 0.13)],
                badge: "Momentum"
            ),
            HomeInspirationSlide(
                id: "chef-gordon",
                eyebrow: "GORDON RAMSAY",
                title: "“Home cooking has to be easy. It’s got to be fast. It’s got to be delicious.”",
                subtitle: "A home-cooking rule worth keeping",
                icon: "quote.opening",
                colors: [Color(red: 0.36, green: 0.21, blue: 0.18), Color(red: 0.16, green: 0.12, blue: 0.11)],
                badge: "Chef quote"
            ),
            HomeInspirationSlide(
                id: "chef-jamie",
                eyebrow: "JAMIE OLIVER",
                title: "“My approach has always been about simplifying cooking.”",
                subtitle: "Keep the method clear and let good ingredients work",
                icon: "quote.opening",
                colors: [Color(red: 0.24, green: 0.34, blue: 0.22), Color(red: 0.12, green: 0.15, blue: 0.12)],
                badge: "Chef quote"
            ),
            HomeInspirationSlide(
                id: "chef-keller-memory",
                eyebrow: "THOMAS KELLER",
                title: "“Roasted chicken reminds me of places I’ve been in the past.”",
                subtitle: "A reminder that food carries memory",
                icon: "quote.opening",
                colors: [Color(red: 0.34, green: 0.24, blue: 0.18), Color(red: 0.16, green: 0.13, blue: 0.12)],
                badge: "Chef quote"
            ),
            HomeInspirationSlide(
                id: "chef-keller-sweetness",
                eyebrow: "THOMAS KELLER",
                title: "“Here’s wishing you a little sweetness every day.”",
                subtitle: "A small thought for the pastry-minded cook",
                icon: "birthday.cake.fill",
                colors: [Color(red: 0.38, green: 0.23, blue: 0.27), Color(red: 0.16, green: 0.12, blue: 0.15)],
                badge: "Chef quote"
            ),
            HomeInspirationSlide(
                id: "movie-ratatouille-cook",
                eyebrow: "RATATOUILLE",
                title: "“Anyone can cook, but only the fearless can be great.”",
                subtitle: "Chef Gusteau • Disney and Pixar’s Ratatouille",
                icon: "film.stack.fill",
                colors: [Color(red: 0.25, green: 0.30, blue: 0.38), Color(red: 0.12, green: 0.14, blue: 0.17)],
                badge: "Movie moment"
            ),
            HomeInspirationSlide(
                id: "movie-ratatouille-artist",
                eyebrow: "RATATOUILLE",
                title: "“A great artist can come from anywhere.”",
                subtitle: "Anton Ego • a little courage for tonight’s cook",
                icon: "paintpalette.fill",
                colors: [Color(red: 0.30, green: 0.25, blue: 0.38), Color(red: 0.13, green: 0.12, blue: 0.17)],
                badge: "Movie moment"
            ),
            HomeInspirationSlide(
                id: "movie-tiana",
                eyebrow: "THE PRINCESS AND THE FROG",
                title: "“The only way to get what you want in this world is through hard work.”",
                subtitle: "Tiana • bring the dream to the stove",
                icon: "star.fill",
                colors: [Color(red: 0.20, green: 0.36, blue: 0.30), Color(red: 0.11, green: 0.16, blue: 0.14)],
                badge: "Disney moment"
            ),
            HomeInspirationSlide(
                id: "movie-imagination",
                eyebrow: "BIG HERO 6",
                title: "“The only limit is your imagination.”",
                subtitle: "A good rule for leftovers and weeknight experiments",
                icon: "cloud.fill",
                colors: [Color(red: 0.22, green: 0.31, blue: 0.40), Color(red: 0.11, green: 0.14, blue: 0.18)],
                badge: "Disney moment"
            ),
            HomeInspirationSlide(
                id: "tip-mise",
                eyebrow: "KITCHEN TIP",
                title: "Prep and group every ingredient before the pan gets hot.",
                subtitle: "A calm start makes timing easier and prevents missed ingredients.",
                icon: "square.grid.3x3.fill",
                colors: [Color(red: 0.30, green: 0.27, blue: 0.22), Color(red: 0.14, green: 0.13, blue: 0.12)],
                badge: "Better workflow"
            ),
            HomeInspirationSlide(
                id: "tip-season",
                eyebrow: "KITCHEN TIP",
                title: "Season in small layers, then taste again before serving.",
                subtitle: "It is easier to add than to rescue an over-seasoned dish.",
                icon: "takeoutbag.and.cup.and.straw.fill",
                colors: [Color(red: 0.34, green: 0.27, blue: 0.19), Color(red: 0.15, green: 0.13, blue: 0.11)],
                badge: "Flavor"
            ),
            HomeInspirationSlide(
                id: "tip-acid",
                eyebrow: "KITCHEN TIP",
                title: "If dinner tastes flat, try a small squeeze of acid before more salt.",
                subtitle: "Lemon or vinegar can wake up heavy, rich, or muted flavors.",
                icon: "drop.fill",
                colors: [Color(red: 0.34, green: 0.35, blue: 0.18), Color(red: 0.15, green: 0.15, blue: 0.10)],
                badge: "Flavor"
            ),
            HomeInspirationSlide(
                id: "tip-crowding",
                eyebrow: "KITCHEN TIP",
                title: "Give ingredients room in the pan when you want browning.",
                subtitle: "Crowding traps steam; two quick batches often cook better than one.",
                icon: "square.split.2x2.fill",
                colors: [Color(red: 0.34, green: 0.23, blue: 0.18), Color(red: 0.15, green: 0.12, blue: 0.11)],
                badge: "Technique"
            ),
            HomeInspirationSlide(
                id: "tip-rest",
                eyebrow: "KITCHEN TIP",
                title: "Let cooked proteins rest before slicing.",
                subtitle: "A short pause helps juices settle and keeps the center tender.",
                icon: "timer",
                colors: [Color(red: 0.29, green: 0.25, blue: 0.23), Color(red: 0.13, green: 0.12, blue: 0.12)],
                badge: "Technique"
            ),
            HomeInspirationSlide(
                id: "tip-pasta-water",
                eyebrow: "KITCHEN TIP",
                title: "Save a mug of pasta water before draining.",
                subtitle: "Its starch helps sauce cling and loosen without becoming watery.",
                icon: "mug.fill",
                colors: [Color(red: 0.23, green: 0.29, blue: 0.35), Color(red: 0.11, green: 0.13, blue: 0.16)],
                badge: "Technique"
            ),
            HomeInspirationSlide(
                id: "tip-knife",
                eyebrow: "KITCHEN TIP",
                title: "A sharp knife is more predictable than a dull one.",
                subtitle: "Use a stable board and slow down before trying to speed up.",
                icon: "scissors",
                colors: [Color(red: 0.25, green: 0.27, blue: 0.29), Color(red: 0.12, green: 0.13, blue: 0.14)],
                badge: "Kitchen safety"
            ),
            HomeInspirationSlide(
                id: "tip-leftovers",
                eyebrow: "KITCHEN TIP",
                title: "Turn leftovers into a new format instead of reheating the same plate.",
                subtitle: "Try a bowl, wrap, fried rice, soup, toast, or crisped filling.",
                icon: "arrow.triangle.2.circlepath",
                colors: [Color(red: 0.22, green: 0.34, blue: 0.27), Color(red: 0.11, green: 0.15, blue: 0.13)],
                badge: "Waste less"
            ),
            HomeInspirationSlide(
                id: "tip-freezer",
                eyebrow: "KITCHEN TIP",
                title: "Freeze sauces and herbs in small portions for faster future meals.",
                subtitle: "Label the date so your freezer becomes a shortcut, not a mystery.",
                icon: "snowflake",
                colors: [Color(red: 0.21, green: 0.31, blue: 0.38), Color(red: 0.10, green: 0.14, blue: 0.17)],
                badge: "Meal prep"
            ),
            HomeInspirationSlide(
                id: "partner",
                eyebrow: "PARTNER SPOTLIGHT",
                title: "A clean home for relevant cookware, grocery, and kitchen partner offers.",
                subtitle: "Reserved advertising placement",
                icon: "megaphone.fill",
                colors: [Color(red: 0.22, green: 0.29, blue: 0.34), Color(red: 0.12, green: 0.14, blue: 0.16)],
                badge: "Sponsored"
            )
        ]

        if !pantryPreview.isEmpty {
            slides.append(
                HomeInspirationSlide(
                    id: "personal-pantry",
                    eyebrow: "BASED ON YOUR PANTRY",
                    title: "Build tonight around \(pantryPreview).",
                    subtitle: "Start with what is already open or most perishable, then choose one clear flavor direction.",
                    icon: "basket.fill",
                    colors: [Color(red: 0.20, green: 0.34, blue: 0.25), Color(red: 0.10, green: 0.15, blue: 0.12)],
                    badge: "Personalized tip"
                )
            )
        }

        if let firstCuisine {
            slides.append(
                HomeInspirationSlide(
                    id: "personal-cuisine",
                    eyebrow: "YOUR \(firstCuisine.uppercased()) LANE",
                    title: "Use one familiar \(firstCuisine) flavor anchor, then keep the rest of the plate simple.",
                    subtitle: "Personalized from your cuisine preferences.",
                    icon: "globe.americas.fill",
                    colors: [Color(red: 0.30, green: 0.25, blue: 0.20), Color(red: 0.14, green: 0.12, blue: 0.11)],
                    badge: "Taste profile"
                )
            )
        }

        if let firstDiet {
            slides.append(
                HomeInspirationSlide(
                    id: "personal-diet",
                    eyebrow: "BUILT FOR YOUR PREFERENCES",
                    title: "For \(firstDiet), choose the protein and sauce first—then build the meal around them.",
                    subtitle: "A structure that keeps dietary choices from feeling restrictive.",
                    icon: "leaf.fill",
                    colors: [Color(red: 0.20, green: 0.35, blue: 0.22), Color(red: 0.10, green: 0.15, blue: 0.11)],
                    badge: "Diet-aware"
                )
            )
        }

        if let firstAppliance {
            slides.append(
                HomeInspirationSlide(
                    id: "personal-appliance",
                    eyebrow: "USE WHAT YOU OWN",
                    title: "Let your \(firstAppliance) handle one component while you prep the rest.",
                    subtitle: "Personalized from the appliances saved in your kitchen profile.",
                    icon: "oven.fill",
                    colors: [Color(red: 0.29, green: 0.27, blue: 0.24), Color(red: 0.13, green: 0.13, blue: 0.12)],
                    badge: "Kitchen setup"
                )
            )
        }

        if let firstMacro {
            slides.append(
                HomeInspirationSlide(
                    id: "personal-macro",
                    eyebrow: "YOUR NUTRITION FOCUS",
                    title: "Make \(firstMacro.lowercased()) easier by choosing the anchor ingredient before the recipe.",
                    subtitle: "Personalized from your saved nutrition preferences.",
                    icon: "bolt.heart.fill",
                    colors: [Color(red: 0.35, green: 0.22, blue: 0.24), Color(red: 0.15, green: 0.11, blue: 0.12)],
                    badge: "Goal-aware"
                )
            )
        }

        if let cookTime = profile?.cookTime, !cookTime.isEmpty {
            slides.append(
                HomeInspirationSlide(
                    id: "personal-time",
                    eyebrow: "MATCH YOUR PACE",
                    title: "For your \(cookTime) preference, pick one fast-cooking protein and one pan.",
                    subtitle: "Fewer moving pieces make the time target much more realistic.",
                    icon: "clock.badge.checkmark.fill",
                    colors: [Color(red: 0.25, green: 0.29, blue: 0.34), Color(red: 0.11, green: 0.13, blue: 0.15)],
                    badge: "Time-aware"
                )
            )
        }

        return slides
    }

    private var orderedInspirationSlides: [HomeInspirationSlide] {
        guard !inspirationOrder.isEmpty else { return inspirationSlides }
        let lookup = Dictionary(uniqueKeysWithValues: inspirationSlides.map { ($0.id, $0) })
        return inspirationOrder.compactMap { lookup[$0] } + inspirationSlides.filter { !inspirationOrder.contains($0.id) }
    }

    var body: some View {
        ZStack {
            ChefBuddyBackground()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    greetingSection
                    kitchenInspirationSection
                    liveCookingSection
                    todayPlanSection
                    navigationGridSection
                    insightSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 120)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            greetingText = makeTimeBasedGreeting()
            setupDynamicPrompts()
            startListeners()
            prepareInspirationDeck()
            generateKitchenIdeaIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                generatePersonalizedKitchenTipIfNeeded()
            }
        }
        .onDisappear {
            stopListeners()
        }
        .onReceive(homeCarouselTimer) { _ in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                homeCarouselIndex = (homeCarouselIndex + 1) % max(orderedInspirationSlides.count, 1)
            }
        }
        .onChange(of: pantryItemCount) { _, _ in
            generatePersonalizedKitchenTipIfNeeded()
        }
    }

    private var greetingSection: some View {
        HomeGreetingCard(
            title: greetingText.isEmpty ? makeTimeBasedGreeting() : greetingText,
            subtitle: dailyPrompt
        )
        .padding(.top, 8)
    }

    private var kitchenInspirationSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kitchen inspiration")
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                    Text("A fresh shuffled mix every time you visit")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    prepareInspirationDeck()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shuffle kitchen inspiration")
            }

            TabView(selection: $homeCarouselIndex) {
                ForEach(Array(orderedInspirationSlides.enumerated()), id: \.element.id) { index, slide in
                    Group {
                        if slide.opensCreator {
                            Button(action: onOpenQuickGenerate) {
                                inspirationCard(slide)
                            }
                            .buttonStyle(.plain)
                        } else {
                            inspirationCard(slide)
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 190)
        }
    }

    private func inspirationCard(_ slide: HomeInspirationSlide) -> some View {
        HomeKitchenCarouselCard(
            eyebrow: slide.eyebrow,
            title: slide.title,
            subtitle: slide.subtitle,
            icon: slide.icon,
            colors: slide.colors,
            badge: slide.badge
        )
    }

    private var todayPlanSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("TODAY IN YOUR KITCHEN")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .tracking(0.9)
                            .foregroundStyle(.white.opacity(0.72))
                        Text(todaySlots.isEmpty ? "Make today delicious." : "Your day is taking shape.")
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)

                        Text(todayPlanSubtitle)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                    }

                    Spacer()

                    Text(todayName)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.15), in: Capsule())
                }

                if todaySlots.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Nothing’s planned yet, but ChefBuddy can turn that around fast.")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)

                        Button(action: { selectedTab = .plan }) {
                            Label("Open Meal Plan", systemImage: "calendar.badge.plus")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    LinearGradient(colors: [.orange, .green.opacity(0.88)], startPoint: .leading, endPoint: .trailing)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    VStack(spacing: 12) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(todaySlots, id: \.mealType) { slot in
                                HomeTodayMealCard(slot: slot)
                            }
                        }

                        HStack {
                            if todayCaloriesTotal > 0 {
                                Label("About \(todayCaloriesTotal) kcal planned", systemImage: "bolt.heart.fill")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.82))
                            }

                            Spacer()

                            Button("See full week") {
                                selectedTab = .plan
                            }
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        }
                    }
                }
            }
            .padding(.top, 6)
            .padding(22)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.24, green: 0.22, blue: 0.20), Color(red: 0.13, green: 0.16, blue: 0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 30, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .orange.opacity(0.20), radius: 18, y: 8)
        }
    }

    private var liveCookingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready to cook?")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            VStack(spacing: 12) {
                HomePrimaryActionCard(
                    title: "What’s on Your Mind?",
                    subtitle: "Tell ChefBuddy what you feel like eating and get a complete recipe in one step.",
                    icon: "sparkles",
                    tint: .orange,
                    actionTitle: "Create a Recipe",
                    action: onOpenQuickGenerate
                )

                HomePrimaryActionCard(
                    title: "Live Cooking",
                    subtitle: "Cook a saved recipe—or show ChefBuddy what you have and build a meal together in real time.",
                    icon: "video.fill",
                    tint: .green,
                    actionTitle: "Start Live Cooking",
                    action: onOpenLiveCookingPicker
                )
            }
        }
    }

    private var navigationGridSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jump Into ChefBuddy")
                .font(.system(size: 20, weight: .bold, design: .rounded))

            HomeAmbientIcons()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                HomeNavigationCard(title: "Pantry", subtitle: "Manage ingredients", icon: "basket.fill", accent: .green) {
                    selectedTab = .pantry
                }

                HomeNavigationCard(title: "Recipes", subtitle: "Discover and save", icon: "book.closed.fill", accent: .orange) {
                    selectedTab = .recipes
                }

                HomeNavigationCard(title: "Meal Plan", subtitle: "Shape your week", icon: "calendar", accent: .teal) {
                    selectedTab = .plan
                }

                HomeNavigationCard(title: "Grocery List", subtitle: "What you still need", icon: "cart.fill", accent: .pink) {
                    onOpenGrocery()
                }
            }

            HomeNavigationWideCard(title: "Profile", subtitle: "Preferences, goals, and settings", icon: "person.crop.circle", accent: .blue) {
                selectedTab = .profile
            }
        }
    }

    private var insightSection: some View {
        Text(homeInsight)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineSpacing(4)
            .padding(.horizontal, 2)
    }

    private func generateKitchenIdeaIfNeeded() {
        guard !isLoadingKitchenIdea,
              aiKitchenIdea == "ChefBuddy is finding an idea that fits your kitchen.",
              !userId.isEmpty else { return }

        isLoadingKitchenIdea = true
        let profile = authVM.currentUserProfile
        let cuisineText = profile?.cuisines.prefix(3).joined(separator: ", ") ?? "open"
        let dietText = profile?.dietTags.prefix(3).joined(separator: ", ") ?? "none"
        let pantryPreview = pantrySpaces.flatMap(\.ingredients).prefix(8).joined(separator: ", ")

        Task {
            do {
                let idea = try await assistant.getHelp(question: """
                Give this ChefBuddy user one concise, appealing cooking idea in 16 words or fewer.
                It must be a meal concept, not a full recipe.
                Preferred cuisines: \(cuisineText)
                Dietary preferences: \(dietText)
                Preferred cook time: \(profile?.cookTime ?? "flexible")
                Pantry preview: \(pantryPreview.isEmpty ? "not available" : pantryPreview)
                Return only the idea sentence.
                """)
                await MainActor.run {
                    aiKitchenIdea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
                    isLoadingKitchenIdea = false
                }
            } catch {
                await MainActor.run {
                    aiKitchenIdea = pantryItemCount > 0
                        ? "Turn what is already stocked into a fast, preference-friendly dinner."
                        : "Build a colorful weeknight bowl around your favorite cuisine and protein goal."
                    isLoadingKitchenIdea = false
                }
            }
        }
    }

    private func prepareInspirationDeck() {
        var ids = inspirationSlides.map(\.id).shuffled()
        let lastFirstID = UserDefaults.standard.string(forKey: "chefbuddy.inspiration.lastFirst")

        if ids.count > 1, ids.first == lastFirstID {
            ids.swapAt(0, Int.random(in: 1..<ids.count))
        }

        inspirationOrder = ids
        homeCarouselIndex = 0
        UserDefaults.standard.set(ids.first, forKey: "chefbuddy.inspiration.lastFirst")
        ChefBuddyHaptics.selection()
    }

    private func generatePersonalizedKitchenTipIfNeeded() {
        guard !isLoadingKitchenTip,
              personalizedKitchenTip == "ChefBuddy is preparing a tip for your kitchen.",
              !userId.isEmpty else { return }

        isLoadingKitchenTip = true
        let profile = authVM.currentUserProfile
        let pantryPreview = pantrySpaces.flatMap(\.ingredients).prefix(12).joined(separator: ", ")

        Task {
            do {
                let tip = try await assistant.getHelp(question: """
                Give this home cook one specific, practical kitchen tip in 20 words or fewer.
                Ground it in their actual pantry, equipment, time, dietary needs, or nutrition focus.
                Pantry: \(pantryPreview.isEmpty ? "not stocked yet" : pantryPreview)
                Cuisines: \(profile?.cuisines.joined(separator: ", ") ?? "open")
                Diet: \(profile?.dietTags.joined(separator: ", ") ?? "none")
                Appliances: \(profile?.appliances.joined(separator: ", ") ?? "basic kitchen")
                Cook time: \(profile?.cookTime ?? "flexible")
                Nutrition focus: \(profile?.macroTags.joined(separator: ", ") ?? "balanced")
                Return only the tip. Do not use quotation marks.
                """)
                await MainActor.run {
                    personalizedKitchenTip = tip.trimmingCharacters(in: .whitespacesAndNewlines)
                    isLoadingKitchenTip = false
                }
            } catch {
                await MainActor.run {
                    personalizedKitchenTip = pantryItemCount > 0
                        ? "Choose three stocked ingredients first, then add one sauce and one texture for a focused meal."
                        : "Save your appliances and pantry staples so ChefBuddy can make every kitchen tip more specific."
                    isLoadingKitchenTip = false
                }
            }
        }
    }

    private func makeTimeBasedGreeting() -> String {
        let date = Date()
        let hour = Calendar.current.component(.hour, from: date)
        let minute = Calendar.current.component(.minute, from: date)

        switch (hour, minute) {
        case (0...2, _), (3, 0...30):
            return [
                "Midnight munchies, \(displayName)? 🦉",
                "Late night cravings, \(displayName)? 🌙",
                "Fueling the midnight oil, \(displayName)? 🍜"
            ].randomElement() ?? "Late night snack, \(displayName)?"
        case (3...11, _):
            return [
                "Rise and shine, Chef \(displayName)! 🍳",
                "Let's get this bread, \(displayName). 🍞",
                "Time to fuel up for the day, \(displayName). ☕️"
            ].randomElement() ?? "Good morning, \(displayName)!"
        case (12...16, _):
            return [
                "Lunchtime cravings, \(displayName)? 🌮",
                "Midday fuel, \(displayName)? 🥗",
                "Let’s cook up a midday masterpiece, \(displayName). 🧑‍🍳"
            ].randomElement() ?? "Good afternoon, \(displayName)!"
        default:
            return [
                "What's on the dinner menu, \(displayName)? 🥘",
                "Time to unwind and dine, \(displayName). 🍽️",
                "Let's cook up something cozy tonight, \(displayName). 🍲"
            ].randomElement() ?? "Good evening, \(displayName)!"
        }
    }

    private func setupDynamicPrompts() {
        let prompts = [
            "Ready to whip up something tasty? 🍳",
            "What's on the menu today? 🌮",
            "Time to make some magic in the kitchen! ✨",
            "Let's cook up a storm! 🌪️",
            "Hungry for something new? 🤤",
            "Grab your apron, it's cooking time! 👨‍🍳"
        ]

        dailyPrompt = prompts.randomElement() ?? prompts[0]
    }

    private func startListeners() {
        guard !userId.isEmpty else { return }

        stopListeners()

        pantryListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("pantrySpaces")
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }
                DispatchQueue.main.async {
                    pantrySpaces = documents.compactMap { document in
                        let data = document.data()
                        let name = data["name"] as? String ?? "Pantry"
                        let emoji = data["emoji"] as? String ?? "🥑"
                        let colorTheme = data["colorTheme"] as? String ?? "Orange"
                        let virtualPantry = data["virtualPantry"] as? [String: [String]] ?? [:]
                        return SimplePantrySpace(
                            id: document.documentID,
                            name: name,
                            emoji: emoji,
                            ingredients: virtualPantry.values.flatMap { $0 },
                            colorTheme: colorTheme
                        )
                    }.sorted { $0.name < $1.name }
                }
            }

        mealPlanListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("mealPlan")
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }
                DispatchQueue.main.async {
                    weeklySlots = documents.compactMap { try? $0.data(as: MealPlanSlot.self) }
                }
            }

    }

    private func stopListeners() {
        pantryListener?.remove()
        pantryListener = nil
        mealPlanListener?.remove()
        mealPlanListener = nil
    }

    private func numericValue(from raw: String) -> Double {
        guard let range = raw.range(of: #"[-+]?\d*\.?\d+"#, options: .regularExpression) else {
            return 0
        }
        return Double(raw[range]) ?? 0
    }

}

private struct HomeKitchenCarouselCard: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let icon: String
    let colors: [Color]
    let badge: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: icon)
                .font(.system(size: 88, weight: .bold))
                .foregroundStyle(.white.opacity(0.12))
                .offset(x: 14, y: -8)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(eyebrow)
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(0.8)
                    Spacer()
                    Text(badge)
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .foregroundStyle(.white.opacity(0.78))

                Spacer(minLength: 2)

                Text(title)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.82)
                    .multilineTextAlignment(.leading)

                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(2)
            }
            .padding(19)
        }
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .leading)
        .background(
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 27, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: (colors.first ?? .orange).opacity(0.18), radius: 16, y: 8)
    }
}

private struct HomeTodayMealCard: View {
    let slot: MealPlanSlot

    private var icon: String {
        switch slot.mealType {
        case "Breakfast": return "sunrise.fill"
        case "Lunch": return "sun.max.fill"
        default: return "moon.stars.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text(slot.plannedRecipe?.emoji ?? "🍽️")
                    .font(.system(size: 20))
            }
            Text(slot.mealType.uppercased())
                .font(.system(size: 8, weight: .black, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.64))
            Text(slot.displayTitle)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(minHeight: 33, alignment: .top)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .padding(13)
        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }
}

private struct HomePrimaryActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 52, height: 52)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    Spacer(minLength: 4)
                }

                HStack {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.96), in: Capsule())

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                        .background(tint.opacity(0.12), in: Circle())
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.20), tint.opacity(0.05), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(tint.opacity(0.24), lineWidth: 1)
            )
            .shadow(color: tint.opacity(0.16), radius: 14, y: 8)
        }
        .buttonStyle(.plain)
    }
}

struct RecipesTabRootView: View {
    @ObservedObject var assistant: CookingAssistant
    let savedRecipes: [Recipe]
    let onOpenLiveCookingPicker: () -> Void

    var body: some View {
        RecipesView(
            assistant: assistant,
            savedRecipes: savedRecipes,
            onOpenLiveCookingPicker: onOpenLiveCookingPicker
        )
    }
}

struct PantryTabRootView: View {
    @EnvironmentObject private var authVM: AuthViewModel
    @ObservedObject var assistant: CookingAssistant
    let onOpenGrocery: () -> Void

    @State private var availablePantries: [SimplePantrySpace] = []
    @State private var selectedPantryId: String? = nil
    @State private var pantryListener: ListenerRegistration? = nil
    @State private var showVirtualPantry = false
    @State private var heroVariant = Int.random(in: 0..<3)
    @State private var heroMetricIndex = 0
    @State private var showPantryHelp = false
    private let pantryHeroTimer = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    private var currentPantry: SimplePantrySpace? {
        availablePantries.first(where: { $0.id == selectedPantryId })
    }

    var body: some View {
        ZStack {
            ChefBuddyBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    pantryHeader
                    pantryHelpLink
                    if availablePantries.isEmpty {
                        pantryEmptyState
                    } else {
                        simplifiedPantryOverview
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 120)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            heroVariant = Int.random(in: 0..<3)
            startListening()
        }
        .onDisappear {
            stopListening()
        }
        .onChange(of: selectedPantryId) { pantryId in
            authVM.updateActivePantrySelection(pantryId)
        }
        .onChange(of: authVM.currentUserProfile?.activePantryId) { pantryId in
            guard pantryId != selectedPantryId else { return }
            if let pantryId,
               availablePantries.contains(where: { $0.id == pantryId }) {
                selectedPantryId = pantryId
            } else if pantryId == nil {
                selectedPantryId = availablePantries.first?.id
            }
        }
        .navigationDestination(isPresented: $showVirtualPantry) {
            VirtualPantryView(assistant: assistant)
                .environmentObject(authVM)
        }
        .sheet(isPresented: $showPantryHelp) {
            InfoMessageSheet(
                title: "How Pantry works",
                message: "Swipe between pantry spaces, scan shelves, or add items manually. ChefBuddy uses the active space for pantry-first recipes, missing-ingredient checks, grocery planning, and beginner-friendly cooking guidance."
            )
        }
        .onReceive(pantryHeroTimer) { _ in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                heroMetricIndex = (heroMetricIndex + 1) % pantryHeroMetrics.count
            }
        }
    }

    private var pantryHeader: some View {
        let titles = [
            "Know what’s ready\nto become dinner.",
            "Your shelves have\na smarter next move.",
            "Waste less.\nCook with context."
        ]
        let eyebrows = ["YOUR KITCHEN INVENTORY", "PANTRY INTELLIGENCE", "STOCKED AND READY"]
        let icons = ["basket.fill", "sparkles", "leaf.fill"]
        let gradients: [[Color]] = [
            [Color(red: 0.08, green: 0.42, blue: 0.30), Color(red: 0.10, green: 0.67, blue: 0.55)],
            [Color(red: 0.07, green: 0.32, blue: 0.29), Color(red: 0.13, green: 0.56, blue: 0.48)],
            [Color(red: 0.14, green: 0.38, blue: 0.24), Color(red: 0.35, green: 0.62, blue: 0.36)]
        ]
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(eyebrows[heroVariant])
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.72))
                    Text(titles[heroVariant])
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineSpacing(-3)
                }
                Spacer()
                Image(systemName: icons[heroVariant])
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            }

            let metric = pantryHeroMetrics[heroMetricIndex % pantryHeroMetrics.count]
            HStack(spacing: 14) {
                Image(systemName: metric.icon)
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.value)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(metric.label.uppercased())
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(.white.opacity(0.68))
                }
                Spacer()
            }
            .id(heroMetricIndex)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .padding(14)
            .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(21)
        .background(
            LinearGradient(colors: gradients[heroVariant], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .shadow(color: .green.opacity(0.20), radius: 18, y: 9)
    }

    private var pantryHelpLink: some View {
        Button {
            showPantryHelp = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.mint)
                Text("How ChefBuddy uses your pantry")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var pantryHeroMetrics: [(value: String, label: String, icon: String)] {
        let total = availablePantries.reduce(0) { $0 + $1.ingredients.count }
        let fullest = availablePantries.max { $0.ingredients.count < $1.ingredients.count }
        let average = availablePantries.isEmpty ? 0 : total / availablePantries.count
        return [
            ("\(availablePantries.count)", "Kitchen spaces", "square.stack.3d.up.fill"),
            ("\(total)", "Ingredients tracked", "leaf.fill"),
            (currentPantry?.name ?? "No space", "Active pantry", "basket.fill"),
            (fullest.map { "\($0.emoji) \($0.name)" } ?? "Not yet", "Most stocked space", "chart.bar.fill"),
            ("\(average)", "Average items per space", "equal.circle.fill")
        ]
    }

    private func pantryHeroMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.system(size: 8, weight: .black, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.68))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var pantryEmptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("No pantry spaces yet")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("Create your first pantry space, scan what you have, and ChefBuddy will stop guessing what’s actually in the kitchen.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineSpacing(3)

            Button(action: { showVirtualPantry = true }) {
                Label("Set Up Pantry", systemImage: "basket.fill")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var simplifiedPantryOverview: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Pantry spaces")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(availablePantries) { pantry in
                        Button {
                            ChefBuddyHaptics.selection()
                            selectedPantryId = pantry.id
                        } label: {
                            HStack(spacing: 9) {
                                Text(pantry.emoji)
                                    .font(.system(size: 22))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pantry.name)
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .lineLimit(1)
                                    Text("\(pantry.ingredients.count) stocked")
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .opacity(0.72)
                                }
                                Spacer(minLength: 0)
                                if selectedPantryId == pantry.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 14, weight: .bold))
                                }
                            }
                            .foregroundStyle(selectedPantryId == pantry.id ? .white : .primary)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(
                                selectedPantryId == pantry.id
                                    ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.10, green: 0.54, blue: 0.38), .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Color.primary.opacity(0.045)),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let pantry = currentPantry {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ACTIVE SPACE")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(.green)
                        Text("\(pantry.emoji) \(pantry.name)")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                    }
                    Spacer()
                    Text("\(pantry.ingredients.count)")
                        .font(.system(size: 25, weight: .heavy, design: .rounded))
                        .foregroundStyle(.green)
                    Text("items")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if pantry.ingredients.isEmpty {
                    Text("This pantry is empty. Scan a shelf or add a few ingredients to start getting pantry-aware recipes.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                } else {
                    Text("Recently stocked")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    FlexibleTagWrap(items: Array(pantry.ingredients.prefix(8))) { ingredient in
                        Text(ingredient)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }

                    if pantry.ingredients.count > 8 {
                        Text("+ \(pantry.ingredients.count - 8) more")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button(action: { showVirtualPantry = true }) {
                Label("Manage Pantry", systemImage: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(action: onOpenGrocery) {
                Label("Open Grocery List", systemImage: "cart.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var pantryControlHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shopping From")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Set the pantry ChefBuddy should use for pantry checks and grocery planning.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                pantryPickerMenu
            }

            if let pantry = currentPantry {
                HStack(spacing: 8) {
                    Label("Using \(pantry.emoji) \(pantry.name)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                    Spacer()
                    Text("\(pantry.ingredients.count) items")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var pantryPickerMenu: some View {
        Menu {
            ForEach(availablePantries) { pantry in
                Button {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    selectedPantryId = pantry.id
                } label: {
                    HStack {
                        Text("\(pantry.emoji) \(pantry.name)")
                        if pantry.id == selectedPantryId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(currentPantry.map { "\($0.emoji) \($0.name)" } ?? "Select Pantry")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var pantrySection: some View {
        Group {
            if let pantry = currentPantry {
                activePantryCard(for: pantry)
            }
        }
    }

    private func activePantryCard(for pantry: SimplePantrySpace) -> some View {
        let previewIngredients = Array(pantry.ingredients.prefix(6))
        let remaining = max(0, pantry.ingredients.count - previewIngredients.count)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Pantry Overview")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("\(pantry.emoji) \(pantry.name)")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))

                    Text("\(pantry.ingredients.count) ingredient\(pantry.ingredients.count == 1 ? "" : "s") ready to compare against your recipes.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Button(action: { showVirtualPantry = true }) {
                    Label("Open Pantry", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }

            if previewIngredients.isEmpty {
                Text("This pantry is still empty. Open Manage Pantry to scan shelves or add ingredients manually.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick pantry preview")
                        .font(.system(size: 14, weight: .bold, design: .rounded))

                    FlexibleTagWrap(items: previewIngredients) { ingredient in
                        Text(ingredient)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }

                    if remaining > 0 {
                        Text("and \(remaining) more")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.green.opacity(0.35), lineWidth: 1.5)
        )
        .shadow(color: Color.green.opacity(0.10), radius: 12, y: 6)
    }

    private var grocerySection: some View {
        Button(action: onOpenGrocery) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Grocery List")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                        Text("Open the list ChefBuddy builds from recipe gaps and pantry checks, then shop with the active pantry already in mind.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 10)

                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.orange.opacity(0.14))
                            .frame(width: 54, height: 54)

                        Image(systemName: "cart.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 10) {
                    pantryUtilityPill(
                        title: currentPantry.map { "\($0.emoji) \($0.name)" } ?? "No pantry",
                        systemImage: "basket.fill",
                        tint: .green
                    )
                    pantryUtilityPill(
                        title: "Missing-item aware",
                        systemImage: "checklist",
                        tint: .orange
                    )
                }

                HStack {
                    Text("Review what is missing, mark items off, and move faster when it is time to shop.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func pantryUtilityPill(title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func startListening() {
        guard let userId = authVM.userSession?.uid else { return }

        stopListening()

        pantryListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("pantrySpaces")
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }

                let spaces = documents.compactMap { document -> SimplePantrySpace? in
                    let data = document.data()
                    let name = data["name"] as? String ?? "Pantry"
                    let emoji = data["emoji"] as? String ?? "🥑"
                    let colorTheme = data["colorTheme"] as? String ?? "Orange"
                    let pantry = data["virtualPantry"] as? [String: [String]] ?? [:]
                    return SimplePantrySpace(
                        id: document.documentID,
                        name: name,
                        emoji: emoji,
                        ingredients: pantry.values.flatMap { $0 },
                        colorTheme: colorTheme
                    )
                }.sorted { $0.name < $1.name }

                DispatchQueue.main.async {
                    availablePantries = spaces

                    let preferredPantryId = authVM.currentUserProfile?.activePantryId
                    if let selectedPantryId,
                       spaces.contains(where: { $0.id == selectedPantryId }) == false {
                        self.selectedPantryId = nil
                    }

                    if self.selectedPantryId == nil,
                       let preferredPantryId,
                       spaces.contains(where: { $0.id == preferredPantryId }) {
                        self.selectedPantryId = preferredPantryId
                    } else if self.selectedPantryId == nil {
                        self.selectedPantryId = spaces.first?.id
                    }
                }
            }
    }

    private func stopListening() {
        pantryListener?.remove()
        pantryListener = nil
    }
}

struct PlanTabRootView: View {
    @ObservedObject var assistant: CookingAssistant

    var body: some View {
        WeeklyMealPlanView(assistant: assistant)
    }
}

struct ProfileTabRootView: View {
    var body: some View {
        ProfileHubView()
    }
}

private struct FloatingShellTabBar: View {
    @Binding var selectedTab: AppTab

    private let primaryItems: [(AppTab, String, String)] = [
        (.plan, "calendar", "Plan"),
        (.pantry, "basket.fill", "Pantry"),
        (.home, "house.fill", "Home"),
        (.recipes, "book.closed.fill", "Recipes")
    ]

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(primaryItems, id: \.0) { item in
                    tabButton(item)
                }
            }
            .padding(6)
            .background(Color.black.opacity(0.88), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))

            Button {
                select(.profile)
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(
                        selectedTab == .profile ? Color.white.opacity(0.20) : Color.black.opacity(0.88),
                        in: Circle()
                    )
                    .overlay(Circle().stroke(Color.white.opacity(selectedTab == .profile ? 0.30 : 0.16), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
        }
        .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
    }

    private func tabButton(_ item: (AppTab, String, String)) -> some View {
        let isSelected = selectedTab == item.0
        return Button {
            select(item.0)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.1)
                    .font(.system(size: 17, weight: .semibold))
                Text(item.2)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(isSelected ? 1 : 0.62))
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(isSelected ? Color.white.opacity(0.17) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func select(_ tab: AppTab) {
        guard selectedTab != tab else {
            ChefBuddyHaptics.light()
            return
        }
        ChefBuddyHaptics.selection()
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            selectedTab = tab
        }
    }
}

private struct HomeAmbientIcons: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 10) {
            ambientPill(symbol: "sparkles", accent: .orange, delay: 0.0)
            ambientPill(symbol: "fork.knife", accent: .green, delay: 0.14)
            ambientPill(symbol: "flame.fill", accent: .pink, delay: 0.28)
        }
        .onAppear {
            animate = true
        }
    }

    private func ambientPill(symbol: String, accent: Color, delay: Double) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(accent.opacity(0.12), in: Capsule())
            .offset(y: animate ? -2 : 2)
            .animation(
                .easeInOut(duration: 1.8)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: animate
            )
    }
}

private struct HomeGreetingCard: View {
    let title: String
    let subtitle: String

    @State private var animateIcon = false
    @State private var animateContent = false
    @State private var homeIconIndex = 0
    @State private var iconTimer: Timer?

    private let rotatingIcons = ["house.fill", "fork.knife.circle.fill", "sparkles", "sun.max.fill"]

    private var activeIcon: String {
        rotatingIcons[homeIconIndex % rotatingIcons.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                HomeAmbientIcons()

                Spacer(minLength: 10)

                HStack(spacing: 8) {
                    Image("ChefBuddyLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)

                    Text("ChefBuddy")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }

            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.orange.opacity(0.18), .green.opacity(0.12), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 62, height: 62)

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.orange.opacity(0.10))
                        .frame(width: 52, height: 52)

                    Image(systemName: activeIcon)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.orange)
                        .offset(y: animateIcon ? -1 : 1)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: activeIcon)
                }
                .frame(width: 72, height: 72, alignment: .center)

                VStack(alignment: .leading, spacing: 5) {
                    Text("YOUR KITCHEN, IN MOTION")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.orange)

                    Text(title)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .lineSpacing(1)
                        .lineLimit(2)
                        .minimumScaleFactor(0.68)
                        .allowsTightening(true)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: animateContent ? 0 : 6)
                .opacity(animateContent ? 1 : 0.72)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .background(
            LinearGradient(
                colors: [Color.orange.opacity(0.12), Color.primary.opacity(0.025), Color.green.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(
                    LinearGradient(colors: [.orange.opacity(0.32), .green.opacity(0.20)], startPoint: .leading, endPoint: .trailing),
                    lineWidth: 1
                )
        )
        .shadow(color: .orange.opacity(0.08), radius: 18, y: 9)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                animateIcon = true
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.84).delay(0.05)) {
                animateContent = true
            }
            if iconTimer == nil {
                iconTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { _ in
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        homeIconIndex = (homeIconIndex + 1) % rotatingIcons.count
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

private struct TodayPlanRow: View {
    let slot: MealPlanSlot

    private var iconName: String {
        switch slot.mealType.lowercased() {
        case "breakfast":
            return "sunrise.fill"
        case "lunch":
            return "sun.max.fill"
        default:
            return "moon.stars.fill"
        }
    }

    private var accent: Color {
        switch slot.mealType.lowercased() {
        case "breakfast":
            return .orange
        case "lunch":
            return .green
        default:
            return .blue
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.14))
                    .frame(width: 38, height: 38)

                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(slot.mealType)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(slot.displayTitle)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(2)
            }

            Spacer(minLength: 10)

            if let plannedRecipe = slot.plannedRecipe,
               !plannedRecipe.calories.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(plannedRecipe.calories)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(accent.opacity(0.10), in: Capsule())
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct HomeNavigationCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(accent.opacity(0.14))
                            .frame(width: 44, height: 44)

                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(accent)
                    }

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))

                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 132, alignment: .topLeading)
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct HomeNavigationWideCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(0.14))
                        .frame(width: 44, height: 44)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PantrySecondaryActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct FlexibleTagWrap<Content: View>: View {
    let items: [String]
    let content: (String) -> Content

    var body: some View {
        let columns = [
            GridItem(.adaptive(minimum: 120), alignment: .leading)
        ]

        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                content(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
