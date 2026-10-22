import SwiftUI
import FirebaseFirestore
import FirebaseAuth
import Combine

private enum ProfileHubTab: String, CaseIterable, Identifiable {
    case profile = "Profile"
    case cookbook = "Cookbook"
    case journey = "Journey"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .profile: return "person.crop.circle.fill"
        case .cookbook: return "fork.knife.circle.fill"
        case .journey: return "sparkles"
        }
    }

    var gradient: [Color] {
        switch self {
        case .profile: return [.orange, Color(red: 0.97, green: 0.72, blue: 0.30)]
        case .cookbook: return [.green, Color(red: 0.34, green: 0.78, blue: 0.48)]
        case .journey: return [Color(red: 0.35, green: 0.53, blue: 0.98), Color(red: 0.58, green: 0.43, blue: 0.92)]
        }
    }

    var accent: Color {
        gradient.first ?? .orange
    }
}

private enum SimplifiedProfileTab: String, CaseIterable, Identifiable {
    case cookbook = "Cookbook"
    case journey = "Journey"
    case gallery = "Gallery"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cookbook: return "fork.knife.circle.fill"
        case .journey: return "sparkles"
        case .gallery: return "photo.stack.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .cookbook: return "Recipes"
        case .journey: return "Progress"
        case .gallery: return "Memories"
        }
    }
}

private struct ProfileGalleryMemory: Identifiable {
    let id: String
    let downloadURL: String
    let recipeTitle: String
    let recipeEmoji: String
    let createdAt: Date
}

private enum ProfileAchievementCategory: String, CaseIterable, Identifiable {
    case consistency = "Consistency"
    case cooking = "Cooking"
    case discovery = "Discovery"
    case profile = "Profile"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .consistency: return "calendar.badge.clock"
        case .cooking: return "fork.knife.circle"
        case .discovery: return "sparkles"
        case .profile: return "person.crop.circle.badge.checkmark"
        }
    }
}

private struct ProfileFeedbackBanner: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let tint: Color
}

struct ProfileHubView: View {
    @EnvironmentObject private var authVM: AuthViewModel
    @StateObject private var assistant = CookingAssistant()

    @State private var selectedTab: ProfileHubTab = .profile
    @State private var showEditPreferences = false
    @State private var showProfileDetails = false
    @State private var showBadgeVault = false
    @State private var showRankRoadmap = false
    @State private var handleText = ""
    @State private var bioText = ""
    @State private var isSavingIdentity = false
    @State private var isResettingDiscovery = false
    @State private var showDiscoveryResetConfirm = false
    @State private var achievements: [AchievementBadge] = []
    @State private var recipes: [Recipe] = []
    @State private var selectedRecipe: Recipe? = nil
    @State private var selectedAchievement: AchievementBadge? = nil
    @State private var recipesListener: ListenerRegistration? = nil
    @State private var achievementListener: ListenerRegistration? = nil
    @State private var galleryListener: ListenerRegistration? = nil
    @State private var galleryMemories: [ProfileGalleryMemory] = []
    @State private var userProfileListener: ListenerRegistration? = nil
    @State private var seededAchievementCelebrations = false
    @State private var isLoadingAchievements = true
    @State private var highlightedAchievement: AchievementBadge? = nil
    @State private var feedbackBanner: ProfileFeedbackBanner? = nil
    @State private var profileCardGlow = false
    @State private var xpChipPulse = false
    @State private var simplifiedTab: SimplifiedProfileTab = .cookbook
    @State private var snapshotIndex = 0
    @Namespace private var simplifiedTabNamespace
    private let snapshotTimer = Timer.publish(every: 3.4, on: .main, in: .common).autoconnect()

    private let db = Firestore.firestore()

