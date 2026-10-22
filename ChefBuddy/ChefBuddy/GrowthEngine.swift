import Foundation
import FirebaseFirestore
import SwiftUI

enum ActivityEventType: String, Codable, CaseIterable {
    case planAdd = "plan_add"
    case planComplete = "plan_complete"
    case mealLogged = "meal_logged"
    case swipeSave = "swipe_save"
    case swipeSkip = "swipe_skip"
    case recipeCooked = "recipe_cooked"
}

enum ChefBuddyUsageMetric: String {
    case liveCookingSeconds = "live_cooking_seconds"
    case recipeViewingSeconds = "recipe_viewing_seconds"
}

enum MealPlanSlotStatus: String, Codable, CaseIterable {
    case planned
    case cooked
    case logged
    case skipped

    var title: String {
        switch self {
        case .planned: return "Planned"
        case .cooked: return "Cooked"
        case .logged: return "Logged"
        case .skipped: return "Skipped"
        }
    }
}

enum MealPlanSourceType: String, Codable, CaseIterable {
    case saved
    case ai
    case custom
    case manual
}

enum MealLogInputMode: String, Codable, CaseIterable, Identifiable {
    case quick
    case photo
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: return "Quick + AI"
        case .photo: return "Photo + AI"
        case .manual: return "Manual"
        }
    }
}

struct MealLogEvent: Identifiable, Codable {
    var id: String?
    var day: String
    var mealType: String
    var title: String
    var notes: String
    var inputMode: String
    var calories: String
    var carbs: String
    var protein: String
    var fat: String
    var sodium: String
    var consumedAt: Date
    var createdAt: Date
    var isEstimated: Bool
    var confidence: String?
    var ingredients: [String]? = nil
    var steps: [String]? = nil
}

struct AchievementBadge: Identifiable, Codable {
    var id: String?
    var key: String
    var title: String
    var subtitle: String
    var icon: String
    var progress: Int
    var target: Int
    var isUnlocked: Bool
    var unlockedAt: Date?
    var milestones: [Int]? = nil
    var tierUnlockedAt: [String: Date]? = nil
}

enum AchievementTierLevel: String, CaseIterable, Codable, Identifiable {
    case bronze
    case silver
    case gold
    case platinum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bronze: return "Bronze"
        case .silver: return "Silver"
        case .gold: return "Gold"
        case .platinum: return "Platinum"
        }
    }
}

extension AchievementBadge {
    func xpReward(for tier: AchievementTierLevel) -> Int {
        switch tier {
        case .bronze:
            return 20
        case .silver:
            return 45
        case .gold:
            return 85
        case .platinum:
            return 140
        }
    }

    var currentTierXPReward: Int {
        xpReward(for: currentTier ?? .bronze)
    }

    func requirementLabel(for tier: AchievementTierLevel) -> String {
        let amount = milestone(for: tier)
        let noun: String

        switch key {
        case "first_plan", "week_builder":
            noun = amount == 1 ? "planned slot" : "planned slots"
        case "planner_pro":
            noun = amount == 1 ? "completed plan slot" : "completed plan slots"
        case "meal_logger", "daily_honesty":
            noun = amount == 1 ? "logged meal" : "logged meals"
        case "discovery_explorer", "flavor_scout":
            noun = amount == 1 ? "discovery swipe" : "discovery swipes"
        case "first_flame", "kitchen_regular":
            noun = amount == 1 ? "cooked recipe" : "cooked recipes"
        case "signature_dish":
            noun = amount == 1 ? "repeat cook on one recipe" : "repeat cooks on one recipe"
        case "recipe_collector", "recipe_archivist":
            noun = amount == 1 ? "saved recipe" : "saved recipes"
        case "favorite_curator":
            noun = amount == 1 ? "favorite recipe" : "favorite recipes"
        case "cuisine_hopper":
            noun = amount == 1 ? "cuisine explored" : "cuisines explored"
        case "profile_polished":
            noun = amount == 100 ? "profile fully set" : "profile score"
        case "streak_chef", "streak_master":
            noun = amount == 1 ? "streak day" : "streak days"
        case "rank_up", "executive_climb":
            noun = "XP"
        default:
            noun = amount == 1 ? "kitchen milestone" : "kitchen milestones"
        }

        if noun == "XP" {
            return "\(amount) XP"
        }

        return "\(amount) \(noun)"
    }

    var tierMilestones: [Int] {
        if let milestones, !milestones.isEmpty {
            return milestones
        }
        return [target]
    }

    var currentTier: AchievementTierLevel? {
        guard let index = tierMilestones.lastIndex(where: { progress >= $0 }) else { return nil }
        let clampedIndex = min(index, AchievementTierLevel.allCases.count - 1)
        return AchievementTierLevel.allCases[clampedIndex]
    }

