// User.swift
// Defines DBUser — the Firestore document model for a user's full profile.
// Stores authentication identifiers, physical metrics, dietary preferences,
// kitchen setup, and scheduling preferences.
// Used by AuthViewModel to read/write user data and by CookingAssistant
// to personalise every AI prompt with the user's actual preferences.

import Foundation
import FirebaseFirestore
import FirebaseAuth

enum NotificationSlotKind: String, Codable, CaseIterable {
    case pantry
    case mealPlan
    case inspiration

    var title: String {
        switch self {
        case .pantry: return "Pantry Nudges"
        case .mealPlan: return "Meal Plan Reminders"
        case .inspiration: return "Recipe Inspiration"
        }
    }
}

struct NotificationSlotPreference: Codable, Equatable, Identifiable {
    var slotId: String
    var title: String
    var hour: Int
    var minute: Int
    var isEnabled: Bool
    var kind: NotificationSlotKind

    var id: String { slotId }

    static var defaults: [NotificationSlotPreference] {
        [
            NotificationSlotPreference(slotId: "breakfast", title: "Breakfast", hour: 9, minute: 0, isEnabled: true, kind: .inspiration),
            NotificationSlotPreference(slotId: "afternoon", title: "Afternoon", hour: 14, minute: 0, isEnabled: true, kind: .pantry),
            NotificationSlotPreference(slotId: "evening", title: "Evening", hour: 18, minute: 0, isEnabled: true, kind: .mealPlan)
        ]
    }
}

enum NutritionTargetSource: String, Codable {
    case recommended
    case manual
}

struct NutritionTargets: Codable, Equatable {
    var calories: Int
    var carbs: Int
    var protein: Int
    var fat: Int
    var sodium: Int
    var source: NutritionTargetSource
    var updatedAt: Date

    static func validated(
        calories: Int,
        carbs: Int,
        protein: Int,
        fat: Int,
        sodium: Int,
        source: NutritionTargetSource,
        updatedAt: Date = Date()
    ) -> NutritionTargets {
        NutritionTargets(
            calories: min(max(calories, 800), 6000),
            carbs: min(max(carbs, 25), 800),
            protein: min(max(protein, 20), 400),
            fat: min(max(fat, 15), 300),
            sodium: min(max(sodium, 500), 6000),
            source: source,
            updatedAt: updatedAt
        )
    }
}

// Firestore document model for a user's full profile.
// Every field maps 1-to-1 to a Firestore key — Codable handles encoding
// automatically so we never write manual dictionary packing.
struct DBUser: Codable {
    let id: String
    let email: String?
    var dateCreated: Date


    var chefLevel: String
    var dietTags: [String]
    var allergies: [String]
    var macroTags: [String]


    var age: String
    var height: String
    var weight: String
    var sex: String
    var targetGoal: String
    var activityLevel: String


    var appliances: [String]


    var cookTime: String
    var mealPrep: Bool


    var cuisines: [String]
    var spiceTolerance: String
    var dislikes: String


    var servingSize: String
    var budget: String
    var measurementSystem: String?
    var goalPace: String?
    var cookingFrequency: String?
    var cleanupPreference: String?
    var leftoverPreference: String?
    var aiCoachingStyle: String?
    var aiCreativity: String?
    var dailyCalorieTarget: Int?
    var nutritionTargets: NutritionTargets?
    var activePantryId: String?
    var didCompleteNotificationOnboarding: Bool?
    var notificationsEnabled: Bool?
    var notificationAuthorizationStatus: String?
    var notificationPreferences: [NotificationSlotPreference]?
    var profileHandle: String?
    var profileBio: String?
    var xpTotal: Int?
    var rankTier: String?
    var currentStreak: Int?
    var longestStreak: Int?
    var lastActivityDate: Date?
    var lastStreakActivityDate: Date?
    var activityStats: [String: Int]?

    // Converts Firebase Auth user + onboarding form values into a storable
    // struct. Sets are converted to arrays because Firestore doesn't support Swift Sets.
    init(
        auth: FirebaseAuth.User,
        level: String,
        diets: Set<String>,
        allergy: Set<String>,
        macros: Set<String>,
        age: String,
        height: String,
        weight: String,
        sex: String,
        targetGoal: String,
        activityLevel: String,
        appliances: Set<String>,
        cookTime: String,
        mealPrep: Bool,
        cuisines: Set<String>,
        spiceTolerance: String,
        dislikes: String,
        servingSize: String,
        budget: String,
        measurementSystem: String = "🇺🇸 US cups & ounces",
        dailyCalorieTarget: Int? = nil,
        activePantryId: String? = nil,
        notificationPreferences: [NotificationSlotPreference] = NotificationSlotPreference.defaults
    ) {
        self.id = auth.uid
        self.email = auth.email
        self.dateCreated = Date()

        self.chefLevel = level
        self.dietTags = Array(diets)
        self.allergies = Array(allergy)
        self.macroTags = Array(macros)

        self.age = age
        self.height = height
        self.weight = weight
        self.sex = sex
        self.targetGoal = targetGoal
        self.activityLevel = activityLevel

        self.appliances = Array(appliances)

        self.cookTime = cookTime
        self.mealPrep = mealPrep

        self.cuisines = Array(cuisines)
        self.spiceTolerance = spiceTolerance
        self.dislikes = dislikes

        self.servingSize = servingSize
        self.budget = budget
        self.measurementSystem = measurementSystem
        self.goalPace = "🌱 Steady"
        self.cookingFrequency = "📅 3–4 days/week"
        self.cleanupPreference = "🧽 Balanced cleanup"
        self.leftoverPreference = "🥡 Enjoy leftovers"
        self.aiCoachingStyle = "🎯 Direct & practical"
        self.aiCreativity = "✨ Balanced"
        self.dailyCalorieTarget = dailyCalorieTarget
        self.nutritionTargets = dailyCalorieTarget.map {
            NutritionTargets.validated(
                calories: $0,
                carbs: 250,
                protein: 100,
                fat: 70,
                sodium: 2300,
                source: .recommended
            )
        }
        self.activePantryId = activePantryId
        self.didCompleteNotificationOnboarding = false
        self.notificationsEnabled = false
        self.notificationAuthorizationStatus = "not_determined"
        self.notificationPreferences = notificationPreferences
        self.profileHandle = auth.displayName ?? auth.email?.split(separator: "@").first.map(String.init) ?? "chefbuddy"
        self.profileBio = ""
        self.xpTotal = 0
        self.rankTier = "Line Cook"
        self.currentStreak = 0
        self.longestStreak = 0
        self.lastActivityDate = nil
        self.lastStreakActivityDate = nil
        self.activityStats = [:]
    }
}