    private var userId: String { authVM.userSession?.uid ?? "" }
    private var accountName: String {
        if let displayName = authVM.userSession?.displayName,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }
        return authVM.userSession?.email?.split(separator: "@").first.map(String.init) ?? "Chef"
    }

    private var displayHandle: String {
        let trimmed = handleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return "@\(trimmed.lowercased().replacingOccurrences(of: " ", with: ""))"
        }
        if let email = authVM.currentUserProfile?.email {
            return "@\(String(email.split(separator: "@").first ?? "chefbuddy"))"
        }
        return "@chefbuddy"
    }

    private var profileBio: String {
        let trimmed = bioText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "Keep your profile polished, track your momentum, and shape a kitchen identity ChefBuddy can learn from."
            : trimmed
    }

    private var derivedXPFromStats: Int {
        let stats = achievementStats
        let planAdd = stats[ActivityEventType.planAdd.rawValue, default: 0] * 6
        let planComplete = stats[ActivityEventType.planComplete.rawValue, default: 0] * 20
        let mealLogged = stats[ActivityEventType.mealLogged.rawValue, default: 0] * 14
        let swipeSave = stats[ActivityEventType.swipeSave.rawValue, default: 0] * 8
        let swipeSkip = stats[ActivityEventType.swipeSkip.rawValue, default: 0] * 2
        let recipeCooked = stats[ActivityEventType.recipeCooked.rawValue, default: 0] * 24
        return planAdd + planComplete + mealLogged + swipeSave + swipeSkip + recipeCooked
    }

    private var xpTotal: Int {
        let storedXP = authVM.currentUserProfile?.xpTotal ?? 0
        return max(storedXP, derivedXPFromStats)
    }

    private var rankProgress: (current: RankTier, next: RankTier?, progress: Double) {
        RankTier.progress(forXP: xpTotal)
    }

    private var joinedDateLabel: String {
        guard let joined = authVM.currentUserProfile?.dateCreated as Date? else { return "Joined recently" }
        return "Joined \(joined.formatted(.dateTime.month(.wide).year()))"
    }

    private var cookedCount: Int {
        recipes.reduce(0) { $0 + $1.cookedCount }
    }

    private var cookedRecipeCount: Int {
        recipes.filter { $0.cookedCount > 0 }.count
    }

    private var streakCount: Int {
        authVM.currentUserProfile?.currentStreak ?? 0
    }

    private var longestStreak: Int {
        authVM.currentUserProfile?.longestStreak ?? 0
    }

    private var streakStatus: (title: String, subtitle: String, tint: Color) {
        guard let lastDate = authVM.currentUserProfile?.lastStreakActivityDate else {
            return ("Start your streak", "Cook a recipe, complete a planned meal, or log a meal today.", .orange)
        }

        let calendar = Calendar.current
        if calendar.isDateInToday(lastDate) {
            return ("Today is protected", "Come back tomorrow and complete another kitchen action to keep it moving.", .green)
        }
        if calendar.isDateInYesterday(lastDate) {
            return ("Keep it alive today", "One eligible cooking action today extends your \(max(streakCount, 1))-day streak.", .orange)
        }
        return ("Streak paused", "Complete an eligible cooking action today to start a new run.", .orange)
    }

    private var achievementStats: [String: Int] {
        authVM.currentUserProfile?.activityStats ?? [:]
    }

    private var liveCookingTimeLabel: String {
        usageDurationLabel(seconds: achievementStats[ChefBuddyUsageMetric.liveCookingSeconds.rawValue, default: 0])
    }

    private var recipeViewingTimeLabel: String {
        usageDurationLabel(seconds: achievementStats[ChefBuddyUsageMetric.recipeViewingSeconds.rawValue, default: 0])
    }

    private func usageDurationLabel(seconds: Int) -> String {
        if seconds < 60 { return seconds == 0 ? "0 min" : "<1 min" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours) hr" : "\(hours)h \(remainingMinutes)m"
    }

    private var displayedAchievements: [AchievementBadge] {
        if !achievements.isEmpty {
            return achievements
        }

        let maxCookedCount = recipes.map(\.cookedCount).max() ?? 0
        let distinctCuisineCount: Int = {
            var cuisines: Set<String> = []
            for recipe in recipes {
                for tag in recipe.tags {
                    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    cuisines.insert(trimmed.lowercased())
                }
            }
            return cuisines.count
        }()

        let swipeDecisionCount = achievementStats[ActivityEventType.swipeSave.rawValue, default: 0]
            + achievementStats[ActivityEventType.swipeSkip.rawValue, default: 0]

        return GrowthEngine.badgeCatalog(
            recipeCount: recipes.count,
            favoriteCount: favoriteRecipesCount,
            maxCookedCount: maxCookedCount,
            distinctCuisineCount: distinctCuisineCount,
            profileCompletionScore: profileCompletionScore,
            swipeDecisionCount: swipeDecisionCount,
            planCompleteCount: achievementStats[ActivityEventType.planComplete.rawValue, default: 0],
            planAddCount: achievementStats[ActivityEventType.planAdd.rawValue, default: 0],
            mealLogCount: achievementStats[ActivityEventType.mealLogged.rawValue, default: 0],
            recipeCookedCount: achievementStats[ActivityEventType.recipeCooked.rawValue, default: 0],
            xp: xpTotal,
            currentStreak: streakCount
        )
    }

    private var unlockedAchievements: [AchievementBadge] {
        displayedAchievements.filter(\.isUnlocked)
    }

    private var recentUnlockedAchievements: [AchievementBadge] {
        unlockedAchievements.sorted { ($0.unlockedAt ?? .distantPast) > ($1.unlockedAt ?? .distantPast) }
    }

    private var topRecipe: Recipe? {
        cookedRecipes.first
    }

    private var sortedRecipesByCooked: [Recipe] {
        recipes.sorted { lhs, rhs in
            if lhs.cookedCount == rhs.cookedCount {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.cookedCount > rhs.cookedCount
        }
    }

    private var favoriteRecipesCount: Int {
        recipes.filter(\.isFavorite).count
    }

    private var favoriteCookedRecipesCount: Int {
        cookedRecipes.filter(\.isFavorite).count
    }

    private var cookedRecipes: [Recipe] {
        sortedRecipesByCooked.filter { $0.cookedCount > 0 }
    }

    private var topCookedRecipes: [Recipe] {
        Array(cookedRecipes.prefix(5))
    }

    private var averageCookRepeatLabel: String {
        guard cookedRecipeCount > 0 else { return "0.0x" }
        let average = Double(cookedCount) / Double(cookedRecipeCount)
        return String(format: "%.1fx", average)
    }

    private var kitchenIdentityTags: [String] {
        var values: [String] = []
        values.append(contentsOf: Array((authVM.currentUserProfile?.cuisines ?? []).prefix(3)))
        values.append(contentsOf: Array((authVM.currentUserProfile?.macroTags ?? []).prefix(2)))
        if let goal = authVM.currentUserProfile?.targetGoal, !goal.isEmpty {
            values.append(goal)
        }

        var deduped: [String] = []
        for value in values where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if deduped.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) == false {
                deduped.append(value)
            }
        }
        return deduped
    }

    private var topCuisineLabel: String {
        let profileCuisines = authVM.currentUserProfile?.cuisines ?? []
        if let first = profileCuisines.first, !first.isEmpty {
            return first
        }

        let cuisineFrequency = recipes
            .flatMap(\.tags)
            .reduce(into: [String: Int]()) { partial, tag in
                let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                partial[trimmed, default: 0] += 1
            }

        return cuisineFrequency.max(by: { $0.value < $1.value })?.key ?? "Still learning"
    }

    private var topCookedCuisineLabel: String {
        let cookedCuisineFrequency = cookedRecipes
            .flatMap(\.tags)
            .reduce(into: [String: Int]()) { partial, tag in
                let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                partial[trimmed, default: 0] += 1
            }

        return cookedCuisineFrequency.max(by: { $0.value < $1.value })?.key ?? "Still building"
    }

    private var nextRankXPRemaining: Int? {
        guard let next = rankProgress.next,
              let target = RankTier.thresholds.first(where: { $0.tier == next })?.minXP else { return nil }
        return max(0, target - xpTotal)
    }

    private var nextAchievementGoals: [AchievementBadge] {
        displayedAchievements
            .filter { !$0.isAtMaxTier }
            .sorted {
                let lhs = $0.tierProgressRatio
                let rhs = $1.tierProgressRatio
                return lhs > rhs
            }
            .prefix(3)
            .map { $0 }
    }

    private var profileCompletionScore: Int {
        var score = 0
        if !(authVM.currentUserProfile?.cuisines.isEmpty ?? true) { score += 1 }
        if !(authVM.currentUserProfile?.macroTags.isEmpty ?? true) { score += 1 }
        if !(authVM.currentUserProfile?.appliances.isEmpty ?? true) { score += 1 }
        if !(authVM.currentUserProfile?.dietTags.isEmpty ?? true) { score += 1 }
        if authVM.currentUserProfile?.nutritionTargets != nil { score += 1 }
        return Int((Double(score) / 5.0 * 100).rounded())
    }

    private var profileScoreCheckpoints: [(title: String, isComplete: Bool)] {
        [
            ("Set a handle", !(authVM.currentUserProfile?.profileHandle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)),
            ("Write a bio", !(authVM.currentUserProfile?.profileBio?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)),
            ("Pick favorite cuisines", !(authVM.currentUserProfile?.cuisines.isEmpty ?? true)),
            ("Set macro goals", !(authVM.currentUserProfile?.macroTags.isEmpty ?? true)),
            ("Add appliances", !(authVM.currentUserProfile?.appliances.isEmpty ?? true))
        ]
    }

    private var groupedAchievements: [(category: ProfileAchievementCategory, badges: [AchievementBadge])] {
        ProfileAchievementCategory.allCases.compactMap { category in
            let badges = displayedAchievements
                .filter { achievementCategory(for: $0) == category }
                .sorted { lhs, rhs in
                    if (lhs.currentTier == rhs.currentTier) { return lhs.title < rhs.title }
                    return (lhs.currentTier != nil) && (rhs.currentTier == nil)
                }

            guard !badges.isEmpty else { return nil }
            return (category, badges)
        }
    }

    private var inProgressAchievementCount: Int {
        displayedAchievements.filter { !$0.isAtMaxTier }.count
    }

    private var bronzeBadgeCount: Int {
        displayedAchievements.filter { $0.currentTier == .bronze }.count
    }

    private var silverBadgeCount: Int {
        displayedAchievements.filter { $0.currentTier == .silver }.count
    }

    private var goldBadgeCount: Int {
        displayedAchievements.filter { $0.currentTier == .gold }.count
    }

    private var platinumBadgeCount: Int {
        displayedAchievements.filter { $0.currentTier == .platinum }.count
    }

    var body: some View {
        simplifiedBody
    }

    private var simplifiedBody: some View {
        ZStack {
            ProfileHubBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    simpleAccountHeader

                    HStack(spacing: 7) {
                        ForEach(SimplifiedProfileTab.allCases) { tab in
                            Button {
                                ChefBuddyHaptics.selection()
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                                    simplifiedTab = tab
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: tab.icon)
                                        .font(.system(size: 13, weight: .bold))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(tab.rawValue)
                                            .font(.system(size: 13, weight: .bold, design: .rounded))
                                        Text(tab.subtitle)
                                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                                            .opacity(0.72)
                                    }
                                }
                                .foregroundStyle(simplifiedTab == tab ? .white : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 11)
                                .background {
                                    if simplifiedTab == tab {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(
                                                tab == .cookbook
                                                    ? LinearGradient(colors: [Color(red: 0.82, green: 0.34, blue: 0.16), Color(red: 0.94, green: 0.66, blue: 0.24)], startPoint: .leading, endPoint: .trailing)
                                                    : tab == .journey
                                                        ? LinearGradient(colors: [.blue, .purple.opacity(0.86)], startPoint: .leading, endPoint: .trailing)
                                                        : LinearGradient(colors: [.pink, .orange.opacity(0.86)], startPoint: .leading, endPoint: .trailing)
                                            )
                                            .matchedGeometryEffect(id: "simplified-profile-tab", in: simplifiedTabNamespace)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    if simplifiedTab == .cookbook {
                        VStack(spacing: 14) {
                            recipeLibrarySummaryCard
                            if let topRecipe {
                                featuredRecipeCard(topRecipe)
                            }
                            topCookedRecipesCard
                        }
                    } else if simplifiedTab == .journey {
                        journeyRedesign
                    } else {
                        profileGallery
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 120)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            startListeners()
            guard !userId.isEmpty else { return }
            Task {
                await assistant.setupAssistant(userId: userId)
                await GrowthEngine.shared.refreshDerivedProgress(userId: userId)
            }
        }
        .onChange(of: simplifiedTab) { _, tab in
            guard tab == .journey, !userId.isEmpty else { return }
            Task { await GrowthEngine.shared.refreshDerivedProgress(userId: userId) }
        }
        .onReceive(snapshotTimer) { _ in
            guard simplifiedTab == .cookbook else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                snapshotIndex = (snapshotIndex + 1) % 12
            }
        }
        .onDisappear {
            userProfileListener?.remove()
            userProfileListener = nil
            recipesListener?.remove()
            recipesListener = nil
            achievementListener?.remove()
            achievementListener = nil
            galleryListener?.remove()
            galleryListener = nil
        }
        .fullScreenCover(isPresented: $showEditPreferences) {
            ProfileSettingsView(showsDismissButton: true, showsSignOutButton: true)
                .environmentObject(authVM)
        }
        .sheet(isPresented: $showBadgeVault) {
            NavigationStack {
                BadgeVaultView(
                    badges: displayedAchievements,
                    displayHandle: accountName,
                    currentRank: rankProgress.current,
                    xpTotal: xpTotal
                )
            }
        }
        .sheet(isPresented: $showRankRoadmap) {
            NavigationStack {
                RankRoadmapView(currentXP: xpTotal)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedRecipe) { recipe in
            RecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                onFavorite: { toggleFavorite(recipe) },
                onDelete: { deleteRecipe(recipe) },
                userId: userId,
                onRecipeUpdated: { updateRecipe($0) },
                onMarkCooked: { markRecipeCooked(recipe) }
            )
        }
        .sheet(item: $selectedAchievement) { badge in
            AchievementCertificateSheet(
                badge: badge,
                currentRank: rankProgress.current,
                xpTotal: xpTotal,
                displayHandle: accountName
            )
        }
    }

    private var simpleAccountHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(colors: [.orange.opacity(0.24), .green.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 68, height: 68)
                    Image("ChefBuddyLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 54, height: 54)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(accountName)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                    Text(authVM.userSession?.email ?? "ChefBuddy account")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("Your private cooking dashboard")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.orange)
                        .textCase(.uppercase)
                }

                Spacer(minLength: 8)

                Button {
                    showEditPreferences = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.orange, in: Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 9) {
                profileHeaderStat(value: "\(xpTotal)", label: "XP", icon: "sparkles", tint: .orange)
                profileHeaderStat(value: "\(streakCount)d", label: "Streak", icon: "flame.fill", tint: .pink)
                profileHeaderStat(value: "\(cookedCount)", label: "Cooks", icon: "fork.knife", tint: .green)
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.orange.opacity(0.13), Color.green.opacity(0.08), Color.primary.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    LinearGradient(colors: [.orange.opacity(0.30), .green.opacity(0.18)], startPoint: .leading, endPoint: .trailing),
                    lineWidth: 1
                )
        )
        .shadow(color: .orange.opacity(0.07), radius: 18, y: 8)
    }

    private func profileHeaderStat(value: String, label: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var journeyRedesign: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                ChefBuddyHaptics.medium()
                showRankRoadmap = true
            } label: {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("YOUR COOKING JOURNEY")
                                .font(.system(size: 10, weight: .black, design: .rounded))
                                .tracking(1)
                                .foregroundStyle(.white.opacity(0.72))
                            Text(rankProgress.current.rawValue)
                                .font(.system(size: 31, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Image(systemName: rankProgress.current.icon)
                            .font(.system(size: 27, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                            .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(xpTotal)")
                            .font(.system(size: 38, weight: .heavy, design: .rounded))
                        Text("XP")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                        Spacer()
                        Text(rankProgress.next.map { "\(nextRankXPRemaining ?? 0) to \($0.rawValue)" } ?? "Highest rank reached")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.80))
                    }
                    .foregroundStyle(.white)

                    ProgressView(value: rankProgress.progress)
                        .tint(.white)
                }
                .padding(21)
                .background(
                    LinearGradient(
                        colors: [rankProgress.current.accent, .purple.opacity(0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 29, style: .continuous)
                )
                .shadow(color: rankProgress.current.accent.opacity(0.24), radius: 18, y: 9)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Kitchen momentum")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                        Text("The habits behind your rank—not just the points.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chart.xyaxis.line")
                        .foregroundStyle(.orange)
                }

                journeyActivityRow(
                    title: "Cooking",
                    detail: "\(achievementStats[ActivityEventType.recipeCooked.rawValue, default: 0]) completed sessions",
                    value: min(Double(achievementStats[ActivityEventType.recipeCooked.rawValue, default: 0]) / 12.0, 1),
                    tint: .orange
                )
                journeyActivityRow(
                    title: "Planning",
                    detail: "\(achievementStats[ActivityEventType.planAdd.rawValue, default: 0]) meals placed",
                    value: min(Double(achievementStats[ActivityEventType.planAdd.rawValue, default: 0]) / 21.0, 1),
                    tint: .green
                )
                journeyActivityRow(
                    title: "Discovery",
                    detail: "\(achievementStats[ActivityEventType.swipeSave.rawValue, default: 0] + achievementStats[ActivityEventType.swipeSkip.rawValue, default: 0]) taste decisions",
                    value: min(Double(achievementStats[ActivityEventType.swipeSave.rawValue, default: 0] + achievementStats[ActivityEventType.swipeSkip.rawValue, default: 0]) / 30.0, 1),
                    tint: .purple
                )
            }
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            nextUnlocksCard

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Badge collection")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                        Text("\(unlockedAchievements.count) unlocked • \(inProgressAchievementCount) still climbing")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Vault") { showBadgeVault = true }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(displayedAchievements.prefix(8))) { badge in
                            Button {
                                selectedAchievement = badge
                            } label: {
                                VStack(spacing: 8) {
                                    RotatingAchievementBadge(
                                        icon: badge.icon,
                                        tint: badge.isUnlocked ? badge.displayTier.tint : .gray,
                                        isUnlocked: badge.isUnlocked,
                                        size: 68
                                    )
                                    Text(badge.title)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(width: 92, height: 118)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func journeyActivityRow(title: String, detail: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 13) {
            Image(systemName: title == "Cooking" ? "fork.knife" : title == "Planning" ? "calendar.badge.checkmark" : "hand.draw.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 43, height: 43)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text(detail)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(tint)
                }
                ProgressView(value: value)
                    .tint(tint)
            }
        }
        .padding(12)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(tint.opacity(0.11), lineWidth: 1)
        )
    }

    private var profileGallery: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color.pink.opacity(0.92), Color.orange.opacity(0.78), Color.purple.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 116, weight: .bold))
                    .foregroundStyle(.white.opacity(0.13))
                    .offset(x: 210, y: -25)

                VStack(alignment: .leading, spacing: 8) {
                    Text("YOUR COOKING GALLERY")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.72))
                    Text(galleryMemories.isEmpty ? "Your next plate can become a memory." : "\(galleryMemories.count) kitchen memories")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Finished dishes, grouped into one personal visual cookbook.")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.84))
                }
                .padding(22)
            }
            .frame(height: 205)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            if galleryMemories.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.pink)
                    Text("Cook a recipe, then add a photo from its Cooking Gallery.")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text("ChefBuddy will collect every finished dish here automatically.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(galleryMemories) { memory in
                        ZStack(alignment: .bottomLeading) {
                            AsyncImage(url: URL(string: memory.downloadURL)) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                } else {
                                    Color.primary.opacity(0.06)
                                        .overlay(ProgressView().tint(.pink))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .clipped()

                            LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(memory.recipeEmoji)
                                Text(memory.recipeTitle)
                                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                Text(memory.createdAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                            .padding(13)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.10)))
                    }
                }
            }
        }
    }

    private var simplifiedJourney: some View {
        VStack(spacing: 14) {
            Button {
                ChefBuddyHaptics.medium()
                showRankRoadmap = true
            } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 13) {
                        Image(systemName: rankProgress.current.icon)
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(rankProgress.current.accent)
                            .frame(width: 48, height: 48)
                            .background(rankProgress.current.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(rankProgress.current.rawValue)
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .foregroundStyle(.primary)
                            Text("\(xpTotal) XP")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(rankProgress.next.map { "\(nextRankXPRemaining ?? 0) XP to \($0.rawValue)" } ?? "Top rank")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                            Label("View rank path", systemImage: "chevron.right")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: rankProgress.progress)
                        .tint(rankProgress.current.accent)
                    Text(rankProgress.current.summary)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(rankProgress.current.accent.opacity(0.16), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                journeyMetric(title: "Current streak", value: "\(streakCount) days", icon: "flame.fill", tint: .orange)
                journeyMetric(title: "Longest streak", value: "\(longestStreak) days", icon: "trophy.fill", tint: .green)
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: streakCount > 0 ? "flame.circle.fill" : "calendar.badge.plus")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(streakStatus.tint)
                    .frame(width: 42, height: 42)
                    .background(streakStatus.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(streakStatus.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(streakStatus.subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Counts: cooked recipes • completed plan meals • meal logs")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(streakStatus.tint)
                }
                Spacer()
            }
            .padding(16)
            .background(streakStatus.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(streakStatus.tint.opacity(0.14), lineWidth: 1)
            )

            nextUnlocksCard

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Badges")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Spacer()
                    Button("View all") { showBadgeVault = true }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(displayedAchievements.prefix(6))) { badge in
                        Button {
                            ChefBuddyHaptics.selection()
                            selectedAchievement = badge
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                RotatingAchievementBadge(
                                    icon: badge.icon,
                                    tint: badge.isUnlocked ? badge.displayTier.tint : .gray,
                                    isUnlocked: badge.isUnlocked,
                                    size: 50
                                )
                                Text(badge.title)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                ProgressView(value: badge.tierProgressRatio)
                                    .tint(badge.isUnlocked ? .orange : .secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                            .padding(13)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private func journeyMetric(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 19, weight: .heavy, design: .rounded))
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var legacyBody: some View {
        ZStack {
            ProfileHubBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    profileHeader
                    profileTabPicker
                    tabContent
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 120)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            bannerRail
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            hydrateIdentityFromProfile()
            startListeners()

            if !userId.isEmpty {
                Task {
                    await assistant.setupAssistant(userId: userId)
                    await GrowthEngine.shared.refreshDerivedProgress(userId: userId)
                }
            }

            guard profileCardGlow == false else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                profileCardGlow = true
            }
        }
        .onChange(of: authVM.currentUserProfile?.profileHandle) { _, _ in
            hydrateIdentityFromProfile()
        }
        .onChange(of: authVM.currentUserProfile?.profileBio) { _, _ in
            hydrateIdentityFromProfile()
        }
        .onChange(of: authVM.currentUserProfile?.xpTotal ?? 0) { _, _ in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                xpChipPulse = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                    xpChipPulse = false
                }
            }
        }
        .onChange(of: recipes) { _, updatedRecipes in
            guard let selectedRecipe, let id = selectedRecipe.id else { return }
            if let fresh = updatedRecipes.first(where: { $0.id == id }) {
                self.selectedRecipe = fresh
            } else {
                self.selectedRecipe = nil
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            guard newTab == .journey, !userId.isEmpty else { return }
            Task {
                await GrowthEngine.shared.refreshDerivedProgress(userId: userId)
            }
        }
        .onDisappear {
            userProfileListener?.remove()
            userProfileListener = nil
            recipesListener?.remove()
            recipesListener = nil
            achievementListener?.remove()
            achievementListener = nil
        }
        .fullScreenCover(isPresented: $showEditPreferences) {
            ProfileSettingsView(showsDismissButton: true, showsSignOutButton: true)
                .environmentObject(authVM)
        }
        .sheet(isPresented: $showProfileDetails) {
            NavigationStack {
                ProfileDetailsSheet(
                    handleText: $handleText,
                    bioText: $bioText,
                    isSavingIdentity: $isSavingIdentity,
                    profileCompletionScore: profileCompletionScore,
                    scoreCheckpoints: profileScoreCheckpoints,
                    onSave: persistIdentity
                )
            }
        }
        .sheet(isPresented: $showBadgeVault) {
            NavigationStack {
                BadgeVaultView(
                    badges: displayedAchievements,
                    displayHandle: accountName,
                    currentRank: rankProgress.current,
                    xpTotal: xpTotal
                )
            }
        }
        .sheet(isPresented: $showRankRoadmap) {
            NavigationStack {
                RankRoadmapView(currentXP: xpTotal)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedRecipe) { recipe in
            RecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                pantryIngredients: [],
                pantrySpaces: [],
                selectedPantryId: authVM.currentUserProfile?.activePantryId,
                onFavorite: { toggleFavorite(recipe) },
                onDelete: { deleteRecipe(recipe) },
                userId: userId,
                onRecipeUpdated: { updateRecipe($0) },
                onMarkCooked: { markRecipeCooked(recipe) }
            )
        }
        .sheet(item: $selectedAchievement) { badge in
            AchievementCertificateSheet(
                badge: badge,
                currentRank: rankProgress.current,
                xpTotal: xpTotal,
                displayHandle: accountName
            )
        }
        .confirmationDialog(
            "Reset AI Suggestions?",
            isPresented: $showDiscoveryResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                resetDiscoverySignals()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ChefBuddy will forget your swipe likes and skips so discovery can feel fresh again.")
        }
    }

    @ViewBuilder
    private var bannerRail: some View {
        if highlightedAchievement != nil || feedbackBanner != nil {
            VStack(spacing: 12) {
                if let highlightedAchievement {
                    ZStack(alignment: .top) {
                        ChefBuddyConfettiView(tint: highlightedAchievement.displayTier.tint)
                            .frame(height: 210)
                            .offset(y: -14)

                        achievementCelebrationBanner(highlightedAchievement)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let feedbackBanner {
                    profileFeedbackBanner(feedbackBanner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(Color.clear)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.orange.opacity(0.22), .green.opacity(0.16)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blur(radius: profileCardGlow ? 24 : 12)
                        .scaleEffect(profileCardGlow ? 1.08 : 0.96)
                        .frame(width: 88, height: 88)

                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .frame(width: 86, height: 86)

                    Image("ChefBuddyLogo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(displayHandle)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(profileBio)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        profileTag(rankProgress.current.rawValue, tint: .orange)
                        profileTag(joinedDateLabel, tint: .blue)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                identityMetricChip(
                    title: "XP",
                    value: "\(xpTotal)",
                    systemImage: "sparkles",
                    tint: .orange,
                    isEmphasized: xpChipPulse
                )
                identityMetricChip(
                    title: "Streak",
                    value: "\(streakCount)d",
                    systemImage: "flame.fill",
                    tint: .pink
                )
                identityMetricChip(
                    title: "Top Flavor",
                    value: topCuisineLabel,
                    systemImage: "fork.knife",
                    tint: .green
                )
            }

            HStack(spacing: 12) {
                dashboardMetricButton(title: "Saved", value: "\(recipes.count)", tint: .orange) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        selectedTab = .cookbook
                    }
                }

                dashboardMetricButton(title: "Cooked", value: "\(cookedCount)", tint: .green) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        selectedTab = .cookbook
                    }
                }

                dashboardMetricButton(title: "Journey", value: "\(unlockedAchievements.count)", tint: .blue) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        selectedTab = .journey
                    }
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var profileTabPicker: some View {
        HStack(spacing: 10) {
            ForEach(ProfileHubTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 12, weight: .bold))
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                        .foregroundStyle(selectedTab == tab ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity)
                        .background(
                            selectedTab == tab
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: tab.gradient,
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                : AnyShapeStyle(Color.primary.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .profile:
            VStack(spacing: 14) {
                profileToolsCard
                profileSnapshotCard
                kitchenIdentityCard
            }
        case .cookbook:
            VStack(spacing: 14) {
                recipeLibrarySummaryCard
                if let topRecipe {
                    featuredRecipeCard(topRecipe)
                }
                topCookedRecipesCard
            }
        case .journey:
            VStack(spacing: 14) {
                achievementOverviewCard
                badgeVaultLauncherCard
                nextUnlocksCard
            }
        }
    }

    private var profileSnapshotCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profile Snapshot")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("A quick read on what your private kitchen profile looks like right now.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                highlightStatTile(
                    title: "Saved Recipes",
                    value: "\(recipes.count)",
                    subtitle: "Everything you can come back to later",
                    systemImage: "books.vertical.fill",
                    tint: .orange
                )

                highlightStatTile(
                    title: "Total Cooks",
                    value: "\(cookedCount)",
                    subtitle: "Every recorded time you finished a recipe",
                    systemImage: "flame.fill",
                    tint: .green
                )

                highlightStatTile(
                    title: "Most Cooked",
                    value: topRecipe?.title ?? "No cooks yet",
                    subtitle: topRecipe.map { "Cooked \($0.cookedCount)x and leading your rotation" } ?? "Cook a saved recipe once to surface a staple",
                    systemImage: "fork.knife.circle.fill",
                    tint: .blue
                )

                highlightStatTile(
                    title: "Favorites",
                    value: "\(favoriteRecipesCount)",
                    subtitle: "The recipes worth protecting in your core list",
                    systemImage: "heart.fill",
                    tint: .pink
                )
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var profileScoreBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profile Score")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Each checkpoint is worth 20%, so completing all five gives you 100%.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(profileCompletionScore)%")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.orange)
            }

            ForEach(profileScoreCheckpoints, id: \.title) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(item.isComplete ? .green : .secondary)

                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))

                    Spacer()

                    Text(item.isComplete ? "Done" : "Missing")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(item.isComplete ? .green : .secondary)
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

    private var kitchenIdentityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kitchen Identity")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("ChefBuddy uses these signals to keep recipes aligned with how you actually cook.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Refine") {
                    showEditPreferences = true
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
            }

            if kitchenIdentityTags.isEmpty {
                Text("Add cuisines, macro goals, and more preferences so ChefBuddy can shape your cooking identity.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                    ForEach(kitchenIdentityTags, id: \.self) { tag in
                        HStack(spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.orange)
                            Text(tag)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
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

    private var profileToolsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Profile Tools")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("The core actions that keep your profile and recommendations feeling sharp.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                profileToolAction(
                    title: "Profile Details",
                    subtitle: "Handle and bio",
                    systemImage: "pencil.line",
                    tint: .green
                ) {
                    showProfileDetails = true
                }

                profileToolAction(
                    title: "Preferences",
                    subtitle: "Taste and goals",
                    systemImage: "slider.horizontal.3",
                    tint: .orange
                ) {
                    showEditPreferences = true
                }
            }

            Button {
                showDiscoveryResetConfirm = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.purple.opacity(0.14))
                            .frame(width: 40, height: 40)

                        if isResettingDiscovery {
                            ProgressView()
                                .tint(.purple)
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.purple)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isResettingDiscovery ? "Resetting AI suggestions" : "Reset AI Suggestions")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("Clear recent swipe signals and let discovery start fresh.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isResettingDiscovery)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var recipeLibrarySummaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cookbook Snapshot")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                    Text("A living view of the recipes that have made it to your table.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 38, height: 38)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }

            TabView(selection: $snapshotIndex) {
                    snapshotCarouselTile(
                        title: "Cooked Library",
                        value: "\(cookedRecipeCount)",
                        subtitle: "Distinct recipes that made it onto the stove",
                        systemImage: "book.fill",
                        tint: .orange
                    )
                    .tag(0)

                    snapshotCarouselTile(
                        title: "Favorite Cooks",
                        value: "\(favoriteCookedRecipesCount)",
                        subtitle: "Cooked recipes you keep close",
                        systemImage: "heart.circle.fill",
                        tint: .pink
                    )
                    .tag(1)

                    snapshotCarouselTile(
                        title: "Avg Repeat",
                        value: averageCookRepeatLabel,
                        subtitle: "How often cooked recipes return",
                        systemImage: "repeat.circle.fill",
                        tint: .green
                    )
                    .tag(2)

                    snapshotCarouselTile(
                        title: "Top Flavor",
                        value: topCookedCuisineLabel,
                        subtitle: "What your history leans toward",
                        systemImage: "fork.knife",
                        tint: .blue
                    )
                    .tag(3)

                    snapshotCarouselTile(
                        title: "Total Cooks",
                        value: "\(cookedCount)",
                        subtitle: "Every completed cooking session in your history",
                        systemImage: "flame.circle.fill",
                        tint: .purple
                    )
                    .tag(4)

                    snapshotCarouselTile(
                        title: "Live Kitchen Time",
                        value: liveCookingTimeLabel,
                        subtitle: "Time spent cooking with the live camera experience",
                        systemImage: "video.circle.fill",
                        tint: .teal
                    )
                    .tag(5)

                    snapshotCarouselTile(
                        title: "Recipe Browsing",
                        value: recipeViewingTimeLabel,
                        subtitle: "Time spent reading saved recipe details",
                        systemImage: "eyes",
                        tint: .indigo
                    )
                    .tag(6)

                    snapshotCarouselTile(
                        title: "Saved Favorites",
                        value: "\(favoriteRecipesCount)",
                        subtitle: "Recipes you marked as worth returning to",
                        systemImage: "bookmark.circle.fill",
                        tint: .mint
                    )
                    .tag(7)

                    snapshotCarouselTile(
                        title: "Current Streak",
                        value: "\(streakCount) days",
                        subtitle: "Consecutive days with meaningful kitchen activity",
                        systemImage: "flame.fill",
                        tint: .orange
                    )
                    .tag(8)

                    snapshotCarouselTile(
                        title: "Best Streak",
                        value: "\(longestStreak) days",
                        subtitle: "Your longest run of consistent cooking momentum",
                        systemImage: "trophy.fill",
                        tint: .yellow
                    )
                    .tag(9)

                    snapshotCarouselTile(
                        title: "Discovery Saves",
                        value: "\(achievementStats[ActivityEventType.swipeSave.rawValue, default: 0])",
                        subtitle: "Ideas saved while teaching ChefBuddy your taste",
                        systemImage: "hand.thumbsup.fill",
                        tint: .purple
                    )
                    .tag(10)

                    snapshotCarouselTile(
                        title: "Meals Logged",
                        value: "\(achievementStats[ActivityEventType.mealLogged.rawValue, default: 0])",
                        subtitle: "Real meals recorded to improve future planning",
                        systemImage: "checkmark.circle.fill",
                        tint: .green
                    )
                    .tag(11)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 238)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func snapshotCarouselTile(title: String, value: String, subtitle: String, systemImage: String, tint: Color) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: systemImage)
                .font(.system(size: 82, weight: .bold))
                .foregroundStyle(.white.opacity(0.15))
                .offset(x: 8, y: -2)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .bold))
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(0.8)
                }
                .foregroundStyle(.white.opacity(0.82))

                Spacer(minLength: 6)

                Text(value)
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
        .background(
            LinearGradient(
                colors: [tint.opacity(0.98), tint.opacity(0.58)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .shadow(color: tint.opacity(0.20), radius: 14, y: 7)
        .padding(.horizontal, 2)
    }

    private func featuredRecipeCard(_ recipe: Recipe) -> some View {
        Button {
            selectedRecipe = recipe
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.orange.opacity(0.22), .green.opacity(0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 74, height: 74)

                        Text(recipe.emoji)
                            .font(.system(size: 34))
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Most cooked right now")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text(recipe.title)
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Cooked \(recipe.cookedCount)x")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    recipeMetaPill(text: recipe.cookTime, systemImage: "clock")
                    recipeMetaPill(text: recipe.calories.isEmpty ? "Calories later" : recipe.calories, systemImage: "flame.fill")
                    if recipe.isFavorite {
                        recipeMetaPill(text: "Favorite", systemImage: "heart.fill")
                    }
                }

                HStack {
                    Text("Open recipe")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var topCookedRecipesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Cooked Most Often")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                Text("Repeat cooks only")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if topCookedRecipes.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [.orange.opacity(0.18), .green.opacity(0.14)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 68, height: 68)

                            Image(systemName: "fork.knife.circle")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.orange)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Your cookbook starts after the first cook")
                                .font(.system(size: 16, weight: .heavy, design: .rounded))
                            Text("Cook a saved recipe once and ChefBuddy will start building your repeat favorites here.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 10) {
                        summaryStatCard(title: "Saved", value: "\(recipes.count)", tint: .orange)
                        summaryStatCard(title: "Cooked", value: "0", tint: .green)
                    }
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(topCookedRecipes) { recipe in
                        profileRecipeRow(recipe)
                    }
                }
            }
        }
    }

    private var achievementOverviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Journey Snapshot")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Your rank climb, badge tiers, and next milestone without the extra clutter.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                profileTag(rankProgress.current.rawValue, tint: .orange)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .lastTextBaseline) {
                    Text("\(xpTotal) XP")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                    Spacer()
                    Text(rankProgress.next.map { "\((nextRankXPRemaining ?? 0)) XP to \($0.rawValue)" } ?? "Top rank reached")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                ProgressView(value: rankProgress.progress)
                    .tint(.green)
            }

            HStack(spacing: 10) {
                summaryStatCard(title: "Bronze", value: "\(bronzeBadgeCount)", tint: .brown)
                summaryStatCard(title: "Silver", value: "\(silverBadgeCount)", tint: .gray)
                summaryStatCard(title: "Gold", value: "\(goldBadgeCount)", tint: .yellow)
                summaryStatCard(title: "Platinum", value: "\(platinumBadgeCount)", tint: .blue)
            }

            if let recent = recentUnlockedAchievements.first {
                Button {
                    selectedAchievement = recent
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: recent.icon)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.yellow)
                            .frame(width: 34, height: 34)
                            .background(Color.yellow.opacity(0.14), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Latest unlock")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Text(recent.title)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var badgeVaultLauncherCard: some View {
        Button {
            showBadgeVault = true
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.orange.opacity(0.2), .green.opacity(0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 68, height: 68)

                        Image(systemName: "rosette")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Badge Vault")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("Open the full collection, browse each tier ladder, and tap any badge to view its certificate.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    tierPill(title: "Bronze", count: bronzeBadgeCount, tint: .brown)
                    tierPill(title: "Silver", count: silverBadgeCount, tint: .gray)
                    tierPill(title: "Gold", count: goldBadgeCount, tint: .yellow)
                    tierPill(title: "Platinum", count: platinumBadgeCount, tint: .blue)
                }

                HStack {
                    Text("\(displayedAchievements.count) badges tracked in your journey")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Open Vault")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var nextUnlocksCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next unlocks")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                    Text("The closest milestones on your kitchen path.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoadingAchievements {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.orange)
                }
            }

            if nextAchievementGoals.isEmpty {
                Text("You’ve unlocked every current badge. More milestones will appear as ChefBuddy grows.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(nextAchievementGoals) { badge in
                    let unlockTint = badge.nextTier?.tint ?? badge.displayTier.tint
                    Button {
                        selectedAchievement = badge
                    } label: {
                        HStack(spacing: 13) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(unlockTint.opacity(0.14))
                                    .frame(width: 52, height: 52)
                                Image(systemName: badge.icon)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(unlockTint)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: badge.icon)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(unlockTint)
                                    Text(badge.title)
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Text(badge.nextTier.map { "\($0.title) next" } ?? "Max tier")
                                        .font(.system(size: 10, weight: .black, design: .rounded))
                                        .foregroundStyle(unlockTint)
                                }

                                ProgressView(value: badge.tierProgressRatio)
                                    .tint(unlockTint)

                                HStack {
                                    Text(badge.subtitle)
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)

                                    Spacer(minLength: 4)

                                    if let nextTarget = badge.nextTarget {
                                        Text("\(badge.progress)/\(nextTarget)")
                                            .font(.system(size: 11, weight: .black, design: .rounded))
                                            .foregroundStyle(unlockTint)
                                    }
                                }
                            }
                        }
                        .padding(13)
                        .background(unlockTint.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(unlockTint.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func tierPill(title: String, count: Int, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text("\(count)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func profileTag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func dashboardMetricButton(title: String, value: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func identityMetricChip(title: String, value: String, systemImage: String, tint: Color, isEmphasized: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .scaleEffect(isEmphasized ? 1.04 : 1)
        .shadow(color: isEmphasized ? tint.opacity(0.18) : .clear, radius: 10, y: 4)
    }

    private func primaryActionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [.orange, .green.opacity(0.88)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func secondaryActionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func highlightStatTile(title: String, value: String, subtitle: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func profileToolAction(title: String, subtitle: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(14)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func summaryStatCard(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func profileRecipeRow(_ recipe: Recipe) -> some View {
        Button {
            selectedRecipe = recipe
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 64, height: 64)
                    Text(recipe.emoji)
                        .font(.system(size: 28))
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(recipe.title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        if recipe.isFavorite {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.red)
                        }
                    }

                    HStack(spacing: 8) {
                        recipeMetaPill(text: recipe.cookTime, systemImage: "clock")
                        recipeMetaPill(text: "Cooked \(recipe.cookedCount)x", systemImage: "flame.fill")
                    }

                    Text(recipe.tags.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "Saved recipe")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func recipeMetaPill(text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func emptyStateCard(title: String, subtitle: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func achievementCelebrationBanner(_ badge: AchievementBadge) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(colors: [.orange.opacity(0.94), .yellow.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 52, height: 52)

                Image(systemName: badge.icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Badge Unlocked")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(badge.title)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                Text(badge.subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    highlightedAchievement = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .orange.opacity(0.18), radius: 12, y: 8)
    }

    private func profileFeedbackBanner(_ banner: ProfileFeedbackBanner) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(banner.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text(banner.subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(banner.tint.opacity(0.16), lineWidth: 1)
        )
    }

    private func hydrateIdentityFromProfile() {
        guard let profile = authVM.currentUserProfile else { return }
        handleText = profile.profileHandle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? profile.profileHandle!
            : (profile.email?.split(separator: "@").first.map(String.init) ?? "chefbuddy")
        bioText = profile.profileBio ?? ""
    }

    private func persistIdentity() {
        isSavingIdentity = true
        authVM.updateProfileIdentity(handle: handleText, bio: bioText)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            isSavingIdentity = false
            showBanner(
                title: "Profile updated",
                subtitle: "Your handle and bio changed right away.",
                tint: .green
            )
        }
    }

    private func resetDiscoverySignals() {
        isResettingDiscovery = true
        authVM.resetDiscoverySuggestions { success in
            DispatchQueue.main.async {
                isResettingDiscovery = false
                if success {
                    showBanner(
                        title: "AI suggestions reset",
                        subtitle: "ChefBuddy will start learning again from fresh swipes.",
                        tint: .green
                    )
                }
            }
        }
    }

    private func startListeners() {
        guard !userId.isEmpty else { return }

        userProfileListener?.remove()
        recipesListener?.remove()
        achievementListener?.remove()
        galleryListener?.remove()
        isLoadingAchievements = true

        userProfileListener = db.collection("users")
            .document(userId)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("Failed to listen for user profile: \(error.localizedDescription)")
                }

                guard let snapshot, snapshot.exists else { return }
                do {
                    var profile = try snapshot.data(as: DBUser.self)
                    if profile.profileHandle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                        profile.profileHandle = profile.email?.split(separator: "@").first.map(String.init) ?? "chefbuddy"
                    }
                    if profile.profileBio == nil {
                        profile.profileBio = ""
                    }
                    if profile.xpTotal == nil { profile.xpTotal = 0 }
                    if profile.rankTier == nil { profile.rankTier = RankTier.lineCook.rawValue }
                    if profile.currentStreak == nil { profile.currentStreak = 0 }
                    if profile.longestStreak == nil { profile.longestStreak = 0 }
                    if profile.activityStats == nil { profile.activityStats = [:] }

                    DispatchQueue.main.async {
                        authVM.currentUserProfile = profile
                    }
                } catch {
                    print("Failed to decode user profile listener payload: \(error.localizedDescription)")
                }
            }

        recipesListener = db.collection("users")
            .document(userId)
            .collection("recipes")
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                DispatchQueue.main.async {
                    recipes = docs.compactMap { try? $0.data(as: Recipe.self) }
                }
            }

        galleryListener = db.collectionGroup("gallery")
            .whereField("userId", isEqualTo: userId)
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { snapshot, _ in
                let memories = snapshot?.documents.compactMap { document -> ProfileGalleryMemory? in
                    let data = document.data()
                    guard let downloadURL = data["downloadURL"] as? String else { return nil }
                    return ProfileGalleryMemory(
                        id: document.documentID,
                        downloadURL: downloadURL,
                        recipeTitle: data["recipeTitle"] as? String ?? "Cooked dish",
                        recipeEmoji: data["recipeEmoji"] as? String ?? "🍽️",
                        createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                    )
                } ?? []
                DispatchQueue.main.async {
                    galleryMemories = memories
                }
            }

        achievementListener = db.collection("users")
            .document(userId)
            .collection("achievements")
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("Failed to listen for achievements: \(error.localizedDescription)")
                }

                let docs = snapshot?.documents ?? []
                DispatchQueue.main.async {
                    isLoadingAchievements = false
                    let decoded = docs.compactMap(decodeAchievement)
                        .sorted { lhs, rhs in
                            if lhs.isUnlocked == rhs.isUnlocked {
                                return lhs.title < rhs.title
                            }
                            return lhs.isUnlocked && !rhs.isUnlocked
                        }

                    if seededAchievementCelebrations == false {
                        seededAchievementCelebrations = true
                    } else {
                        let previouslyKnown = Set(achievements.filter(\.isUnlocked).map { $0.id ?? $0.key })
                        if let fresh = decoded
                            .filter({ $0.isUnlocked && !previouslyKnown.contains($0.id ?? $0.key) })
                            .sorted(by: { ($0.unlockedAt ?? .distantPast) > ($1.unlockedAt ?? .distantPast) })
                            .first {
                            let freshIdentifier = fresh.id ?? fresh.key
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                                highlightedAchievement = fresh
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                                let currentIdentifier = highlightedAchievement?.id ?? highlightedAchievement?.key
                                guard currentIdentifier == freshIdentifier else { return }
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                                    highlightedAchievement = nil
                                }
                            }
                        }
                    }

                    achievements = decoded

                    if docs.isEmpty {
                        Task {
                            await GrowthEngine.shared.refreshDerivedProgress(userId: userId)
                        }
                    }
                }
            }
    }

    private func decodeAchievement(_ document: QueryDocumentSnapshot) -> AchievementBadge? {
        let data = document.data()
        guard
            let key = data["key"] as? String,
            let title = data["title"] as? String,
            let subtitle = data["subtitle"] as? String,
            let icon = data["icon"] as? String
        else {
            return nil
        }

        let progress = data["progress"] as? Int ?? 0
        let target = data["target"] as? Int ?? 1
        let isUnlocked = data["isUnlocked"] as? Bool ?? false
        let milestones = (data["milestones"] as? [Int]).flatMap { $0.isEmpty ? nil : $0 } ?? legacyMilestones(for: key, target: target)
        let unlockedAt: Date? = {
            if let timestamp = data["unlockedAt"] as? Timestamp {
                return timestamp.dateValue()
            }
            return data["unlockedAt"] as? Date
        }()
        let tierUnlockedAt: [String: Date]? = {
            guard let map = data["tierUnlockedAt"] as? [String: Any] else { return nil }
            var resolved: [String: Date] = [:]
            for (tier, value) in map {
                if let timestamp = value as? Timestamp {
                    resolved[tier] = timestamp.dateValue()
                } else if let date = value as? Date {
                    resolved[tier] = date
                }
            }
            return resolved.isEmpty ? nil : resolved
        }()

        return AchievementBadge(
            id: document.documentID,
            key: key,
            title: title,
            subtitle: subtitle,
            icon: icon,
            progress: progress,
            target: target,
            isUnlocked: isUnlocked,
            unlockedAt: unlockedAt,
            milestones: milestones,
            tierUnlockedAt: tierUnlockedAt
        )
    }

    private func legacyMilestones(for key: String, target: Int) -> [Int] {
        switch key {
        case "recipe_collector":
            return [5, 15, 50, 100]
        case "recipe_archivist":
            return [10, 25, 75, 150]
        case "favorite_curator":
            return [3, 10, 25, 60]
        case "signature_dish":
            return [2, 3, 5, 8]
        default:
            let safeTarget = max(1, target)
            let first = max(1, safeTarget / 4)
            let second = max(first + 1, safeTarget / 2)
            let third = max(second + 1, (safeTarget * 3) / 4)
            return [first, second, third, safeTarget]
        }
    }

    private func showBanner(title: String, subtitle: String, tint: Color) {
        let banner = ProfileFeedbackBanner(title: title, subtitle: subtitle, tint: tint)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            feedbackBanner = banner
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            guard feedbackBanner?.id == banner.id else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                feedbackBanner = nil
            }
        }
    }

    private func achievementCategory(for badge: AchievementBadge) -> ProfileAchievementCategory {
        switch badge.key {
        case "first_plan", "planner_pro", "week_builder", "meal_logger", "daily_honesty", "streak_chef", "streak_master":
            return .consistency
        case "first_flame", "kitchen_regular", "signature_dish", "recipe_collector", "recipe_archivist", "favorite_curator", "cuisine_hopper":
            return .cooking
        case "discovery_explorer", "flavor_scout":
            return .discovery
        case "profile_polished", "rank_up", "executive_climb":
            return .profile
        default:
            return .profile
        }
    }

    private func updateRecipe(_ updatedRecipe: Recipe) {
        guard let id = updatedRecipe.id, !userId.isEmpty else { return }

        if let index = recipes.firstIndex(where: { $0.id == id }) {
            recipes[index] = updatedRecipe
        }
        selectedRecipe = updatedRecipe

        guard let encoded = try? Firestore.Encoder().encode(updatedRecipe) else { return }
        db.collection("users")
            .document(userId)
            .collection("recipes")
            .document(id)
            .setData(encoded, merge: false)
    }

    private func toggleFavorite(_ recipe: Recipe) {
        guard let id = recipe.id, !userId.isEmpty else { return }
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { return }

        recipes[index].isFavorite.toggle()
        selectedRecipe = recipes[index]
        let updatedValue = recipes[index].isFavorite

        db.collection("users")
            .document(userId)
            .collection("recipes")
            .document(id)
            .updateData(["isFavorite": updatedValue]) { error in
                if error != nil, let rollbackIndex = recipes.firstIndex(where: { $0.id == id }) {
                    recipes[rollbackIndex].isFavorite.toggle()
                    selectedRecipe = recipes[rollbackIndex]
                } else {
                    showBanner(
                        title: updatedValue ? "Added to favorites" : "Removed from favorites",
                        subtitle: recipe.title,
                        tint: updatedValue ? .pink : .orange
                    )
                }
            }
    }

    private func deleteRecipe(_ recipe: Recipe) {
        guard let id = recipe.id, !userId.isEmpty else { return }

        db.collection("users")
            .document(userId)
            .collection("recipes")
            .document(id)
            .delete()

        selectedRecipe = nil
        showBanner(
            title: "Recipe removed",
            subtitle: recipe.title,
            tint: .orange
        )
    }

    private func markRecipeCooked(_ recipe: Recipe) {
        guard let id = recipe.id, !userId.isEmpty else { return }
        let newCount = recipe.cookedCount + 1
        let now = Date()

        if let index = recipes.firstIndex(where: { $0.id == id }) {
            recipes[index].cookedCount = newCount
            recipes[index].lastCookedAt = now
            selectedRecipe = recipes[index]
        }

        db.collection("users")
            .document(userId)
            .collection("recipes")
            .document(id)
            .updateData(["cookedCount": newCount, "lastCookedAt": now])

        Task {
            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .recipeCooked,
                eventKey: "profile_recipe_cooked_\(id)_\(newCount)",
                metadata: [
                    "recipeId": id,
                    "title": recipe.title,
                    "source": "profile"
                ]
            )
        }

        showBanner(
            title: "Marked as cooked",
            subtitle: "\(recipe.title) moved your streak forward.",
            tint: .green
        )
    }
}