    var nextTier: AchievementTierLevel? {
        guard let currentTier else { return AchievementTierLevel.allCases.first }
        guard let index = AchievementTierLevel.allCases.firstIndex(of: currentTier),
              index + 1 < AchievementTierLevel.allCases.count else { return nil }
        return AchievementTierLevel.allCases[index + 1]
    }

    var nextTarget: Int? {
        tierMilestones.first(where: { progress < $0 })
    }

    var isAtMaxTier: Bool {
        guard let last = tierMilestones.last else { return false }
        return progress >= last
    }

    var displayTier: AchievementTierLevel {
        currentTier ?? .bronze
    }

    func milestone(for tier: AchievementTierLevel) -> Int {
        let index = AchievementTierLevel.allCases.firstIndex(of: tier) ?? 0
        return tierMilestones[min(index, tierMilestones.count - 1)]
    }

    func unlockedDate(for tier: AchievementTierLevel) -> Date? {
        tierUnlockedAt?[tier.rawValue]
    }

    var earnedTiers: [AchievementTierLevel] {
        AchievementTierLevel.allCases.filter { progress >= milestone(for: $0) }
    }

    var tierProgressRatio: Double {
        let milestones = tierMilestones
        guard let first = milestones.first else { return 0 }
        if progress < first {
            return Double(progress) / Double(max(1, first))
        }

        if let currentTier, let tierIndex = AchievementTierLevel.allCases.firstIndex(of: currentTier) {
            let lowerBound = milestones[tierIndex]
            if tierIndex + 1 < milestones.count {
                let upperBound = milestones[tierIndex + 1]
                return Double(max(0, progress - lowerBound)) / Double(max(1, upperBound - lowerBound))
            }
        }

        return 1
    }
}

enum RankTier: String, CaseIterable, Codable {
    case lineCook = "Line Cook"
    case prepMaster = "Prep Master"
    case stationChef = "Station Chef"
    case sousChef = "Sous Chef"
    case executiveChef = "Executive Chef"
    case chefLegend = "Chef Legend"

    var icon: String {
        switch self {
        case .lineCook: return "flame.fill"
        case .prepMaster: return "fork.knife.circle.fill"
        case .stationChef: return "frying.pan.fill"
        case .sousChef: return "medal.fill"
        case .executiveChef: return "crown.fill"
        case .chefLegend: return "sparkles"
        }
    }

    var summary: String {
        switch self {
        case .lineCook: return "Build the habit with plans, meal logs, and your first completed recipes."
        case .prepMaster: return "Show consistency and start turning saved ideas into real meals."
        case .stationChef: return "Develop a dependable cooking rhythm across planning and discovery."
        case .sousChef: return "Prove range, repeatability, and stronger kitchen momentum."
        case .executiveChef: return "Lead your week with sustained cooking, planning, and exploration."
        case .chefLegend: return "ChefBuddy’s highest rank for a deeply established kitchen practice."
        }
    }

    var accent: Color {
        switch self {
        case .lineCook: return .orange
        case .prepMaster: return .green
        case .stationChef: return .blue
        case .sousChef: return .purple
        case .executiveChef: return .pink
        case .chefLegend: return .yellow
        }
    }

    static let thresholds: [(tier: RankTier, minXP: Int)] = [
        (.lineCook, 0),
        (.prepMaster, 120),
        (.stationChef, 320),
        (.sousChef, 650),
        (.executiveChef, 1100),
        (.chefLegend, 1700)
    ]

    static func tier(forXP xp: Int) -> RankTier {
        var current = RankTier.lineCook
        for checkpoint in thresholds where xp >= checkpoint.minXP {
            current = checkpoint.tier
        }
        return current
    }

    static func progress(forXP xp: Int) -> (current: RankTier, next: RankTier?, progress: Double) {
        let current = tier(forXP: xp)
        guard let currentIndex = thresholds.firstIndex(where: { $0.tier == current }) else {
            return (current, nil, 1)
        }
        let currentFloor = thresholds[currentIndex].minXP
        guard currentIndex + 1 < thresholds.count else {
            return (current, nil, 1)
        }
        let nextCheckpoint = thresholds[currentIndex + 1]
        let span = max(1, nextCheckpoint.minXP - currentFloor)
        let progressed = min(max(0, xp - currentFloor), span)
        return (current, nextCheckpoint.tier, Double(progressed) / Double(span))
    }
}

final class GrowthEngine {
    static let shared = GrowthEngine()

    private let db = Firestore.firestore()

    private static let streakEvents: Set<ActivityEventType> = [.planComplete, .mealLogged, .recipeCooked]

