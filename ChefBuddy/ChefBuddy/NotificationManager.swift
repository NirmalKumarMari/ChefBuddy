import Foundation
import FirebaseAuth
import FirebaseFirestore
import SwiftUI
import UserNotifications
import Combine
import UIKit

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var isScheduling = false

    private let center = UNUserNotificationCenter.current()
    private let db = Firestore.firestore()
    private let notificationIdentifierPrefix = "chefbuddy.daily"

    private init() {
        Task {
            await refreshAuthorizationStatus()
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func disableNotifications() async {
        let identifiers = pendingNotificationIdentifiers()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        clearBadgeCount()
        notificationsEnabled = false
        await refreshAuthorizationStatus()
    }

    @discardableResult
    func requestNotifications(for profile: DBUser, userId: String) async -> Bool {
        isScheduling = true
        defer { isScheduling = false }

        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            granted = false
        }

        await refreshAuthorizationStatus()

        if granted {
            await scheduleDailyNotifications(for: profile, userId: userId)
        } else {
            await disableNotifications()
        }

        return granted
    }

    func rescheduleNotificationsIfPossible(profile: DBUser?, userId: String?) async {
        guard let profile, let userId else { return }
        await refreshAuthorizationStatus()
        let userEnabledNotifications = profile.notificationsEnabled ?? false
        notificationsEnabled = userEnabledNotifications
        guard userEnabledNotifications else { return }
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        await scheduleDailyNotifications(for: profile, userId: userId)
    }

    private func pendingNotificationIdentifiers() -> [String] {
        let offsets = Array(0..<7)
        let slots = NotificationSlotPreference.defaults.map(\.slotId)
        return offsets.flatMap { dayOffset in
            slots.map { "\(notificationIdentifierPrefix).\($0).\(dayOffset)" }
        }
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func scheduleDailyNotifications(for profile: DBUser, userId: String) async {
        isScheduling = true
        defer { isScheduling = false }

        let identifiers = pendingNotificationIdentifiers()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        clearBadgeCount()

        let snapshot = await fetchKitchenSnapshot(userId: userId)
        let calendar = Calendar.current
        let baseDate = Date()
        let notificationTimes = resolvedPreferences(from: profile)
            .filter(\.isEnabled)

        for dayOffset in 0..<7 {
            guard let scheduledDate = calendar.date(byAdding: .day, value: dayOffset, to: baseDate) else { continue }

            for notificationTime in notificationTimes {
                let content = makeNotificationContent(
                    slot: notificationTime,
                    dayOffset: dayOffset,
                    profile: profile,
                    snapshot: snapshot
                )

                var components = calendar.dateComponents([.year, .month, .day], from: scheduledDate)
                components.hour = notificationTime.hour
                components.minute = notificationTime.minute

                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(
                    identifier: "\(notificationIdentifierPrefix).\(notificationTime.slotId).\(dayOffset)",
                    content: content,
                    trigger: trigger
                )

                do {
                    try await center.add(request)
                } catch {
                    continue
                }
            }
        }

        notificationsEnabled = true
        clearBadgeCount()
    }

    func updatePreferences(
        profile: DBUser,
        userId: String,
        preferences: [NotificationSlotPreference],
        isEnabled: Bool
    ) async {
        notificationsEnabled = isEnabled
        await refreshAuthorizationStatus()

        if isEnabled, (authorizationStatus == .authorized || authorizationStatus == .provisional) {
            var updatedProfile = profile
            updatedProfile.notificationsEnabled = isEnabled
            updatedProfile.notificationPreferences = preferences
            await scheduleDailyNotifications(for: updatedProfile, userId: userId)
        } else {
            await disableNotifications()
        }
    }

    private func fetchKitchenSnapshot(userId: String) async -> KitchenSnapshot {
        async let pantrySpacesTask = db.collection("users")
            .document(userId)
            .collection("pantrySpaces")
            .getDocuments()

        async let mealPlanTask = db.collection("users")
            .document(userId)
            .collection("mealPlan")
            .getDocuments()

        let pantryCount: Int
        let mealPlanCount: Int

        do {
            let pantrySnapshot = try await pantrySpacesTask
            pantryCount = pantrySnapshot.documents.reduce(0) { partial, document in
                let pantry = document.data()["virtualPantry"] as? [String: [String]] ?? [:]
                return partial + pantry.values.flatMap { $0 }.count
            }
        } catch {
            pantryCount = 0
        }

        do {
            let planSnapshot = try await mealPlanTask
            mealPlanCount = planSnapshot.documents.filter { document in
                let title = (document.data()["recipeTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !title.isEmpty
            }.count
        } catch {
            mealPlanCount = 0
        }

        return KitchenSnapshot(pantryIngredientCount: pantryCount, plannedMealsCount: mealPlanCount)
    }

    private func makeNotificationContent(
        slot: NotificationSlotPreference,
        dayOffset: Int,
        profile: DBUser,
        snapshot: KitchenSnapshot
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let servings = profile.servingSize.isEmpty ? "your crew" : profile.servingSize.replacingOccurrences(of: "👤 ", with: "")
        let cuisines = profile.cuisines.isEmpty ? "something delicious" : profile.cuisines.joined(separator: ", ")
        let calorieText = profile.dailyCalorieTarget.map { "\($0) cal" } ?? "your goal"

        let pantryMessages = [
            ("Your pantry has dinner 👀", "\(snapshot.pantryIngredientCount) ingredients are ready. Let’s turn them into \(cuisines.lowercased())."),
            ("Cook what you have", "A pantry-first recipe for \(servings.lowercased()) is one tap away."),
            ("Pantry win incoming ✨", "Turn what’s on your shelves into a real meal."),
            ("Skip the grocery run", "Your pantry may already have tonight covered."),
            ("Dinner is in the house", "Open ChefBuddy and make the most of what you own.")
        ]

        let mealPlanMessages = [
            ("Tonight is already planned", "\(snapshot.plannedMealsCount) meals are queued. Pick one and cook."),
            ("Keep the streak alive 🔥", "Open today’s plan and finish one meal."),
            ("One less decision", "Your next planned meal is ready when you are."),
            ("Your next meal is queued", "Open the plan and stay close to \(calorieText)."),
            ("Dinner, minus the guesswork", "Your day plan is ready to cook.")
        ]

        let generalMessages = [
            ("What are we cooking? 🍳", "Get one idea that fits your taste and kitchen."),
            ("Craving → recipe", "Tell ChefBuddy the vibe. We’ll build the meal."),
            ("Dinner decision: solved", "Open ChefBuddy for a quick, realistic recipe."),
            ("Good food can be easy", "Find a meal that fits your time and \(calorieText)."),
            ("Make the craving real", "Your next personalized recipe is one tap away.")
        ]

        let pool: [(String, String)]
        switch slot.kind {
        case .pantry:
            pool = snapshot.pantryIngredientCount > 0 ? pantryMessages : generalMessages
        case .mealPlan:
            pool = snapshot.plannedMealsCount > 0 ? mealPlanMessages : generalMessages
        case .inspiration:
            pool = generalMessages
        }

        let stableKey = "\(slot.slotId)-\(slot.kind.rawValue)"
        let slotOffset = stableKey.unicodeScalars.reduce(0) { partial, scalar in
            partial + Int(scalar.value)
        }
        let selected = pool[(dayOffset + slotOffset) % pool.count]
        content.title = selected.0
        content.body = selected.1
        content.sound = .default
        content.userInfo = ["slot": slot.slotId, "kind": slot.kind.rawValue]
        return content
    }

    private func resolvedPreferences(from profile: DBUser) -> [NotificationSlotPreference] {
        let stored = profile.notificationPreferences ?? []
        if stored.isEmpty {
            return NotificationSlotPreference.defaults
        }

        var merged: [NotificationSlotPreference] = []
        for fallback in NotificationSlotPreference.defaults {
            if let match = stored.first(where: { $0.slotId == fallback.slotId }) {
                merged.append(match)
            } else {
                merged.append(fallback)
            }
        }
        return merged
    }

    func clearBadgeCount() {
        UIApplication.shared.applicationIconBadgeNumber = 0
    }
}

private struct KitchenSnapshot {
    let pantryIngredientCount: Int
    let plannedMealsCount: Int
}