private struct ProfileHubBackground: View {
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

private extension AchievementTierLevel {
    var tint: Color {
        switch self {
        case .bronze: return Color(red: 0.72, green: 0.47, blue: 0.28)
        case .silver: return .gray
        case .gold: return Color(red: 0.90, green: 0.72, blue: 0.20)
        case .platinum: return Color(red: 0.39, green: 0.71, blue: 0.95)
        }
    }
}

private struct RankRoadmapView: View {
    let currentXP: Int
    @Environment(\.dismiss) private var dismiss

    private var currentTier: RankTier {
        RankTier.tier(forXP: currentXP)
    }

    var body: some View {
        ZStack {
            ProfileHubBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Your Chef Rank")
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                        Text("Ranks grow from real kitchen activity—not passive browsing. Every milestone below shows exactly where you are headed.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        rankEarningCard(icon: "fork.knife", title: "Cook", detail: "+24 XP")
                        rankEarningCard(icon: "checkmark.circle.fill", title: "Complete", detail: "+20 XP")
                        rankEarningCard(icon: "sparkles", title: "Discover", detail: "+2–8 XP")
                    }

                    VStack(spacing: 12) {
                        ForEach(Array(RankTier.thresholds.enumerated()), id: \.element.tier) { index, checkpoint in
                            let tier = checkpoint.tier
                            let isEarned = currentXP >= checkpoint.minXP
                            let isCurrent = tier == currentTier
                            let nextThreshold = index + 1 < RankTier.thresholds.count
                                ? RankTier.thresholds[index + 1].minXP
                                : checkpoint.minXP
                            let progress = isEarned
                                ? (isCurrent && nextThreshold > checkpoint.minXP
                                    ? Double(currentXP - checkpoint.minXP) / Double(nextThreshold - checkpoint.minXP)
                                    : 1)
                                : 0

                            HStack(alignment: .top, spacing: 14) {
                                VStack(spacing: 0) {
                                    Image(systemName: tier.icon)
                                        .font(.system(size: 19, weight: .bold))
                                        .foregroundStyle(isEarned ? tier.accent : .secondary)
                                        .frame(width: 46, height: 46)
                                        .background((isEarned ? tier.accent : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    if index < RankTier.thresholds.count - 1 {
                                        Rectangle()
                                            .fill(isEarned ? tier.accent.opacity(0.35) : Color.primary.opacity(0.08))
                                            .frame(width: 3, height: 46)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(tier.rawValue)
                                            .font(.system(size: 17, weight: .bold, design: .rounded))
                                        Spacer()
                                        Text(isCurrent ? "CURRENT" : isEarned ? "EARNED" : "\(checkpoint.minXP) XP")
                                            .font(.system(size: 9, weight: .black, design: .rounded))
                                            .foregroundStyle(isCurrent ? .white : isEarned ? tier.accent : .secondary)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 6)
                                            .background(
                                                isCurrent ? AnyShapeStyle(tier.accent) : AnyShapeStyle((isEarned ? tier.accent : Color.secondary).opacity(0.10)),
                                                in: Capsule()
                                            )
                                    }
                                    Text(tier.summary)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if isCurrent && nextThreshold > checkpoint.minXP {
                                        ProgressView(value: min(max(progress, 0), 1))
                                            .tint(tier.accent)
                                        Text("\(max(nextThreshold - currentXP, 0)) XP until \(RankTier.thresholds[index + 1].tier.rawValue)")
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundStyle(tier.accent)
                                    }
                                }
                                .padding(.top, 3)
                            }
                        }
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .padding(20)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Rank Path")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    ChefBuddyHaptics.light()
                    dismiss()
                }
            }
        }
    }