    private init() {}

    private static func calculatedXP(from stats: [String: Int]) -> Int {
        let planAdd = stats[ActivityEventType.planAdd.rawValue, default: 0] * 6
        let planComplete = stats[ActivityEventType.planComplete.rawValue, default: 0] * 20
        let mealLogged = stats[ActivityEventType.mealLogged.rawValue, default: 0] * 14
        let swipeSave = stats[ActivityEventType.swipeSave.rawValue, default: 0] * 8
        let swipeSkip = stats[ActivityEventType.swipeSkip.rawValue, default: 0] * 2
        let recipeCooked = stats[ActivityEventType.recipeCooked.rawValue, default: 0] * 24
        return planAdd + planComplete + mealLogged + swipeSave + swipeSkip + recipeCooked
    }

    func refreshDerivedProgress(userId: String) async {
        guard !userId.isEmpty else { return }

        do {
            let snapshot = try await db.collection("users").document(userId).getDocument()
            let data = snapshot.data() ?? [:]
            let storedStats = Self.decodeStats(data["activityStats"])
            let storedXP = data["xpTotal"] as? Int ?? 0
            let recoveredStats = (storedStats.isEmpty || storedXP == 0)
                ? await recoverHistoricalStats(userId: userId)
                : [:]
            let stats = Self.mergeStats(stored: storedStats, recovered: recoveredStats)
            let recalculatedXP = Self.calculatedXP(from: stats)
            let xp = max(storedXP, recalculatedXP)
            let storedStreak = data["currentStreak"] as? Int ?? 0
            let storedLongestStreak = data["longestStreak"] as? Int ?? 0
            let storedStreakDate = Self.decodeDate(data["lastStreakActivityDate"])
            let recoveredActivityDates = await recoverEligibleActivityDates(userId: userId)
            let recoveredStreakDate = recoveredActivityDates.max()
            let lastStreakActivityDate = storedStreakDate ?? recoveredStreakDate
            let recoveredSummary = Self.streakSummary(
                activityDates: recoveredActivityDates + [storedStreakDate].compactMap { $0 },
                now: Date()
            )
            let currentStreak = recoveredActivityDates.isEmpty
                ? Self.refreshedStreakValue(
                    lastActivityDate: lastStreakActivityDate,
                    now: Date(),
                    currentValue: storedStreak
                )
                : recoveredSummary.current
            let longestStreak = max(storedLongestStreak, recoveredSummary.longest, currentStreak)

            let rank = RankTier.tier(forXP: xp).rawValue
            if xp != storedXP ||
                (data["rankTier"] as? String) != rank ||
                stats != storedStats ||
                currentStreak != storedStreak ||
                longestStreak != storedLongestStreak ||
                (storedStreakDate == nil && lastStreakActivityDate != nil) {
                var payload: [String: Any] = [
                    "xpTotal": xp,
                    "rankTier": rank,
                    "currentStreak": currentStreak,
                    "longestStreak": longestStreak
                ]
                if stats != storedStats {
                    payload["activityStats"] = stats
                }
                if let lastStreakActivityDate {
                    payload["lastStreakActivityDate"] = lastStreakActivityDate
                }
                try await db.collection("users").document(userId).setData(payload, merge: true)
            }

            await syncAchievements(userId: userId, stats: stats, xp: xp, currentStreak: currentStreak)
        } catch {
            print("Failed to refresh derived progress: \(error.localizedDescription)")
        }
    }