    private func rankEarningCard(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
            Text(detail)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct RotatingAchievementBadge: View {
    let icon: String
    let tint: Color
    let isUnlocked: Bool
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let tilt = reduceMotion ? 0 : sin(phase * 0.9) * 12
            let shine = reduceMotion ? 0 : (sin(phase * 1.15) + 1) / 2

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.34), tint.opacity(isUnlocked ? 0.94 : 0.34), Color.black.opacity(0.34)],
                            center: UnitPoint(x: 0.34, y: 0.25),
                            startRadius: 2,
                            endRadius: size * 0.62
                        )
                    )

                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [Color.white.opacity(0.84), tint, Color.black.opacity(0.26), Color.white.opacity(0.72)],
                            center: .center
                        ),
                        lineWidth: max(2, size * 0.07)
                    )
                    .padding(size * 0.08)

                Circle()
                    .fill(Color.black.opacity(0.18))
                    .padding(size * 0.21)

                Image(systemName: isUnlocked ? icon : "lock.fill")
                    .font(.system(size: size * 0.30, weight: .black))
                    .foregroundStyle(Color.white.opacity(isUnlocked ? 0.96 : 0.62))

                Capsule()
                    .fill(Color.white.opacity(0.34))
                    .frame(width: size * 0.16, height: size * 0.62)
                    .blur(radius: size * 0.06)
                    .rotationEffect(.degrees(24))
                    .offset(x: CGFloat(shine - 0.5) * size * 0.55)
                    .mask(Circle().padding(size * 0.05))
            }
            .frame(width: size, height: size)
            .rotation3DEffect(.degrees(tilt), axis: (x: 0.1, y: 1, z: 0), perspective: 0.72)
            .shadow(color: tint.opacity(isUnlocked ? 0.30 : 0.08), radius: size * 0.15, y: size * 0.10)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct ChefBuddyConfettiView: View {
    let tint: Color
    @State private var isFalling = false

    private let colors: [Color] = [.yellow, .orange, .pink, .blue, .mint, .purple]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(0..<42, id: \.self) { index in
                    let xFraction = CGFloat((index * 37) % 101) / 100
                    let width = CGFloat(5 + (index % 4) * 2)
                    let delay = Double(index % 12) * 0.055
                    let particleColor = index % 7 == 0 ? tint : colors[index % colors.count]

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(particleColor)
                        .frame(width: width, height: width * 1.7)
                        .rotationEffect(.degrees(isFalling ? Double(index * 79) : Double(index * 13)))
                        .position(x: proxy.size.width * xFraction, y: isFalling ? proxy.size.height + 35 : -20)
                        .animation(
                            .easeIn(duration: 1.8 + Double(index % 5) * 0.17)
                                .delay(delay),
                            value: isFalling
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            isFalling = true
        }
    }
}