    func logActivity(
        userId: String,
        type: ActivityEventType,
        eventKey: String? = nil,
        metadata: [String: String] = [:]
    ) async {
        guard !userId.isEmpty else { return }

        let eventsCollection = db.collection("users").document(userId).collection("activityEvents")
        let eventRef: DocumentReference = eventKey.map { eventsCollection.document($0) } ?? eventsCollection.document()
        let recoveredStreakDate = Self.streakEvents.contains(type)
            ? await recoverLatestEligibleActivityDate(userId: userId)
            : nil

        do {
            if eventKey != nil {
                let existing = try await eventRef.getDocument()
                if existing.exists { return }
            }
        } catch {
            print("Activity event dedupe check failed: \(error.localizedDescription)")
        }

        var statsSnapshot: [String: Int] = [:]
        var xpSnapshot = 0
        var streakSnapshot = 0
        do {
            _ = try await db.runTransaction { [weak self] transaction, errorPointer -> Any? in
                guard let self else { return nil }
                let userRef = self.db.collection("users").document(userId)

                let userDocument: DocumentSnapshot
                do {
                    userDocument = try transaction.getDocument(userRef)
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }

                let data = userDocument.data() ?? [:]
                var stats = Self.decodeStats(data["activityStats"])
                stats[type.rawValue, default: 0] += 1

                let storedXP = data["xpTotal"] as? Int ?? 0
                let recalculatedXP = Self.calculatedXP(from: stats)
                let xp = max(storedXP + self.points(for: type), recalculatedXP)

                var currentStreak = data["currentStreak"] as? Int ?? 0
                var longestStreak = data["longestStreak"] as? Int ?? 0
                let lastStreakActivityDate =
                    Self.decodeDate(data["lastStreakActivityDate"]) ??
                    recoveredStreakDate
                let now = Date()

                if Self.streakEvents.contains(type) {
                    currentStreak = Self.nextStreakValue(
                        lastActivityDate: lastStreakActivityDate,
                        now: now,
                        currentValue: currentStreak
                    )
                    longestStreak = max(longestStreak, currentStreak)
                }

                let rank = RankTier.tier(forXP: xp).rawValue

                var userPayload: [String: Any] = [
                    "xpTotal": xp,
                    "rankTier": rank,
                    "currentStreak": currentStreak,
                    "longestStreak": longestStreak,
                    "lastActivityDate": now,
                    "activityStats": stats
                ]
                if Self.streakEvents.contains(type) {
                    userPayload["lastStreakActivityDate"] = now
                }
                transaction.setData(userPayload, forDocument: userRef, merge: true)

                var eventPayload: [String: Any] = [
                    "type": type.rawValue,
                    "createdAt": now
                ]
                if !metadata.isEmpty {
                    eventPayload["metadata"] = metadata
                }
                transaction.setData(eventPayload, forDocument: eventRef, merge: false)

                statsSnapshot = stats
                xpSnapshot = xp
                streakSnapshot = currentStreak
                return nil
            }

            await syncAchievements(
                userId: userId,
                stats: statsSnapshot,
                xp: xpSnapshot,
                currentStreak: streakSnapshot
            )
        } catch {
            print("Failed to log activity event \(type.rawValue): \(error.localizedDescription)")
        }
    }

    private func points(for event: ActivityEventType) -> Int {
        switch event {
        case .planAdd:
            return 6
        case .planComplete:
            return 20
        case .mealLogged:
            return 14
        case .swipeSave:
            return 8
        case .swipeSkip:
            return 2
        case .recipeCooked:
            return 24
        }
    }

    private func recoverHistoricalStats(userId: String) async -> [String: Int] {
        var recovered: [String: Int] = [:]
        let userRef = db.collection("users").document(userId)

        do {
            let recipesSnapshot = try await userRef.collection("recipes").getDocuments()
            let cookedEvents = recipesSnapshot.documents.reduce(0) { partial, document in
                partial + max(0, document.data()["cookedCount"] as? Int ?? 0)
            }
            if cookedEvents > 0 {
                recovered[ActivityEventType.recipeCooked.rawValue] = cookedEvents
            }
        } catch {
            print("Failed to recover cooked recipe stats: \(error.localizedDescription)")
        }

        do {
            let logsSnapshot = try await userRef.collection("mealLogEvents").getDocuments()
            if !logsSnapshot.documents.isEmpty {
                recovered[ActivityEventType.mealLogged.rawValue] = logsSnapshot.documents.count
            }
        } catch {
            print("Failed to recover meal log stats: \(error.localizedDescription)")
        }

        do {
            let feedbackSnapshot = try await userRef.collection("discoveryFeedback").getDocuments()
            var swipeSave = 0
            var swipeSkip = 0

            for document in feedbackSnapshot.documents {
                let action = (document.data()["action"] as? String ?? "").lowercased()
                if action == "saved" {
                    swipeSave += 1
                } else if action == "skipped" {
                    swipeSkip += 1
                }
            }

            if swipeSave > 0 {
                recovered[ActivityEventType.swipeSave.rawValue] = swipeSave
            }
            if swipeSkip > 0 {
                recovered[ActivityEventType.swipeSkip.rawValue] = swipeSkip
            }
        } catch {
            print("Failed to recover swipe stats: \(error.localizedDescription)")
        }

        do {
            let mealPlanSnapshot = try await userRef.collection("mealPlan").getDocuments()
            var planAdd = 0
            var planComplete = 0

            for document in mealPlanSnapshot.documents {
                let data = document.data()
                let hasPlannedMeal =
                    (data["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
                    (data["displayTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
                    data["plannedRecipe"] != nil

                if hasPlannedMeal {
                    planAdd += 1
                }

                let status = (data["status"] as? String ?? "").lowercased()
                if status == "cooked" || status == "logged" {
                    planComplete += 1
                }
            }

            if planAdd > 0 {
                recovered[ActivityEventType.planAdd.rawValue] = planAdd
            }
            if planComplete > 0 {
                recovered[ActivityEventType.planComplete.rawValue] = planComplete
            }
        } catch {
            print("Failed to recover meal-plan stats: \(error.localizedDescription)")
        }

        return recovered
    }

    private func recoverEligibleActivityDates(userId: String) async -> [Date] {
        let userRef = db.collection("users").document(userId)
        var candidates: [Date] = []

        do {
            let events = try await userRef.collection("activityEvents").getDocuments()
            for document in events.documents {
                let data = document.data()
                guard let rawType = data["type"] as? String,
                      let type = ActivityEventType(rawValue: rawType),
                      Self.streakEvents.contains(type),
                      let date = Self.decodeDate(data["createdAt"]) else { continue }
                candidates.append(date)
            }
        } catch {
            print("Failed to recover streak activity events: \(error.localizedDescription)")
        }

        do {
            let recipes = try await userRef.collection("recipes").getDocuments()
            candidates.append(contentsOf: recipes.documents.compactMap {
                Self.decodeDate($0.data()["lastCookedAt"])
            })
        } catch {
            print("Failed to recover streak recipe dates: \(error.localizedDescription)")
        }

        do {
            let plan = try await userRef.collection("mealPlan").getDocuments()
            candidates.append(contentsOf: plan.documents.compactMap { document in
                let data = document.data()
                let status = (data["status"] as? String ?? "").lowercased()
                guard status == MealPlanSlotStatus.cooked.rawValue ||
                        status == MealPlanSlotStatus.logged.rawValue else { return nil }
                return Self.decodeDate(data["completedAt"])
            })
        } catch {
            print("Failed to recover streak meal-plan dates: \(error.localizedDescription)")
        }

        return candidates
    }

    private func recoverLatestEligibleActivityDate(userId: String) async -> Date? {
        await recoverEligibleActivityDates(userId: userId).max()
    }

    private static func mergeStats(stored: [String: Int], recovered: [String: Int]) -> [String: Int] {
        var merged = stored
        for (key, value) in recovered {
            merged[key] = max(merged[key, default: 0], value)
        }
        return merged
    }

    static func badgeCatalog(
        recipeCount: Int,
        favoriteCount: Int,
        maxCookedCount: Int,
        distinctCuisineCount: Int,
        profileCompletionScore: Int,
        swipeDecisionCount: Int,
        planCompleteCount: Int,
        planAddCount: Int,
        mealLogCount: Int,
        recipeCookedCount: Int,
        xp: Int,
        currentStreak: Int,
        unlockedAtLookup: [String: Date] = [:],
        tierUnlockedAtLookup: [String: [String: Date]] = [:]
    ) -> [AchievementBadge] {
        let specs: [(key: String, title: String, subtitle: String, icon: String, progress: Int, milestones: [Int])] = [
            ("first_plan", "First Plate Planned", "Add meal-plan slots and turn planning into a real habit.", "calendar.badge.plus", planAddCount, [1, 5, 15, 40]),
            ("planner_pro", "Planner Pro", "Complete planned meals consistently throughout the week.", "checklist", planCompleteCount, [3, 10, 25, 60]),
            ("week_builder", "Week Builder", "Shape bigger weekly plans instead of planning one meal at a time.", "calendar", planAddCount, [7, 21, 50, 120]),
            ("meal_logger", "Reality Tracker", "Log what you actually ate so ChefBuddy learns the real pattern.", "square.and.pencil", mealLogCount, [2, 7, 20, 45]),
            ("daily_honesty", "Daily Honesty", "Keep nutrition honest with regular real-world meal logs.", "list.clipboard.fill", mealLogCount, [5, 20, 40, 90]),
            ("discovery_explorer", "Discovery Explorer", "Train discovery by making plenty of swipe decisions.", "sparkles", swipeDecisionCount, [10, 25, 60, 140]),
            ("flavor_scout", "Flavor Scout", "Keep tasting beyond your defaults and teach ChefBuddy range.", "safari.fill", swipeDecisionCount, [20, 50, 120, 250]),
            ("first_flame", "First Flame", "Cook saved recipes instead of just collecting them.", "flame", recipeCookedCount, [1, 5, 15, 35]),
            ("kitchen_regular", "Kitchen Regular", "Build a real cooking rhythm inside ChefBuddy.", "fork.knife.circle.fill", recipeCookedCount, [3, 10, 25, 60]),
            ("signature_dish", "Signature Dish", "Repeat dishes enough to form real staples.", "house.fill", maxCookedCount, [2, 3, 5, 8]),
            ("recipe_collector", "Recipe Collector", "Grow your recipe library into something worth browsing.", "books.vertical.fill", recipeCount, [5, 15, 50, 100]),
            ("recipe_archivist", "Recipe Archivist", "Build a deep recipe bench for every mood and night.", "folder.fill.badge.plus", recipeCount, [10, 25, 75, 150]),
            ("favorite_curator", "Favorite Curator", "Mark the recipes that actually belong in your core rotation.", "heart.circle.fill", favoriteCount, [3, 10, 25, 60]),
            ("cuisine_hopper", "Cuisine Hopper", "Explore enough cuisines to become a more adventurous cook.", "globe.americas.fill", distinctCuisineCount, [2, 5, 10, 18]),
            ("profile_polished", "Kitchen Setup", "Complete the cooking preferences and nutrition targets that power personalization.", "slider.horizontal.3", profileCompletionScore, [20, 40, 80, 100]),
            ("streak_chef", "Streak Chef", "Show up regularly and keep your streak alive.", "flame.fill", currentStreak, [3, 7, 14, 30]),
            ("streak_master", "Streak Master", "Turn consistency into a longer-term rhythm.", "bolt.heart.fill", currentStreak, [7, 21, 45, 90]),
            ("rank_up", "Rising Rank", "Earn XP through real kitchen activity and climb tiers.", "star.circle.fill", xp, [120, 350, 800, 1500]),
            ("executive_climb", "Executive Climb", "Push toward ChefBuddy's highest kitchen ranks.", "crown.fill", xp, [300, 700, 1200, 2000]),
            ("pantry_planner", "Pantry Planner", "Turn stocked ingredients into meals you actually schedule.", "basket.fill", planAddCount, [3, 12, 35, 80]),
            ("weeknight_winner", "Weeknight Winner", "Complete practical planned meals when the week is busiest.", "moon.stars.fill", planCompleteCount, [5, 15, 40, 100]),
            ("taste_trainer", "Taste Trainer", "Teach ChefBuddy your preferences through discovery decisions.", "hand.draw.fill", swipeDecisionCount, [15, 45, 100, 220]),
            ("cookbook_builder", "Cookbook Builder", "Save enough useful recipes to create a personal cooking library.", "book.closed.fill", recipeCount, [8, 24, 60, 140]),
            ("favorite_five", "Favorite Five", "Build a dependable rotation of recipes you genuinely love.", "heart.fill", favoriteCount, [5, 12, 30, 75]),
            ("world_table", "World Table", "Bring more cuisines and cooking traditions into your kitchen.", "globe.desk.fill", distinctCuisineCount, [3, 7, 14, 24]),
            ("repeat_request", "Repeat Request", "Cook a favorite often enough for it to become a household request.", "arrow.triangle.2.circlepath", maxCookedCount, [2, 4, 7, 12]),
            ("counter_confidence", "Counter Confidence", "Build confidence by completing more recipes from start to finish.", "figure.strengthtraining.traditional", recipeCookedCount, [5, 18, 45, 100]),
            ("nutrition_navigator", "Nutrition Navigator", "Keep planning and real meal logs connected to your goals.", "chart.line.uptrend.xyaxis", mealLogCount, [7, 21, 60, 150]),
            ("kitchen_legend", "Kitchen Legend", "Combine consistency, planning, and cooking into lasting momentum.", "medal.star.fill", xp, [500, 1100, 2200, 4000])
        ]

        return specs.map { spec in
            let highestTarget = spec.milestones.last ?? 1
            let unlocked = spec.progress >= (spec.milestones.first ?? highestTarget)
            return AchievementBadge(
                id: spec.key,
                key: spec.key,
                title: spec.title,
                subtitle: spec.subtitle,
                icon: spec.icon,
                progress: min(spec.progress, highestTarget),
                target: highestTarget,
                isUnlocked: unlocked,
                unlockedAt: unlockedAtLookup[spec.key],
                milestones: spec.milestones,
                tierUnlockedAt: tierUnlockedAtLookup[spec.key]
            )
        }
    }

    private func syncAchievements(
        userId: String,
        stats: [String: Int],
        xp: Int,
        currentStreak: Int
    ) async {
        let userRef = db.collection("users").document(userId)
        let achievementsRef = userRef.collection("achievements")

        var profileData: [String: Any] = [:]
        var recipeDocuments: [QueryDocumentSnapshot] = []

        do {
            let userSnapshot = try await userRef.getDocument()
            profileData = userSnapshot.data() ?? [:]
        } catch {
            print("Failed to load profile for achievements: \(error.localizedDescription)")
        }

        do {
            let recipeSnapshot = try await userRef.collection("recipes").getDocuments()
            recipeDocuments = recipeSnapshot.documents
        } catch {
            print("Failed to load recipes for achievements: \(error.localizedDescription)")
        }

        let recipeCount = recipeDocuments.count
        let favoriteCount = recipeDocuments.reduce(0) { partial, document in
            partial + ((document.data()["isFavorite"] as? Bool) == true ? 1 : 0)
        }
        let maxCookedCount = recipeDocuments.reduce(0) { partial, document in
            max(partial, document.data()["cookedCount"] as? Int ?? 0)
        }
        let distinctCuisineCount: Int = {
            var cuisines: Set<String> = []
            for document in recipeDocuments {
                let tags = document.data()["tags"] as? [String] ?? []
                for tag in tags {
                    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    cuisines.insert(trimmed.lowercased())
                }
            }
            return cuisines.count
        }()

        let profileCompletionScore: Int = {
            var score = 0
            let cuisines = profileData["cuisines"] as? [String] ?? []
            let macroTags = profileData["macroTags"] as? [String] ?? []
            let appliances = profileData["appliances"] as? [String] ?? []
            let diets = profileData["dietTags"] as? [String] ?? []
            let nutritionTargets = profileData["nutritionTargets"] as? [String: Any]

            if !cuisines.isEmpty { score += 1 }
            if !macroTags.isEmpty { score += 1 }
            if !appliances.isEmpty { score += 1 }
            if !diets.isEmpty { score += 1 }
            if nutritionTargets != nil { score += 1 }

            return Int((Double(score) / 5.0 * 100.0).rounded())
        }()

        let swipeDecisionCount = stats[ActivityEventType.swipeSave.rawValue, default: 0] + stats[ActivityEventType.swipeSkip.rawValue, default: 0]
        let planCompleteCount = stats[ActivityEventType.planComplete.rawValue, default: 0]
        let planAddCount = stats[ActivityEventType.planAdd.rawValue, default: 0]
        let mealLogCount = stats[ActivityEventType.mealLogged.rawValue, default: 0]
        let recipeCookedCount = stats[ActivityEventType.recipeCooked.rawValue, default: 0]

        var previouslyUnlockedDates: [String: Date] = [:]
        var previouslyTierUnlockedDates: [String: [String: Date]] = [:]
        var existingDocuments: [QueryDocumentSnapshot] = []
        do {
            let existing = try await achievementsRef.getDocuments()
            existingDocuments = existing.documents
            for doc in existing.documents {
                let data = doc.data()
                if let tierMap = Self.decodeTierUnlockedAt(data["tierUnlockedAt"]) {
                    previouslyTierUnlockedDates[doc.documentID] = tierMap
                }
                guard
                    (data["isUnlocked"] as? Bool) == true,
                    let key = data["key"] as? String
                else { continue }

                if let timestamp = data["unlockedAt"] as? Timestamp {
                    previouslyUnlockedDates[key] = timestamp.dateValue()
                } else if let date = data["unlockedAt"] as? Date {
                    previouslyUnlockedDates[key] = date
                }
            }
        } catch {
            print("Failed to read existing achievements: \(error.localizedDescription)")
        }

        let badges = Self.badgeCatalog(
            recipeCount: recipeCount,
            favoriteCount: favoriteCount,
            maxCookedCount: maxCookedCount,
            distinctCuisineCount: distinctCuisineCount,
            profileCompletionScore: profileCompletionScore,
            swipeDecisionCount: swipeDecisionCount,
            planCompleteCount: planCompleteCount,
            planAddCount: planAddCount,
            mealLogCount: mealLogCount,
            recipeCookedCount: recipeCookedCount,
            xp: xp,
            currentStreak: currentStreak,
            unlockedAtLookup: previouslyUnlockedDates,
            tierUnlockedAtLookup: previouslyTierUnlockedDates
        )

        let activeKeys = Set(badges.map(\.key))

        for document in existingDocuments where !activeKeys.contains(document.documentID) {
            do {
                try await achievementsRef.document(document.documentID).delete()
            } catch {
                print("Failed to remove retired achievement \(document.documentID): \(error.localizedDescription)")
            }
        }

        for badge in badges {
            var tierDates = badge.tierUnlockedAt ?? [:]
            let now = Date()
            let legacyDate = badge.unlockedAt

            if tierDates.isEmpty, let legacyDate {
                for tier in badge.earnedTiers {
                    tierDates[tier.rawValue] = legacyDate
                }
            }

            for tier in badge.earnedTiers where tierDates[tier.rawValue] == nil {
                tierDates[tier.rawValue] = now
            }

            var payload: [String: Any] = [
                "key": badge.key,
                "title": badge.title,
                "subtitle": badge.subtitle,
                "icon": badge.icon,
                "progress": badge.progress,
                "target": badge.target,
                "isUnlocked": badge.isUnlocked,
                "milestones": badge.milestones ?? [],
                "tierUnlockedAt": tierDates
            ]

            if let unlockedAt = tierDates[AchievementTierLevel.bronze.rawValue] ?? badge.unlockedAt {
                payload["unlockedAt"] = unlockedAt
            } else if badge.isUnlocked {
                payload["unlockedAt"] = now
            }

            do {
                try await achievementsRef.document(badge.key).setData(payload, merge: true)
            } catch {
                print("Failed to upsert achievement \(badge.key): \(error.localizedDescription)")
            }
        }
    }

    private static func decodeTierUnlockedAt(_ rawValue: Any?) -> [String: Date]? {
        guard let rawMap = rawValue as? [String: Any], !rawMap.isEmpty else { return nil }

        var resolved: [String: Date] = [:]
        for (key, value) in rawMap {
            if let timestamp = value as? Timestamp {
                resolved[key] = timestamp.dateValue()
            } else if let date = value as? Date {
                resolved[key] = date
            }
        }

        return resolved.isEmpty ? nil : resolved
    }

    private static func decodeStats(_ raw: Any?) -> [String: Int] {
        guard let dictionary = raw as? [String: Any] else { return [:] }
        var result: [String: Int] = [:]
        for (key, value) in dictionary {
            if let intValue = value as? Int {
                result[key] = intValue
            } else if let number = value as? NSNumber {
                result[key] = number.intValue
            }
        }
        return result
    }

    private static func decodeDate(_ raw: Any?) -> Date? {
        if let timestamp = raw as? Timestamp {
            return timestamp.dateValue()
        }
        return raw as? Date
    }

    static func nextStreakValue(lastActivityDate: Date?, now: Date, currentValue: Int) -> Int {
        let calendar = Calendar.current
        guard let lastActivityDate else { return 1 }

        let startLast = calendar.startOfDay(for: lastActivityDate)
        let startNow = calendar.startOfDay(for: now)
        let delta = calendar.dateComponents([.day], from: startLast, to: startNow).day ?? 0

        if delta <= 0 {
            return max(1, currentValue)
        }
        if delta == 1 {
            return max(1, currentValue + 1)
        }
        return 1
    }

    static func refreshedStreakValue(lastActivityDate: Date?, now: Date, currentValue: Int) -> Int {
        guard let lastActivityDate else { return 0 }
        let calendar = Calendar.current
        let startLast = calendar.startOfDay(for: lastActivityDate)
        let startNow = calendar.startOfDay(for: now)
        let delta = calendar.dateComponents([.day], from: startLast, to: startNow).day ?? 0

        if delta <= 1 {
            return max(currentValue, 1)
        }
        return 0
    }

    static func streakSummary(
        activityDates: [Date],
        now: Date,
        calendar: Calendar = .current
    ) -> (current: Int, longest: Int) {
        let uniqueDays = Set(activityDates.map { calendar.startOfDay(for: $0) }).sorted()
        guard !uniqueDays.isEmpty else { return (0, 0) }

        var longest = 1
        var run = 1
        for index in 1..<uniqueDays.count {
            let previous = uniqueDays[index - 1]
            let current = uniqueDays[index]
            let delta = calendar.dateComponents([.day], from: previous, to: current).day ?? 0
            if delta == 1 {
                run += 1
                longest = max(longest, run)
            } else if delta > 1 {
                run = 1
            }
        }

        let today = calendar.startOfDay(for: now)
        guard let latest = uniqueDays.last else { return (0, longest) }
        let latestDelta = calendar.dateComponents([.day], from: latest, to: today).day ?? 0
        guard latestDelta == 0 || latestDelta == 1 else {
            return (0, longest)
        }

        var currentStreak = 1
        var cursor = latest
        for date in uniqueDays.dropLast().reversed() {
            let delta = calendar.dateComponents([.day], from: date, to: cursor).day ?? 0
            guard delta == 1 else { break }
            currentStreak += 1
            cursor = date
        }

        return (currentStreak, max(longest, currentStreak))
    }
}

enum ChefBuddyUsageStats {
    static func recordSession(userId: String, metric: ChefBuddyUsageMetric, startedAt: Date?) {
        guard !userId.isEmpty, let startedAt else { return }
        let seconds = max(1, Int(Date().timeIntervalSince(startedAt).rounded()))
        Firestore.firestore()
            .collection("users")
            .document(userId)
            .setData(
                ["activityStats.\(metric.rawValue)": FieldValue.increment(Int64(seconds))],
                merge: true
            )
    }
}