private struct BadgeVaultView: View {
    let badges: [AchievementBadge]
    let displayHandle: String
    let currentRank: RankTier
    let xpTotal: Int

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFilter: BadgeVaultFilter = .all
    @State private var selectedTier: AchievementTierLevel? = nil
    @State private var selectedBadge: AchievementBadge? = nil

    private enum BadgeVaultFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case unlocked = "Unlocked"
        case climbing = "Climbing"

        var id: String { rawValue }
    }

    private var groupedBadges: [(category: ProfileAchievementCategory, badges: [AchievementBadge])] {
        ProfileAchievementCategory.allCases.compactMap { category in
            let filtered = badges
                .filter { badgeCategory(for: $0) == category }
                .filter { badge in
                    guard let selectedTier else { return true }
                    return badge.currentTier == selectedTier
                }
                .filter { badge in
                    switch selectedFilter {
                    case .all: return true
                    case .unlocked: return badge.currentTier != nil
                    case .climbing: return !badge.isAtMaxTier
                    }
                }
                .sorted { lhs, rhs in
                    let lhsTier = AchievementTierLevel.allCases.firstIndex(of: lhs.currentTier ?? .bronze) ?? -1
                    let rhsTier = AchievementTierLevel.allCases.firstIndex(of: rhs.currentTier ?? .bronze) ?? -1
                    if lhsTier == rhsTier { return lhs.title < rhs.title }
                    return lhsTier > rhsTier
                }

            guard !filtered.isEmpty else { return nil }
            return (category, filtered)
        }
    }

    private var bronzeCount: Int { badges.filter { $0.currentTier == .bronze }.count }
    private var silverCount: Int { badges.filter { $0.currentTier == .silver }.count }
    private var goldCount: Int { badges.filter { $0.currentTier == .gold }.count }
    private var platinumCount: Int { badges.filter { $0.currentTier == .platinum }.count }
    private var unlockedCount: Int { badges.filter { $0.currentTier != nil }.count }

    private func filteredCount(for filter: BadgeVaultFilter) -> Int {
        switch filter {
        case .all:
            return badges.count
        case .unlocked:
            return badges.filter { $0.currentTier != nil }.count
        case .climbing:
            return badges.filter { !$0.isAtMaxTier }.count
        }
    }

    var body: some View {
        ZStack {
            ProfileHubBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("YOUR COLLECTION")
                                    .font(.system(size: 10, weight: .black, design: .rounded))
                                    .tracking(1)
                                    .foregroundStyle(.white.opacity(0.72))
                                Text("Badge Vault")
                                    .font(.system(size: 31, weight: .heavy, design: .rounded))
                            }
                            Spacer()
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 27, weight: .bold))
                                .frame(width: 58, height: 58)
                                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                        }

                        HStack(spacing: 9) {
                            vaultHeroMetric(value: "\(unlockedCount)", label: "unlocked")
                            vaultHeroMetric(value: "\(badges.count - unlockedCount)", label: "in progress")
                            vaultHeroMetric(value: "\(xpTotal)", label: "total XP")
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(21)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.13, green: 0.14, blue: 0.18),
                                Color(red: 0.07, green: 0.08, blue: 0.11)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 29, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 29, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.24), radius: 18, y: 9)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            vaultTierCard(title: "Bronze", count: bronzeCount, tint: .bronze)
                            vaultTierCard(title: "Silver", count: silverCount, tint: .silver)
                            vaultTierCard(title: "Gold", count: goldCount, tint: .gold)
                            vaultTierCard(title: "Platinum", count: platinumCount, tint: .platinum)
                        }
                    }

                    if let selectedTier {
                        Button {
                            ChefBuddyHaptics.light()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                self.selectedTier = nil
                            }
                        } label: {
                            Label("Showing \(selectedTier.title) badges", systemImage: "line.3.horizontal.decrease.circle.fill")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(selectedTier.tint)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(selectedTier.tint.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 10) {
                        ForEach(BadgeVaultFilter.allCases) { filter in
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                    selectedFilter = filter
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Image(systemName: filter == .all ? "square.grid.2x2.fill" : filter == .unlocked ? "checkmark.seal.fill" : "arrow.up.forward.circle.fill")
                                            .font(.system(size: 11, weight: .bold))
                                        Text(filter.rawValue)
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                    }

                                    Text("\(filteredCount(for: filter)) badges")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundStyle(selectedFilter == filter ? .white.opacity(0.86) : .secondary)
                                }
                                .foregroundStyle(selectedFilter == filter ? .white : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .background(
                                    selectedFilter == filter
                                        ? AnyShapeStyle(
                                            LinearGradient(
                                                colors: [Color.indigo, Color.blue.opacity(0.82)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        : AnyShapeStyle(Color.white.opacity(0.035)),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(selectedFilter == filter ? Color.white.opacity(0.08) : Color.primary.opacity(0.06), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ForEach(groupedBadges, id: \.category) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: section.category.icon)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(categoryTint(section.category))
                                    .frame(width: 30, height: 30)
                                    .background(categoryTint(section.category).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.category.rawValue)
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                    Text("Tier ladders you are building in this lane.")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(section.badges.count)")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }

                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)],
                                spacing: 11
                            ) {
                                ForEach(section.badges) { badge in
                                    vaultBadgeTile(badge)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
        }
        .sheet(item: $selectedBadge) { badge in
            AchievementCertificateSheet(
                badge: badge,
                currentRank: currentRank,
                xpTotal: xpTotal,
                displayHandle: displayHandle
            )
        }
    }

    private func vaultHeroMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
            Text(label.uppercased())
                .font(.system(size: 8, weight: .black, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func badgeCategory(for badge: AchievementBadge) -> ProfileAchievementCategory {
        switch badge.key {
        case "first_plan", "planner_pro", "week_builder", "meal_logger", "daily_honesty", "streak_chef", "streak_master":
            return .consistency
        case "first_flame", "kitchen_regular", "signature_dish", "recipe_collector", "recipe_archivist", "favorite_curator", "cuisine_hopper":
            return .cooking
        case "discovery_explorer", "flavor_scout":
            return .discovery
        default:
            return .profile
        }
    }

    private func categoryTint(_ category: ProfileAchievementCategory) -> Color {
        switch category {
        case .consistency: return .blue
        case .cooking: return .orange
        case .discovery: return .purple
        case .profile: return .teal
        }
    }

    private func vaultTierCard(title: String, count: Int, tint: AchievementTierLevel) -> some View {
        let isSelected = selectedTier == tint

        return Button {
            ChefBuddyHaptics.selection()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                selectedTier = isSelected ? nil : tint
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: tierFilterIcon(tint))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isSelected ? .white : tint.tint)
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : tint.tint)
                Text("\(count)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .frame(width: 91)
            .padding(.vertical, 12)
            .background(
                isSelected
                    ? AnyShapeStyle(tint.tint.gradient)
                    : AnyShapeStyle(
                        LinearGradient(
                            colors: [Color.white.opacity(0.035), tint.tint.opacity(0.16)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    ),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.16) : tint.tint.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func tierFilterIcon(_ tier: AchievementTierLevel) -> String {
        switch tier {
        case .bronze: return "flame.fill"
        case .silver: return "star.fill"
        case .gold: return "trophy.fill"
        case .platinum: return "crown.fill"
        }
    }

    private func vaultBadgeTile(_ badge: AchievementBadge) -> some View {
        Button {
            ChefBuddyHaptics.selection()
            selectedBadge = badge
        } label: {
            VStack(spacing: 10) {
                RotatingAchievementBadge(
                    icon: badge.icon,
                    tint: badge.currentTier?.tint ?? .gray,
                    isUnlocked: badge.currentTier != nil,
                    size: 78
                )

                VStack(spacing: 3) {
                    Text(badge.title)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(badge.currentTier?.title.uppercased() ?? "LOCKED")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(badge.currentTier?.tint ?? .secondary)
                }

                ProgressView(value: badge.tierProgressRatio)
                    .tint(badge.currentTier?.tint ?? .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 158)
            .padding(13)
            .background(
                LinearGradient(
                    colors: [Color.primary.opacity(0.035), (badge.currentTier?.tint ?? .gray).opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke((badge.currentTier?.tint ?? .gray).opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func vaultBadgeCard(_ badge: AchievementBadge) -> some View {
        Button {
            selectedBadge = badge
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RotatingAchievementBadge(
                        icon: badge.icon,
                        tint: badge.displayTier.tint,
                        isUnlocked: badge.isUnlocked,
                        size: 62
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(badge.title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(badge.subtitle)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    ForEach(AchievementTierLevel.allCases) { tier in
                        let isEarned = badge.earnedTiers.contains(tier)
                        Text(tier.title)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(isEarned ? tier.tint : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background((isEarned ? tier.tint : .secondary).opacity(isEarned ? 0.16 : 0.08), in: Capsule())
                    }
                }

                HStack(spacing: 10) {
                    Label(
                        badge.unlockedDate(for: badge.currentTier ?? .bronze)?.formatted(date: .abbreviated, time: .omitted)
                            ?? badge.requirementLabel(for: badge.nextTier ?? .bronze),
                        systemImage: badge.currentTier == nil ? "lock.fill" : "calendar"
                    )
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Text(badge.currentTier.map { "\($0.title) • \(badge.currentTierXPReward) XP" } ?? "Climbing")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(badge.displayTier.tint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(badge.displayTier.tint.opacity(0.14), in: Capsule())
                }

                ProgressView(value: badge.tierProgressRatio)
                    .tint(badge.displayTier.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.22), badge.displayTier.tint.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(badge.displayTier.tint.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AchievementCertificateSheet: View {
    let badge: AchievementBadge
    let currentRank: RankTier
    let xpTotal: Int
    let displayHandle: String

    @Environment(\.dismiss) private var dismiss
    @State private var certificateTilt: Double = -82
    @State private var showCelebration = false

    private var progressValue: Double {
        badge.tierProgressRatio
    }

    private var displayTier: AchievementTierLevel {
        badge.displayTier
    }

    private var currentTierLabel: String {
        badge.currentTier?.title ?? "Locked"
    }

    private var certificateTitle: String {
        if badge.currentTier == nil {
            return "\(displayTier.title) Tier Waiting"
        }
        if badge.isAtMaxTier {
            return "\(displayTier.title) Tier Secured"
        }
        return "\(displayTier.title) Tier Earned"
    }

    private var certificateSubtitle: String {
        switch displayTier {
        case .bronze:
            return badge.currentTier == nil
                ? "Your first tier opens once you hit the Bronze milestone for this badge."
                : "You have earned the first step in this badge ladder."
        case .silver:
            return "This badge has moved beyond the starter tier and into Silver momentum."
        case .gold:
            return "Gold means this habit is becoming a real part of how you cook."
        case .platinum:
            return "Platinum marks the top tier for this badge and a standout milestone in your kitchen journey."
        }
    }

    private var issuedLabel: String {
        if let unlocked = badge.unlockedDate(for: displayTier) {
            return unlocked.formatted(date: .abbreviated, time: .omitted)
        }
        return badge.requirementLabel(for: displayTier)
    }

    private var statusLabel: String {
        if badge.currentTier == nil {
            return "Unlocks with \(badge.requirementLabel(for: displayTier))"
        }
        if badge.isAtMaxTier {
            return "\(displayTier.title) tier complete • \(badge.xpReward(for: displayTier)) XP earned"
        }
        return "\(displayTier.title) tier earned • \(badge.xpReward(for: displayTier)) XP"
    }

    var body: some View {
        ZStack {
            ProfileHubBackground()

            if showCelebration {
                ChefBuddyConfettiView(tint: displayTier.tint)
                    .ignoresSafeArea()
                    .zIndex(8)
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("ChefBuddy Achievement Certificate")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 26)
                            .padding(.top, 20)

                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Awarded to")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.65))
                                    Text(displayHandle)
                                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                                        .foregroundStyle(.white)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Text(displayTier.title)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(displayTier.tint)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(displayTier.tint.opacity(0.14), in: Capsule())
                            }

                            Text(certificateTitle)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(displayTier.tint)

                            Text(badge.title)
                                .font(.system(size: 28, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(certificateSubtitle)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.74))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Issued")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.65))
                                    Text(issuedLabel)
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer()

                                ZStack {
                                    Circle()
                                        .fill(displayTier.tint.opacity(0.16))
                                        .frame(width: 124, height: 124)
                                        .blur(radius: 8)

                                    RotatingAchievementBadge(
                                        icon: badge.icon,
                                        tint: displayTier.tint,
                                        isUnlocked: badge.isUnlocked,
                                        size: 106
                                    )
                                }
                                .frame(width: 124, height: 124)
                                .accessibilityLabel("\(displayTier.title) \(badge.title) badge, animated in 3D")
                            }
                        }
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.16, green: 0.16, blue: 0.18),
                                    Color(red: 0.12, green: 0.13, blue: 0.16),
                                    displayTier.tint.opacity(0.24)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(displayTier.tint.opacity(0.34), lineWidth: 1.2)
                        )
                        .shadow(color: displayTier.tint.opacity(0.12), radius: 22, y: 12)
                        .rotation3DEffect(.degrees(certificateTilt), axis: (x: 0, y: 1, z: 0), perspective: 0.7)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Tier Progress")
                                .font(.system(size: 15, weight: .bold, design: .rounded))

                            HStack(spacing: 8) {
                                ForEach(Array(zip(AchievementTierLevel.allCases.indices, AchievementTierLevel.allCases)), id: \.0) { index, tier in
                                    let milestone = badge.tierMilestones[min(index, badge.tierMilestones.count - 1)]
                                    VStack(spacing: 6) {
                                        Text(tier.title)
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundStyle(tier.tint)
                                        Text("\(milestone)")
                                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                                            .foregroundStyle(.primary)
                                        Text(badge.unlockedDate(for: tier)?.formatted(date: .abbreviated, time: .omitted) ?? "Locked")
                                            .font(.system(size: 10, weight: .medium, design: .rounded))
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(tier.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(statusLabel)
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(badge.nextTier.map { badge.requirementLabel(for: $0) } ?? "All tiers earned")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                ProgressView(value: progressValue)
                                    .tint(displayTier.tint)
                            }
                        }
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                        VStack(alignment: .leading, spacing: 13) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("HOW THIS BADGE IS EARNED")
                                        .font(.system(size: 9, weight: .black, design: .rounded))
                                        .tracking(0.8)
                                        .foregroundStyle(displayTier.tint)
                                    Text(badge.subtitle)
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: badge.icon)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(displayTier.tint)
                                    .frame(width: 46, height: 46)
                                    .background(displayTier.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                            }

                            Text("Your activity reached \(badge.progress) toward this badge. \(badge.currentTier == nil ? "The first tier unlocks at \(badge.requirementLabel(for: .bronze))." : "Your latest earned tier is \(currentTierLabel), awarded for reaching \(badge.requirementLabel(for: displayTier)).")")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 9) {
                                certificateStat(value: "\(badge.progress)", label: "Current")
                                certificateStat(
                                    value: badge.nextTarget.map(String.init) ?? "Done",
                                    label: "Next Tier"
                                )
                                certificateStat(value: "\(xpTotal)", label: "Total XP")
                                certificateStat(value: currentRank.rawValue, label: "Rank")
                            }
                        }
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(displayTier.tint.opacity(0.14), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            showCelebration = true
            ChefBuddyHaptics.success()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.84)) {
                certificateTilt = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                showCelebration = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
        }
    }

    private func detailMetricRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func certificateStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(displayTier.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(label.uppercased())
                .font(.system(size: 7, weight: .black, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(displayTier.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ProfileDetailsSheet: View {
    @Binding var handleText: String
    @Binding var bioText: String
    @Binding var isSavingIdentity: Bool
    let profileCompletionScore: Int
    let scoreCheckpoints: [(title: String, isComplete: Bool)]
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var normalizedHandlePreview: String {
        let trimmed = handleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "@chefbuddy" }
        return "@\(trimmed.lowercased().replacingOccurrences(of: " ", with: ""))"
    }

    var body: some View {
        ZStack {
            ProfileHubBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Profile Details")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))

                        Text("Update the private identity ChefBuddy uses across your profile and recommendation surfaces.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [.orange.opacity(0.22), .green.opacity(0.16)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 78, height: 78)

                                Image("ChefBuddyLogo")
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 58, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Live Preview")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                Text(normalizedHandlePreview)
                                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(
                                    bioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? "Add a short line that describes how you cook."
                                        : bioText
                                )
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        HStack(spacing: 10) {
                            profileDetailMetric(title: "Handle", value: handleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Missing" : "Ready", tint: .orange)
                            profileDetailMetric(title: "Bio", value: bioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Missing" : "Ready", tint: .green)
                        }
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Profile Completion")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                Text(profileCompletionScore == 100 ? "Everything’s set." : "Finish the last missing details to complete your profile.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(profileCompletionScore == 100 ? "Done" : "\(profileCompletionScore)%")
                                .font(.system(size: 18, weight: .heavy, design: .rounded))
                                .foregroundStyle(profileCompletionScore == 100 ? .green : .orange)
                        }

                        ForEach(scoreCheckpoints, id: \.title) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(item.isComplete ? .green : .secondary)

                                Text(item.title)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))

                                Spacer()

                                Text(item.isComplete ? "Done" : "Missing")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(item.isComplete ? .green : .secondary)
                            }
                        }
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Identity")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text("These details stay private, but they shape how ChefBuddy talks to you and scores your profile.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        formField(
                            title: "Handle",
                            subtitle: "This becomes your private profile label.",
                            content: AnyView(
                                TextField("chefbuddy", text: $handleText)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            )
                        )

                        formField(
                            title: "Bio",
                            subtitle: "A short sentence about your cooking style.",
                            content: AnyView(
                                VStack(alignment: .leading, spacing: 8) {
                                    TextField("Tell ChefBuddy what kind of cook you are.", text: $bioText, axis: .vertical)
                                        .lineLimit(3...5)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 13)
                                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                                    HStack {
                                        Spacer()
                                        Text("\(bioText.count)/140")
                                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            )
                        )
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                    Button(action: {
                        onSave()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            dismiss()
                        }
                    }) {
                        HStack(spacing: 8) {
                            if isSavingIdentity {
                                ProgressView()
                                    .tint(.white)
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "checkmark")
                            }
                            Text("Save Profile")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(colors: [.orange, .green.opacity(0.86)], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
        }
    }

    private func profileDetailMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func formField(title: String, subtitle: String, content: AnyView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            content
        }
    }
}
