// MealPlan.swift
// Meal planning feature — lets users schedule recipes across a week.
// Persists plan data to Firestore so it survives app restarts and can
// later be used to auto-generate a grocery list from planned meals.

import SwiftUI
import FirebaseFirestore
import FirebaseAuth
import Combine
import PhotosUI

private extension Calendar {
    func weekdayName(for date: Date) -> String {
        let weekday = component(.weekday, from: date)
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[max(0, min(names.count - 1, weekday - 1))]
    }
}

enum MealPlanDisplayMode: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"

    var id: String { rawValue }
}

func mealPlanWeekDates(
    containing date: Date,
    calendar sourceCalendar: Calendar = .current
) -> [(day: String, date: Date)] {
    var calendar = sourceCalendar
    calendar.firstWeekday = 2
    let start = calendar.startOfDay(for: date)
    let weekday = calendar.component(.weekday, from: start)
    let daysSinceMonday = (weekday + 5) % 7
    guard let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: start) else { return [] }

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEEE"

    return (0..<7).compactMap { offset in
        guard let dayDate = calendar.date(byAdding: .day, value: offset, to: monday) else { return nil }
        return (formatter.string(from: dayDate), dayDate)
    }
}

struct PlannedMealRecipe: Codable, Equatable {
    var title: String
    var emoji: String
    var description: String
    var ingredients: [String]
    var steps: [String]
    var cookTime: String
    var servings: String
    var difficulty: String
    var tags: [String]
    var calories: String
    var nutrition: NutritionInfo

    init(recipe: Recipe) {
        self.title = recipe.title
        self.emoji = recipe.emoji
        self.description = recipe.description
        self.ingredients = recipe.ingredients
        self.steps = recipe.steps
        self.cookTime = recipe.cookTime
        self.servings = recipe.servings
        self.difficulty = recipe.difficulty
        self.tags = recipe.tags
        self.calories = recipe.calories
        self.nutrition = recipe.nutrition
    }

    func asRecipe(id: String? = nil) -> Recipe {
        var recipe = Recipe(
            title: title,
            emoji: emoji,
            description: description,
            ingredients: ingredients,
            steps: steps,
            cookTime: cookTime,
            servings: servings,
            difficulty: difficulty,
            tags: tags,
            calories: calories,
            nutrition: nutrition,
            createdAt: Date()
        )
        recipe.id = id
        return recipe
    }
}

struct MealPlanEntry: Identifiable, Codable, Equatable {
    var id: String
    var recipeId: String?
    var recipeTitle: String?
    var plannedRecipe: PlannedMealRecipe?
    var status: MealPlanSlotStatus? = nil
    var completedAt: Date? = nil
    var consumedNutritionSnapshot: NutritionInfo? = nil
    var sourceType: MealPlanSourceType? = nil

    init(
        id: String = UUID().uuidString,
        recipeId: String?,
        recipeTitle: String?,
        plannedRecipe: PlannedMealRecipe?,
        status: MealPlanSlotStatus? = .planned,
        completedAt: Date? = nil,
        consumedNutritionSnapshot: NutritionInfo? = nil,
        sourceType: MealPlanSourceType? = nil
    ) {
        self.id = id
        self.recipeId = recipeId
        self.recipeTitle = recipeTitle
        self.plannedRecipe = plannedRecipe
        self.status = status
        self.completedAt = completedAt
        self.consumedNutritionSnapshot = consumedNutritionSnapshot
        self.sourceType = sourceType
    }

    init(recipe: Recipe, sourceType: MealPlanSourceType) {
        self.init(
            recipeId: recipe.id,
            recipeTitle: recipe.title,
            plannedRecipe: PlannedMealRecipe(recipe: recipe),
            status: .planned,
            sourceType: sourceType
        )
    }

    var displayTitle: String {
        let snapshotTitle = plannedRecipe?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let topLevelTitle = recipeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !snapshotTitle.isEmpty ? snapshotTitle : topLevelTitle
    }

    var resolvedStatus: MealPlanSlotStatus {
        status ?? .planned
    }

    var isCompleted: Bool {
        resolvedStatus == .cooked || resolvedStatus == .logged
    }
}

struct MealPlanSlot: Identifiable, Codable {
    var id: String?
    var day: String
    var mealType: String
    var recipeId: String?
    var recipeTitle: String?
    var plannedRecipe: PlannedMealRecipe?
    var status: MealPlanSlotStatus? = nil
    var completedAt: Date? = nil
    var consumedNutritionSnapshot: NutritionInfo? = nil
    var sourceType: MealPlanSourceType? = nil
    var entries: [MealPlanEntry]? = nil

    var plannedEntries: [MealPlanEntry] {
        if let entries, entries.isEmpty == false {
            return entries
        }

        let title = recipeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if plannedRecipe == nil && title.isEmpty {
            return []
        }

        return [
            MealPlanEntry(
                id: "legacy-\(day)-\(mealType)",
                recipeId: recipeId,
                recipeTitle: recipeTitle,
                plannedRecipe: plannedRecipe,
                status: status ?? .planned,
                completedAt: completedAt,
                consumedNutritionSnapshot: consumedNutritionSnapshot,
                sourceType: sourceType
            )
        ]
    }

    var displayTitle: String {
        let titles = plannedEntries.map(\.displayTitle).filter { !$0.isEmpty }
        if titles.count > 1 {
            return "\(titles.count) dishes planned"
        }
        return titles.first ?? ""
    }

    var hasRecipeContent: Bool {
        plannedEntries.isEmpty == false
    }

    var resolvedStatus: MealPlanSlotStatus {
        let entries = plannedEntries
        guard entries.isEmpty == false else { return status ?? .planned }
        if entries.allSatisfy(\.isCompleted) {
            return entries.contains(where: { $0.resolvedStatus == .logged }) ? .logged : .cooked
        }
        if entries.contains(where: { $0.resolvedStatus == .skipped }) {
            return .skipped
        }
        return .planned
    }

    var isCompleted: Bool {
        let entries = plannedEntries
        return entries.isEmpty == false && entries.allSatisfy(\.isCompleted)
    }
}

enum MealPlanDetailResolution: Equatable {
    case savedRecipe(String)
    case embeddedRecipe
    case unavailable
}

func mealPlanDetailResolution(
    for slot: MealPlanSlot,
    availableRecipeIDs: Set<String>
) -> MealPlanDetailResolution {
    switch slot.sourceType {
    case .ai, .custom:
        if slot.plannedRecipe != nil { return .embeddedRecipe }
    case .saved:
        if let recipeId = slot.recipeId, availableRecipeIDs.contains(recipeId) {
            return .savedRecipe(recipeId)
        }
    case .manual, .none:
        break
    }

    if let recipeId = slot.recipeId, availableRecipeIDs.contains(recipeId) {
        return .savedRecipe(recipeId)
    }
    if slot.plannedRecipe != nil {
        return .embeddedRecipe
    }
    return .unavailable
}

private struct MealPlanGenerationSlot: Codable {
    let day: String
    let mealType: String
    let recipe: RecipeSuggestion
}

private func nutritionNumericValue(from raw: String) -> Double {
    let pattern = #"[-+]?\d*\.?\d+"#
    guard let range = raw.range(of: pattern, options: .regularExpression) else { return 0 }
    return Double(raw[range]) ?? 0
}

private func formatNutritionValue(_ value: Double, suffix: String) -> String {
    if value == 0 { return "0\(suffix)" }
    if value.rounded() == value {
        return "\(Int(value))\(suffix)"
    }
    return "\(String(format: "%.1f", value))\(suffix)"
}

struct DayNutritionSummary {
    let calories: String
    let carbs: String
    let protein: String
    let fat: String
    let sodium: String
}

struct DayNutritionRealitySummary {
    let planned: DayNutritionSummary
    let consumed: DayNutritionSummary
    let deltaCalories: String
}

struct MealLogDraft {
    var mode: MealLogInputMode = .quick
    var mealType: String = "Dinner"
    var title: String = ""
    var notes: String = ""
    var calories: String = ""
    var carbs: String = ""
    var protein: String = ""
    var fat: String = ""
    var sodium: String = ""
    var isEstimated: Bool = true
    var confidence: String? = nil
    var ingredients: [String] = [""]
    var steps: [String] = [""]
    var autoPolishWithAI: Bool = true
}

struct CustomMealRecipeDraft {
    var mealType: String = "Dinner"
    var title: String = ""
    var emoji: String = "🍽️"
    var description: String = ""
    var prepMinutes: Int = 25
    var servingsCount: Int = 2
    var difficulty: String = "Easy"
    var tagsText: String = "Custom"
    var calories: Int = 400
    var carbs: Int = 40
    var protein: Int = 25
    var fat: Int = 15
    var sodium: Int = 500
    var ingredients: [String] = [""]
    var steps: [String] = [""]
    var autoPolishWithAI: Bool = true
}

struct MealPlanGenerationSession: Equatable {
    enum Kind: Equatable {
        case weekly
        case day(day: String, mealTypes: [String])
    }

    let id = UUID()
    let kind: Kind
}


class MealPlanViewModel: ObservableObject {
    static let shared = MealPlanViewModel()

    @Published var weeklySlots: [MealPlanSlot] = []
    @Published var mealLogEvents: [MealLogEvent] = []
    @Published var isGenerating = false
    @Published var activeGeneration: MealPlanGenerationSession? = nil
    @Published var generationError: String? = nil

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var mealLogListener: ListenerRegistration?
    private var generationTask: Task<Void, Never>? = nil

    private func slotWithEntries(id: String, day: String, mealType: String, entries: [MealPlanEntry]) -> MealPlanSlot {
        let first = entries.first
        return MealPlanSlot(
            id: id,
            day: day,
            mealType: mealType,
            recipeId: first?.recipeId,
            recipeTitle: first?.displayTitle,
            plannedRecipe: first?.plannedRecipe,
            status: first?.status ?? .planned,
            completedAt: first?.completedAt,
            consumedNutritionSnapshot: first?.consumedNutritionSnapshot,
            sourceType: first?.sourceType,
            entries: entries
        )
    }

    private func writeSlot(_ slot: MealPlanSlot, to ref: DocumentReference) {
        do {
            var payload = try Firestore.Encoder().encode(slot)
            payload["updatedAt"] = FieldValue.serverTimestamp()
            ref.setData(payload, merge: true)
        } catch {
            print("Error encoding meal plan slot: \(error.localizedDescription)")
        }
    }

    func startListening(userId: String) {

        guard !userId.isEmpty else { return }
        listener?.remove()

        listener = db.collection("users")
            .document(userId)
            .collection("mealPlan")
            .addSnapshotListener { snapshot, _ in

                guard let documents = snapshot?.documents else { return }

                DispatchQueue.main.async {
                    self.weeklySlots = documents.compactMap {
                        try? $0.data(as: MealPlanSlot.self)
                    }
                }
            }

        mealLogListener?.remove()
        mealLogListener = db.collection("users")
            .document(userId)
            .collection("mealLogEvents")
            .order(by: "consumedAt", descending: true)
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }
                DispatchQueue.main.async {
                    self.mealLogEvents = documents.compactMap { try? $0.data(as: MealLogEvent.self) }
                }
            }

    }

    func addToPlan(recipe: Recipe, day: String, mealType: String, userId: String) {
        let slotId = "\(day)-\(mealType)"
        let ref = db.collection("users").document(userId).collection("mealPlan").document(slotId)
        let source: MealPlanSourceType = recipe.id == nil ? .custom : .saved
        let newEntry = MealPlanEntry(recipe: recipe, sourceType: source)

        ref.getDocument { snapshot, _ in
            var entries: [MealPlanEntry] = []
            if let snapshot, snapshot.exists, let existing = try? snapshot.data(as: MealPlanSlot.self) {
                entries = existing.plannedEntries
            }
            entries.append(newEntry)

            let slot = self.slotWithEntries(id: slotId, day: day, mealType: mealType, entries: entries)
            do {
                var payload = try Firestore.Encoder().encode(slot)
                payload["updatedAt"] = FieldValue.serverTimestamp()
                ref.setData(payload, merge: true) { error in
                    if error == nil {
                        DispatchQueue.main.async {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                        Task {
                            await GrowthEngine.shared.logActivity(
                                userId: userId,
                                type: .planAdd,
                                eventKey: "plan_add_\(slotId)_\(newEntry.id)",
                                metadata: [
                                    "day": day,
                                    "mealType": mealType,
                                    "title": recipe.title
                                ]
                            )
                        }
                    } else {
                        print("Error adding to plan: \(error?.localizedDescription ?? "Unknown error")")
                    }
                }
            } catch {
                print("Error encoding meal plan slot: \(error.localizedDescription)")
            }
        }
    }

    func removeFromPlan(day: String, mealType: String, entryId: String? = nil, userId: String) {
        let slotId = "\(day)-\(mealType)"
        let ref = db.collection("users")
            .document(userId)
            .collection("mealPlan")
            .document(slotId)

        guard let entryId else {
            ref.delete() { error in
                if error == nil {
                    DispatchQueue.main.async {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                } else {
                    print("Error removing from plan: \(error?.localizedDescription ?? "Unknown error")")
                }
            }
            return
        }

        ref.getDocument { snapshot, _ in
            guard let snapshot, snapshot.exists, let existing = try? snapshot.data(as: MealPlanSlot.self) else { return }
            let remaining = existing.plannedEntries.filter { $0.id != entryId }
            guard remaining.isEmpty == false else {
                ref.delete()
                DispatchQueue.main.async {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                return
            }
            let updated = self.slotWithEntries(id: slotId, day: day, mealType: mealType, entries: remaining)
            self.writeSlot(updated, to: ref)
            DispatchQueue.main.async {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    deinit {
        listener?.remove()
        mealLogListener?.remove()
    }

    func startWeeklyPlanGeneration(
        assistant: CookingAssistant,
        userId: String
    ) {
        guard !userId.isEmpty else { return }

        let session = MealPlanGenerationSession(kind: .weekly)
        generationTask?.cancel()

        Task { @MainActor in
            activeGeneration = session
            isGenerating = true
            generationError = nil
        }

        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.generateWeeklyPlan(assistant: assistant, userId: userId)
            await MainActor.run {
                if self.activeGeneration?.id == session.id {
                    self.activeGeneration = nil
                }
                self.generationTask = nil
            }
        }
    }

    func startDayCustomization(
        day: String,
        mealTypes: [String],
        prompt: String,
        assistant: CookingAssistant,
        userId: String
    ) {
        guard !userId.isEmpty, !day.isEmpty, !mealTypes.isEmpty else { return }

        let session = MealPlanGenerationSession(kind: .day(day: day, mealTypes: mealTypes))
        generationTask?.cancel()

        Task { @MainActor in
            activeGeneration = session
            isGenerating = true
            generationError = nil
        }

        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.customizeDayPlan(
                day: day,
                mealTypes: mealTypes,
                prompt: prompt,
                assistant: assistant,
                userId: userId
            )
            await MainActor.run {
                if self.activeGeneration?.id == session.id {
                    self.activeGeneration = nil
                }
                self.generationTask = nil
            }
        }
    }

    func updatePlannedRecipe(_ recipe: Recipe, for slot: MealPlanSlot, userId: String) {
        guard let slotId = slot.id else { return }

        var entries = slot.plannedEntries
        guard entries.isEmpty == false else { return }
        entries[0].recipeTitle = recipe.title
        entries[0].plannedRecipe = PlannedMealRecipe(recipe: recipe)
        entries[0].recipeId = recipe.id ?? entries[0].recipeId

        let updated = slotWithEntries(id: slotId, day: slot.day, mealType: slot.mealType, entries: entries)
        let ref = db.collection("users")
            .document(userId)
            .collection("mealPlan")
            .document(slotId)
        writeSlot(updated, to: ref)
    }

    func updateSlotStatus(
        _ slot: MealPlanSlot,
        status: MealPlanSlotStatus,
        userId: String,
        entryId: String? = nil,
        consumedNutritionSnapshot: NutritionInfo? = nil
    ) {
        guard !userId.isEmpty, let slotId = slot.id else { return }

        var entries = slot.plannedEntries
        let completedAt = (status == .cooked || status == .logged) ? Date() : nil

        if let entryId, let index = entries.firstIndex(where: { $0.id == entryId }) {
            entries[index].status = status
            entries[index].completedAt = completedAt
            if let consumedNutritionSnapshot {
                entries[index].consumedNutritionSnapshot = consumedNutritionSnapshot
            }
        } else {
            entries = entries.map { entry in
                var updatedEntry = entry
                updatedEntry.status = status
                updatedEntry.completedAt = completedAt
                if let consumedNutritionSnapshot {
                    updatedEntry.consumedNutritionSnapshot = consumedNutritionSnapshot
                }
                return updatedEntry
            }
        }

        let updated = slotWithEntries(id: slotId, day: slot.day, mealType: slot.mealType, entries: entries)
        let ref = db.collection("users")
            .document(userId)
            .collection("mealPlan")
            .document(slotId)
        writeSlot(updated, to: ref)

        if status == .cooked || status == .logged {
            let completedTitle = entryId.flatMap { id in
                entries.first(where: { $0.id == id })?.displayTitle
            } ?? slot.displayTitle
            Task {
                await GrowthEngine.shared.logActivity(
                    userId: userId,
                    type: .planComplete,
                    eventKey: "plan_complete_\(slotId)_\(entryId ?? "group")_\(status.rawValue)",
                    metadata: [
                        "day": slot.day,
                        "mealType": slot.mealType,
                        "status": status.rawValue
                    ]
                )

                if status == .cooked {
                    await GrowthEngine.shared.logActivity(
                        userId: userId,
                        type: .recipeCooked,
                        eventKey: "recipe_cooked_plan_\(slotId)",
                        metadata: [
                            "day": slot.day,
                            "mealType": slot.mealType,
                            "title": completedTitle
                        ]
                    )
                }
            }
        }
    }

    func addMealLogEvent(
        day: String,
        mealType: String,
        title: String,
        notes: String,
        mode: MealLogInputMode,
        calories: String,
        nutrition: NutritionInfo,
        isEstimated: Bool,
        confidence: String?,
        ingredients: [String],
        steps: [String],
        userId: String
    ) async {
        guard !userId.isEmpty else { return }

        let logId = UUID().uuidString
        let event = MealLogEvent(
            id: logId,
            day: day,
            mealType: mealType,
            title: title,
            notes: notes,
            inputMode: mode.rawValue,
            calories: calories,
            carbs: nutrition.carbs,
            protein: nutrition.protein,
            fat: nutrition.fat,
            sodium: nutrition.sodium,
            consumedAt: Date(),
            createdAt: Date(),
            isEstimated: isEstimated,
            confidence: confidence,
            ingredients: ingredients.isEmpty ? nil : ingredients,
            steps: steps.isEmpty ? nil : steps
        )

        do {
            let encoded = try Firestore.Encoder().encode(event)
            try await db.collection("users")
                .document(userId)
                .collection("mealLogEvents")
                .document(logId)
                .setData(encoded, merge: false)

            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .mealLogged,
                eventKey: "meal_logged_\(logId)",
                metadata: [
                    "day": day,
                    "mealType": mealType,
                    "mode": mode.rawValue
                ]
            )
        } catch {
            print("Failed to store meal log event: \(error.localizedDescription)")
        }
    }

    private func consumedHistorySummary(userId: String) async -> String {
        guard !userId.isEmpty else { return "" }

        do {
            let snap = try await db.collection("users")
                .document(userId)
                .collection("mealLogEvents")
                .order(by: "consumedAt", descending: true)
                .limit(to: 40)
                .getDocuments()

            let logs = snap.documents.compactMap { try? $0.data(as: MealLogEvent.self) }
            guard !logs.isEmpty else { return "" }

            let titles = logs.map(\.title).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let calorieValues = logs.map { nutritionNumericValue(from: $0.calories) }.filter { $0 > 0 }
            let avgCalories = calorieValues.isEmpty ? nil : Int((calorieValues.reduce(0, +) / Double(calorieValues.count)).rounded())
            let frequentModes = Dictionary(grouping: logs, by: \.inputMode)
                .mapValues(\.count)
                .sorted { $0.value > $1.value }
                .prefix(2)
                .map(\.key)

            var parts: [String] = []
            if !titles.isEmpty {
                parts.append("Recently eaten meals include: \(Array(titles.prefix(5)).joined(separator: ", ")).")
            }
            if let avgCalories {
                parts.append("Logged intake style averages around \(avgCalories) kcal.")
            }
            if !frequentModes.isEmpty {
                parts.append("Most logs are captured through: \(frequentModes.joined(separator: ", ")).")
            }
            parts.append("Use this consumption history to keep suggestions realistic, not just theoretical.")
            return parts.joined(separator: " ")
        } catch {
            print("Failed to load consumed history summary: \(error.localizedDescription)")
            return ""
        }
    }


    func generateWeeklyPlan(
        assistant: CookingAssistant,
        userId: String
    ) async {

        guard !userId.isEmpty else { return }
        await MainActor.run {
            isGenerating = true
        }

        do {


            let userDoc = try await db.collection("users")
                .document(userId)
                .getDocument()

            let data = userDoc.data() ?? [:]

            let diets = (data["dietTags"] as? [String])?.joined(separator: ", ") ?? ""
            let allergies = (data["allergies"] as? [String])?.joined(separator: ", ") ?? ""
            let macros = (data["macroTags"] as? [String])?.joined(separator: ", ") ?? ""
            let cuisines = (data["cuisines"] as? [String])?.joined(separator: ", ") ?? ""
            let spice = data["spiceTolerance"] as? String ?? "Medium"
            let cookTime = data["cookTime"] as? String ?? "30 mins"
            let budget = data["budget"] as? String ?? "Standard"
            let servings = data["servingSize"] as? String ?? "2"
            let dislikes = data["dislikes"] as? String ?? ""
            let dailyCalorieTarget = data["dailyCalorieTarget"] as? Int
            let targetData = data["nutritionTargets"] as? [String: Any] ?? [:]
            let targetCalories = (targetData["calories"] as? NSNumber)?.intValue ?? dailyCalorieTarget
            let targetCarbs = (targetData["carbs"] as? NSNumber)?.intValue
            let targetProtein = (targetData["protein"] as? NSNumber)?.intValue
            let targetFat = (targetData["fat"] as? NSNumber)?.intValue
            let targetSodium = (targetData["sodium"] as? NSNumber)?.intValue

            var context = ""

            if !diets.isEmpty { context += "Diet: \(diets). " }
            if !allergies.isEmpty { context += "Avoid allergies: \(allergies). " }
            if !macros.isEmpty { context += "Macro goal: \(macros). " }
            if !cuisines.isEmpty { context += "Preferred cuisines: \(cuisines). " }
            if !dislikes.isEmpty { context += "Avoid ingredients: \(dislikes). " }

            context += "Spice tolerance: \(spice). "
            context += "Cook time preference: \(cookTime). "
            context += "Budget: \(budget). "
            context += "Serving size: \(servings)."
            if let targetCalories {
                context += " Daily nutrition targets: \(targetCalories) calories"
                if let targetCarbs { context += ", \(targetCarbs)g carbs" }
                if let targetProtein { context += ", \(targetProtein)g protein" }
                if let targetFat { context += ", \(targetFat)g fat" }
                if let targetSodium { context += ", no more than about \(targetSodium)mg sodium" }
                context += ". Balance these totals realistically across breakfast, lunch, and dinner."
            }
            let consumedHistory = await consumedHistorySummary(userId: userId)
            if !consumedHistory.isEmpty {
                context += " \(consumedHistory)"
            }


            let existingSnap = try await db.collection("users")
                .document(userId)
                .collection("mealPlan")
                .getDocuments()

            let currentPlan = existingSnap.documents.compactMap { try? $0.data(as: MealPlanSlot.self) }

            var emptySlotsDescription = ""
            for day in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"] {
                for meal in ["Breakfast", "Lunch", "Dinner"] {
                    if !currentPlan.contains(where: { $0.day == day && $0.mealType == meal && !$0.displayTitle.isEmpty }) {
                        emptySlotsDescription += "- \(day): \(meal)\n"
                    }
                }
            }

            let prompt = """
            Generate meals ONLY for the following empty slots:
            \(emptySlotsDescription)

            Do not provide suggestions for slots already filled.
            User preferences: \(context)

            Return ONLY valid JSON in this exact format:
            [
              {
                "day": "Monday",
                "mealType": "Breakfast",
                "recipe": {
                  "title": "Spinach Egg Tacos",
                  "emoji": "🌮",
                  "description": "A fast, savory breakfast taco with fluffy eggs and sauteed spinach.",
                  "prepTime": "15 mins",
                  "servings": "2 people",
                  "difficulty": "Easy",
                  "calories": "410 kcal",
                  "carbs": "26g",
                  "protein": "24g",
                  "fat": "21g",
                  "saturatedFat": "6g",
                  "sugar": "3g",
                  "fiber": "4g",
                  "sodium": "540mg",
                  "tags": ["Mexican", "High Protein", "Quick"],
                  "ingredients": ["4 eggs", "1 cup spinach"],
                  "steps": ["Crack the eggs into a bowl and whisk until smooth before heating the pan.", "Cook until the eggs are softly set, 2 to 3 minutes, then remove from the heat immediately."],
                  "matchReason": "Why it fits the user."
                }
              }
            ]

            Rules:
            - Output JSON only. No markdown, no commentary, and no code fences.
            - Generate entries for every empty slot only.
            - Every recipe must be fully cookable with 4 to 7 detailed steps.
            - ingredients must include exact quantities and units.
            - steps must include prep work, timing ranges, heat guidance, and doneness or texture cues.
            - Include nutrition strings for calories, carbs, protein, fat, saturatedFat, sugar, fiber, and sodium.
            - Keep recipes realistic for the stated cook time, budget, preferences, and skill level.
            - Include at least one cuisine tag in each recipe tags array.
            - Balance each full day toward the saved calorie, carbohydrate, protein, fat, and sodium targets in the user preferences.
            """


            let response = try await retryingTransientChefBuddyAI {
                try await assistant.waitUntilReady()
                return try await assistant.getHelp(question: prompt)
            }

            guard let json = CookingAssistant.extractJSONArray(from: response),
                  let data = json.data(using: .utf8) else {
                throw CookingAssistantError.invalidRecipeResponse
            }

            let generated = try JSONDecoder().decode([MealPlanGenerationSlot].self, from: data)

            let batch = db.batch()

            let collection = db.collection("users")
                .document(userId)
                .collection("mealPlan")

            for generatedSlot in generated {
                let slotId = "\(generatedSlot.day)-\(generatedSlot.mealType)"
                let doc = collection.document(slotId)
                let recipe = generatedSlot.recipe.asRecipe()
                let entry = MealPlanEntry(recipe: recipe, sourceType: .ai)
                let slot = MealPlanSlot(
                    id: slotId,
                    day: generatedSlot.day,
                    mealType: generatedSlot.mealType,
                    recipeId: entry.recipeId,
                    recipeTitle: recipe.title,
                    plannedRecipe: PlannedMealRecipe(recipe: recipe),
                    status: .planned,
                    completedAt: nil,
                    consumedNutritionSnapshot: nil,
                    sourceType: .ai,
                    entries: [entry]
                )
                var payload = try Firestore.Encoder().encode(slot)
                payload["updatedAt"] = FieldValue.serverTimestamp()
                batch.setData(payload, forDocument: doc, merge: false)
            }

            try await batch.commit()

            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isGenerating = false
            }

        } catch {
            let presentation = chefBuddyAIErrorPresentation(for: error)

            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                isGenerating = false
                generationError = "\(presentation.message) \(presentation.retryGuidance)"
            }
        }
    }

    func customizeDayPlan(
        day: String,
        mealTypes: [String],
        prompt: String,
        assistant: CookingAssistant,
        userId: String
    ) async {
        guard !userId.isEmpty, !day.isEmpty, !mealTypes.isEmpty else { return }

        await MainActor.run {
            isGenerating = true
        }

        do {
            let userDoc = try await db.collection("users").document(userId).getDocument()
            let data = userDoc.data() ?? [:]

            let diets = (data["dietTags"] as? [String])?.joined(separator: ", ") ?? ""
            let allergies = (data["allergies"] as? [String])?.joined(separator: ", ") ?? ""
            let macros = (data["macroTags"] as? [String])?.joined(separator: ", ") ?? ""
            let cuisines = (data["cuisines"] as? [String])?.joined(separator: ", ") ?? ""
            let spice = data["spiceTolerance"] as? String ?? "Medium"
            let cookTime = data["cookTime"] as? String ?? "30 mins"
            let budget = data["budget"] as? String ?? "Standard"
            let servings = data["servingSize"] as? String ?? "2"
            let dislikes = data["dislikes"] as? String ?? ""
            let dailyCalorieTarget = data["dailyCalorieTarget"] as? Int
            let targetData = data["nutritionTargets"] as? [String: Any] ?? [:]
            let targetCalories = (targetData["calories"] as? NSNumber)?.intValue ?? dailyCalorieTarget
            let targetCarbs = (targetData["carbs"] as? NSNumber)?.intValue
            let targetProtein = (targetData["protein"] as? NSNumber)?.intValue
            let targetFat = (targetData["fat"] as? NSNumber)?.intValue
            let targetSodium = (targetData["sodium"] as? NSNumber)?.intValue

            var context = ""
            if !diets.isEmpty { context += "Diet: \(diets). " }
            if !allergies.isEmpty { context += "Avoid allergies: \(allergies). " }
            if !macros.isEmpty { context += "Macro goal: \(macros). " }
            if !cuisines.isEmpty { context += "Preferred cuisines: \(cuisines). " }
            if !dislikes.isEmpty { context += "Avoid ingredients: \(dislikes). " }
            context += "Spice tolerance: \(spice). "
            context += "Cook time preference: \(cookTime). "
            context += "Budget: \(budget). "
            context += "Serving size: \(servings). "
            if let targetCalories {
                context += "Daily targets: \(targetCalories) calories"
                if let targetCarbs { context += ", \(targetCarbs)g carbs" }
                if let targetProtein { context += ", \(targetProtein)g protein" }
                if let targetFat { context += ", \(targetFat)g fat" }
                if let targetSodium { context += ", about \(targetSodium)mg sodium maximum" }
                context += ". Balance the selected meals against the rest of the day. "
            }
            let consumedHistory = await consumedHistorySummary(userId: userId)
            if !consumedHistory.isEmpty {
                context += consumedHistory + " "
            }

            let targetedMeals = mealTypes.joined(separator: ", ")
            let customizationPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No extra theme request. Make the day balanced and appealing."
                : prompt.trimmingCharacters(in: .whitespacesAndNewlines)

            let request = """
            Regenerate only these meals for \(day): \(targetedMeals).

            User preferences: \(context)
            Extra customization request: \(customizationPrompt)

            Return ONLY valid JSON in this exact format:
            [
              {
                "day": "\(day)",
                "mealType": "Lunch",
                "recipe": {
                  "title": "Recipe name",
                  "emoji": "🍝",
                  "description": "Short enticing description",
                  "prepTime": "25 mins",
                  "servings": "2 people",
                  "difficulty": "Easy",
                  "calories": "420 kcal",
                  "carbs": "42g",
                  "protein": "35g",
                  "fat": "12g",
                  "saturatedFat": "4g",
                  "sugar": "8g",
                  "fiber": "5g",
                  "sodium": "620mg",
                  "tags": ["Italian", "Balanced"],
                  "ingredients": ["1 tbsp olive oil", "200g chicken breast"],
                  "steps": ["Prep...", "Cook..."],
                  "matchReason": "Why it fits the day."
                }
              }
            ]

            Rules:
            - Output JSON only with no markdown or code fences.
            - Generate entries for exactly these meal types and no others: \(targetedMeals).
            - Keep the selected day coherent with the customization request.
            - Balance the selected meals so the full day tracks close to all saved nutrition targets when provided.
            - Each recipe must be fully cookable with 4 to 7 detailed steps.
            - ingredients must include exact quantities and units.
            - steps must include prep work, timing ranges, heat guidance, and doneness or texture cues.
            - Include nutrition strings for calories, carbs, protein, fat, saturatedFat, sugar, fiber, and sodium.
            - Include at least one cuisine tag in each recipe tags array.
            """

            let response = try await retryingTransientChefBuddyAI {
                try await assistant.waitUntilReady()
                return try await assistant.getHelp(question: request)
            }

            guard let json = CookingAssistant.extractJSONArray(from: response),
                  let responseData = json.data(using: .utf8) else {
                throw NSError(domain: "MealPlan", code: 1)
            }

            let generated = try JSONDecoder().decode([MealPlanGenerationSlot].self, from: responseData)
            let batch = db.batch()
            let collection = db.collection("users").document(userId).collection("mealPlan")

            for generatedSlot in generated where mealTypes.contains(generatedSlot.mealType) {
                let slotId = "\(generatedSlot.day)-\(generatedSlot.mealType)"
                let recipe = generatedSlot.recipe.asRecipe()
                let entry = MealPlanEntry(recipe: recipe, sourceType: .ai)
                let slot = MealPlanSlot(
                    id: slotId,
                    day: generatedSlot.day,
                    mealType: generatedSlot.mealType,
                    recipeId: entry.recipeId,
                    recipeTitle: recipe.title,
                    plannedRecipe: PlannedMealRecipe(recipe: recipe),
                    status: .planned,
                    completedAt: nil,
                    consumedNutritionSnapshot: nil,
                    sourceType: .ai,
                    entries: [entry]
                )
                var payload = try Firestore.Encoder().encode(slot)
                payload["updatedAt"] = FieldValue.serverTimestamp()
                batch.setData(payload, forDocument: collection.document(slotId), merge: false)
            }

            try await batch.commit()

            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isGenerating = false
                generationError = nil
            }
        } catch {
            let presentation = chefBuddyAIErrorPresentation(for: error)
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                isGenerating = false
                generationError = "\(presentation.message) Your meal selections are still here. \(presentation.retryGuidance)"
            }
        }
    }
}


struct WeeklyMealPlanView: View {

    @EnvironmentObject var authVM: AuthViewModel
    @ObservedObject var assistant: CookingAssistant

    @ObservedObject private var vm = MealPlanViewModel.shared
    @StateObject private var recipesVM = RecipesViewModel()

    @State private var selectedDay = Calendar.current.weekdayName(for: Date())
    @State private var showRecipePicker = false
    @State private var selectedMealType: String?
    @State private var selectedRecipeForDetail: Recipe? = nil
    @State private var selectedPlannedRecipeForDetail: Recipe? = nil
    @State private var selectedPlanSlotForDetail: MealPlanSlot? = nil
    @State private var hasAppeared = false
    @State private var pulseHero = false
    @State private var showDayAssistant = false
    @State private var dayAssistantPrompt = ""
    @State private var dayAssistantMealTypes: Set<String> = ["Breakfast", "Lunch", "Dinner"]
    @State private var showMealLogSheet = false
    @State private var pantrySpaces: [SimplePantrySpace] = []
    @State private var selectedPantryId: String? = nil
    @State private var pantryListener: ListenerRegistration? = nil
    @State private var aiCoachInsight: DailyCoachInsight? = nil
    @State private var aiCoachLoading = false
    @State private var aiCoachCache: [String: DailyCoachInsight] = [:]
    @State private var aiCoachTask: Task<Void, Never>? = nil
    @State private var showNutritionTargetSetup = false
    @State private var showDayOverwriteConfirmation = false
    @State private var displayMode: MealPlanDisplayMode = .day
    @State private var showDayInsights = false
    @State private var heroVariant = Int.random(in: 0..<3)
    @State private var heroMetricIndex = 0
    @State private var showMealPlanHelp = false
    private let mealPlanHeroTimer = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    private let days = [
        "Monday", "Tuesday", "Wednesday",
        "Thursday", "Friday", "Saturday", "Sunday"
    ]

    private let mealTypes = ["Breakfast", "Lunch", "Dinner"]

    private var currentWeekday: String {
        Calendar.current.weekdayName(for: Date())
    }

    private var currentWeekDates: [(day: String, date: Date)] {
        mealPlanWeekDates(containing: Date())
    }

    private func date(for day: String) -> Date? {
        currentWeekDates.first(where: { $0.day == day })?.date
    }

    private func isPastDay(_ day: String) -> Bool {
        guard let date = date(for: day) else { return false }
        return date < Calendar.current.startOfDay(for: Date())
    }

    private func isCompletedDay(_ day: String) -> Bool {
        let entries = mealTypes
            .compactMap { slotFor(day: day, type: $0) }
            .flatMap(\.plannedEntries)
        return entries.isEmpty == false && entries.allSatisfy(\.isCompleted)
    }

    private func compactDateLabel(for day: String) -> String {
        guard let date = date(for: day) else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func fullDateLabel(for day: String) -> String {
        guard let date = date(for: day) else { return day }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private var filledSlotsCount: Int {
        vm.weeklySlots.flatMap(\.plannedEntries).filter { !$0.displayTitle.isEmpty }.count
    }

    private var emptyMealSlotCount: Int {
        days.reduce(0) { total, day in
            total + mealTypes.filter { type in
                slotFor(day: day, type: type)?.plannedEntries.isEmpty ?? true
            }.count
        }
    }

    private var selectedDayFilledCount: Int {
        mealTypes
            .compactMap { slotFor(type: $0) }
            .flatMap(\.plannedEntries)
            .filter { !$0.displayTitle.isEmpty }
            .count
    }

    private var pantryIngredients: [String] {
        pantrySpaces.first(where: { $0.id == selectedPantryId })?.ingredients ?? []
    }

    private func shortDay(_ day: String) -> String {
        String(day.prefix(3))
    }

    private func slotFor(type: String) -> MealPlanSlot? {
        slotFor(day: selectedDay, type: type)
    }

    private func slotFor(day: String, type: String) -> MealPlanSlot? {
        vm.weeklySlots.first {
            $0.day == day && $0.mealType == type
        }
    }

    private func nutritionSummary(for day: String) -> DayNutritionSummary {
        let plannedRecipes = mealTypes
            .compactMap { slotFor(day: day, type: $0) }
            .flatMap(\.plannedEntries)
            .compactMap(\.plannedRecipe)
        return DayNutritionSummary(
            calories: formatNutritionValue(plannedRecipes.reduce(0) { $0 + nutritionNumericValue(from: $1.calories) }, suffix: " kcal"),
            carbs: formatNutritionValue(plannedRecipes.reduce(0) { $0 + nutritionNumericValue(from: $1.nutrition.carbs) }, suffix: "g carbs"),
            protein: formatNutritionValue(plannedRecipes.reduce(0) { $0 + nutritionNumericValue(from: $1.nutrition.protein) }, suffix: "g protein"),
            fat: formatNutritionValue(plannedRecipes.reduce(0) { $0 + nutritionNumericValue(from: $1.nutrition.fat) }, suffix: "g fat"),
            sodium: formatNutritionValue(plannedRecipes.reduce(0) { $0 + nutritionNumericValue(from: $1.nutrition.sodium) }, suffix: "mg sodium")
        )
    }

    private var selectedDayNutritionSummary: DayNutritionSummary {
        nutritionSummary(for: selectedDay)
    }

    private var selectedDayMealLogs: [MealLogEvent] {
        vm.mealLogEvents.filter { $0.day == selectedDay }
    }

    private var selectedDayCompletionCount: Int {
        mealTypes
            .compactMap { slotFor(type: $0) }
            .flatMap(\.plannedEntries)
            .filter(\.isCompleted)
            .count
    }

    private var selectedDayConsumedSummary: DayNutritionSummary {
        var calories = 0.0
        var carbs = 0.0
        var protein = 0.0
        var fat = 0.0
        var sodium = 0.0

        for entry in mealTypes.compactMap({ slotFor(type: $0) }).flatMap(\.plannedEntries) where entry.isCompleted {
            if let consumed = entry.consumedNutritionSnapshot {
                calories += nutritionNumericValue(from: consumed.calories)
                carbs += nutritionNumericValue(from: consumed.carbs)
                protein += nutritionNumericValue(from: consumed.protein)
                fat += nutritionNumericValue(from: consumed.fat)
                sodium += nutritionNumericValue(from: consumed.sodium)
            } else if let planned = entry.plannedRecipe {
                calories += nutritionNumericValue(from: planned.calories)
                carbs += nutritionNumericValue(from: planned.nutrition.carbs)
                protein += nutritionNumericValue(from: planned.nutrition.protein)
                fat += nutritionNumericValue(from: planned.nutrition.fat)
                sodium += nutritionNumericValue(from: planned.nutrition.sodium)
            }
        }

        for log in selectedDayMealLogs {
            calories += nutritionNumericValue(from: log.calories)
            carbs += nutritionNumericValue(from: log.carbs)
            protein += nutritionNumericValue(from: log.protein)
            fat += nutritionNumericValue(from: log.fat)
            sodium += nutritionNumericValue(from: log.sodium)
        }

        return DayNutritionSummary(
            calories: formatNutritionValue(calories, suffix: " kcal"),
            carbs: formatNutritionValue(carbs, suffix: "g carbs"),
            protein: formatNutritionValue(protein, suffix: "g protein"),
            fat: formatNutritionValue(fat, suffix: "g fat"),
            sodium: formatNutritionValue(sodium, suffix: "mg sodium")
        )
    }

    private var selectedDayRealitySummary: DayNutritionRealitySummary {
        let planned = selectedDayNutritionSummary
        let consumed = selectedDayConsumedSummary
        let delta = nutritionNumericValue(from: consumed.calories) - nutritionNumericValue(from: planned.calories)
        let deltaPrefix = delta > 0 ? "+" : ""
        return DayNutritionRealitySummary(
            planned: planned,
            consumed: consumed,
            deltaCalories: "\(deltaPrefix)\(Int(delta.rounded())) kcal"
        )
    }

    private var fallbackDailyCoachInsight: DailyCoachInsight {
        let target = Double(authVM.currentUserProfile?.dailyCalorieTarget ?? 0)
        let consumedCalories = nutritionNumericValue(from: selectedDayConsumedSummary.calories)

        if selectedDayCompletionCount == 0 && selectedDayMealLogs.isEmpty {
            return DailyCoachInsight(
                focus: "Momentum",
                headline: "Get one meal on the board",
                nextAction: "Mark one planned meal cooked or log what you actually ate next.",
                benefit: "That gives ChefBuddy real data to tune tomorrow."
            )
        }

        if target > 0 {
            let difference = consumedCalories - target
            if difference > 180 {
                return DailyCoachInsight(
                    focus: "Balance",
                    headline: "Dinner can rebalance the day",
                    nextAction: "Aim for a lighter, higher-protein next meal to close the calorie gap.",
                    benefit: "A softer landing keeps the week easier to sustain."
                )
            }
            if difference < -180 {
                return DailyCoachInsight(
                    focus: "Recovery",
                    headline: "You may need a little more fuel",
                    nextAction: "Add a balanced snack so energy stays steadier tonight.",
                    benefit: "Closing the gap helps recovery and appetite control."
                )
            }
        }

        if selectedDayCompletionCount >= 3 {
            return DailyCoachInsight(
                focus: "Consistency",
                headline: "You landed the whole day",
                nextAction: "Keep tomorrow simple so this streak stays low-friction.",
                benefit: "Consistency is turning into a real habit loop."
            )
        }

        if selectedDayMealLogs.count >= 2 {
            return DailyCoachInsight(
                focus: "Feedback",
                headline: "Your logging signal is getting useful",
                nextAction: "Keep portions honest so tomorrow's plan can tune faster.",
                benefit: "Better feedback makes personalization smarter."
            )
        }

        return DailyCoachInsight(
            focus: "Consistency",
            headline: "One more meal strengthens the day",
            nextAction: "Finish one more planned slot to lock in stronger momentum.",
            benefit: "Small completions are what build the streak."
        )
    }

    private var coachContextSignature: String {
        let slotTitles = mealTypes.compactMap { slotFor(type: $0)?.displayTitle }.joined(separator: "|")
        let logTitles = selectedDayMealLogs.map(\.title).joined(separator: "|")
        let target = authVM.currentUserProfile?.dailyCalorieTarget ?? 0
        return [
            selectedDay,
            slotTitles,
            logTitles,
            selectedDayNutritionSummary.calories,
            selectedDayConsumedSummary.calories,
            selectedDayCompletionCount.description,
            selectedDayMealLogs.count.description,
            target.description
        ].joined(separator: "•")
    }

    private var displayedDailyCoachInsight: DailyCoachInsight {
        aiCoachInsight ?? fallbackDailyCoachInsight
    }

    private var nutritionTargets: NutritionTargets? {
        authVM.currentUserProfile?.nutritionTargets
    }

    private func handleSlotTap(type: String) {
        if let slot = slotFor(type: type), let entry = slot.plannedEntries.first {
            openMealEntry(entry, in: slot)
            return
        }
        addMeal(to: type)
    }

    private func addMeal(to type: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        selectedMealType = type
        showRecipePicker = true
    }

    private func openMealEntry(_ entry: MealPlanEntry, in slot: MealPlanSlot) {
        let recipeIDs = Set(recipesVM.recipes.compactMap(\.id))
        if let recipeId = entry.recipeId,
           recipeIDs.contains(recipeId),
           let savedRecipe = recipesVM.recipes.first(where: { $0.id == recipeId }) {
            selectedRecipeForDetail = savedRecipe
            return
        }

        if let plannedRecipe = entry.plannedRecipe {
            selectedPlanSlotForDetail = slot
            selectedPlannedRecipeForDetail = plannedRecipe.asRecipe(id: entry.recipeId ?? entry.id)
            return
        }

        addMeal(to: slot.mealType)
    }

    private func removeSlot(type: String) {
        guard let uid = authVM.userSession?.uid else { return }
        vm.removeFromPlan(day: selectedDay, mealType: type, userId: uid)
    }

    private func removeEntry(type: String, entry: MealPlanEntry) {
        guard let uid = authVM.userSession?.uid else { return }
        vm.removeFromPlan(day: selectedDay, mealType: type, entryId: entry.id, userId: uid)
    }

    private func updateSlotStatus(type: String, status: MealPlanSlotStatus) {
        guard let uid = authVM.userSession?.uid,
              let slot = slotFor(type: type) else { return }
        vm.updateSlotStatus(slot, status: status, userId: uid)
    }

    private func updateEntryStatus(type: String, entry: MealPlanEntry, status: MealPlanSlotStatus) {
        guard let uid = authVM.userSession?.uid,
              let slot = slotFor(type: type) else { return }
        vm.updateSlotStatus(slot, status: status, userId: uid, entryId: entry.id)
    }

    private func generateWeeklyPlan() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if let uid = authVM.userSession?.uid {
            vm.startWeeklyPlanGeneration(assistant: assistant, userId: uid)
        }
    }

    private func customizeSelectedDay() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        performDayCustomization()
    }

    private func performDayCustomization() {
        if let uid = authVM.userSession?.uid {
            vm.startDayCustomization(
                day: selectedDay,
                mealTypes: Array(dayAssistantMealTypes),
                prompt: dayAssistantPrompt,
                assistant: assistant,
                userId: uid
            )
        }
    }

    private func saveMealLog(_ draft: MealLogDraft) {
        guard let uid = authVM.userSession?.uid else { return }

        let cleanIngredients = draft.ingredients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanSteps = draft.steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let nutrition = NutritionInfo(
            calories: draft.calories,
            carbs: draft.carbs,
            protein: draft.protein,
            fat: draft.fat,
            saturatedFat: "",
            sugar: "",
            fiber: "",
            sodium: draft.sodium
        )

        Task {
            await vm.addMealLogEvent(
                day: selectedDay,
                mealType: draft.mealType,
                title: draft.title,
                notes: draft.notes,
                mode: draft.mode,
                calories: draft.calories,
                nutrition: nutrition,
                isEstimated: draft.isEstimated,
                confidence: draft.confidence,
                ingredients: cleanIngredients,
                steps: cleanSteps,
                userId: uid
            )

            if let slot = slotFor(type: draft.mealType) {
                vm.updateSlotStatus(slot, status: .logged, userId: uid, consumedNutritionSnapshot: nutrition)
            }
        }
    }

    var body: some View {
        simplifiedBody
    }

    private var simplifiedBody: some View {
        ZStack {
            ChefBuddyBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    mealPlanHero
                    mealPlanHelpLink
                    displayModeSwitcher

                    if displayMode == .day {
                        dayPlannerContent
                    } else {
                        weekPlannerContent
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        if emptyMealSlotCount == 0 {
                            selectedDay = currentWeekday
                            displayMode = .day
                            dayAssistantMealTypes = Set(mealTypes)
                            dayAssistantPrompt = ""
                            showDayAssistant = true
                        } else if nutritionTargets == nil {
                            showNutritionTargetSetup = true
                        } else {
                            generateWeeklyPlan()
                        }
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: vm.isGenerating ? "hourglass" : emptyMealSlotCount == 0 ? "slider.horizontal.3" : "sparkles")
                                .font(.system(size: 17, weight: .bold))
                                .frame(width: 42, height: 42)
                                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    vm.isGenerating
                                    ? "Completing your week…"
                                    : emptyMealSlotCount == 0 ? "Tune This Week" : "Complete \(emptyMealSlotCount) Open Slot\(emptyMealSlotCount == 1 ? "" : "s")"
                                )
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                Text(
                                    emptyMealSlotCount == 0
                                    ? "Everything is planned—adjust today around your goals instead."
                                    : "ChefBuddy will preserve every meal already on your calendar."
                                )
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.76))
                                .multilineTextAlignment(.leading)
                            }

                            Spacer(minLength: 4)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(
                                colors: emptyMealSlotCount == 0
                                ? [.blue, .purple.opacity(0.84)]
                                : [.orange, .green.opacity(0.84)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isGenerating)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 140)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            selectedDay = currentWeekday
            if let uid = authVM.userSession?.uid {
                vm.startListening(userId: uid)
                recipesVM.startListening(userId: uid)
                startPantryListener(userId: uid)
            }
        }
        .onDisappear {
            pantryListener?.remove()
            pantryListener = nil
        }
        .sheet(isPresented: $showNutritionTargetSetup) {
            if let profile = authVM.currentUserProfile {
                NutritionTargetSetupSheet(
                    profile: profile,
                    assistant: assistant,
                    currentTargets: nutritionTargets,
                    onSave: { targets in
                        authVM.updateNutritionTargets(targets)
                        showNutritionTargetSetup = false
                    }
                )
            }
        }
        .sheet(isPresented: $showRecipePicker) {
            NavigationStack {
                List(recipesVM.recipes) { recipe in
                    Button {
                        guard let selectedMealType, let uid = authVM.userSession?.uid else { return }
                        vm.addToPlan(recipe: recipe, day: selectedDay, mealType: selectedMealType, userId: uid)
                        showRecipePicker = false
                    } label: {
                        HStack(spacing: 12) {
                            Text(recipe.emoji).font(.title2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recipe.title)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                Text("\(recipe.cookTime) • \(recipe.calories)")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .overlay {
                    if recipesVM.recipes.isEmpty {
                        ContentUnavailableView(
                            "No Saved Recipes",
                            systemImage: "book.closed",
                            description: Text("Save a recipe first, then add it to your plan.")
                        )
                    }
                }
                .navigationTitle("Choose \(selectedMealType ?? "Meal")")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { showRecipePicker = false }
                    }
                }
            }
        }
        .sheet(item: $selectedRecipeForDetail) { recipe in
            RecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                pantryIngredients: pantryIngredients,
                onFavorite: {
                    if let uid = authVM.userSession?.uid {
                        recipesVM.toggleFavorite(recipe, userId: uid)
                    }
                },
                onDelete: {},
                userId: authVM.userSession?.uid ?? ""
            )
        }
        .sheet(item: $selectedPlannedRecipeForDetail) { recipe in
            SuggestedRecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                onSave: {
                    guard let uid = authVM.userSession?.uid else { return }
                    recipesVM.saveSuggestedRecipe(recipe, userId: uid)
                },
                onDislike: nil,
                onRecipeUpdated: { updated in
                    guard let uid = authVM.userSession?.uid, let slot = selectedPlanSlotForDetail else { return }
                    vm.updatePlannedRecipe(updated, for: slot, userId: uid)
                    selectedPlannedRecipeForDetail = updated
                },
                onLiveHelp: nil
            )
        }
        .sheet(isPresented: $showDayAssistant) {
            DayCustomizationSheet(
                day: selectedDay,
                mealTypes: mealTypes,
                selectedMealTypes: $dayAssistantMealTypes,
                prompt: $dayAssistantPrompt,
                occupiedMealTypes: Set(mealTypes.filter { slotFor(type: $0)?.displayTitle.isEmpty == false }),
                nutritionTargets: nutritionTargets,
                isGenerating: vm.isGenerating,
                errorMessage: vm.generationError,
                onGenerate: customizeSelectedDay
            )
        }
        .confirmationDialog(
            "Replace selected meals?",
            isPresented: $showDayOverwriteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace Meals", role: .destructive) {
                performDayCustomization()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some selected meal slots already contain recipes. ChefBuddy will replace only those selected slots.")
        }
        .sheet(isPresented: $showMealPlanHelp) {
            InfoMessageSheet(
                title: "How Meal Plan works",
                message: "Day view keeps today focused. Week view shows the full rhythm. ChefBuddy can fill only open slots, adjust selected meals, and align the plan with your calorie, protein, sodium, pantry, schedule, and body-goal preferences."
            )
        }
        .onReceive(mealPlanHeroTimer) { _ in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                heroMetricIndex = (heroMetricIndex + 1) % 4
            }
        }
    }

    private var mealPlanHero: some View {
        let titles = [
            "A plan you’ll\nactually use.",
            "Make the week\nfeel lighter.",
            "Goals and dinner,\nin one rhythm."
        ]
        let eyebrows = ["THIS WEEK", "YOUR WEEK AHEAD", "PERSONAL MEAL RHYTHM"]
        let icons = ["calendar.badge.clock", "wand.and.stars", "chart.bar.fill"]
        let gradients: [[Color]] = [
            [Color(red: 0.22, green: 0.18, blue: 0.66), Color(red: 0.20, green: 0.48, blue: 0.84)],
            [Color(red: 0.34, green: 0.16, blue: 0.67), Color(red: 0.18, green: 0.42, blue: 0.80)],
            [Color(red: 0.19, green: 0.28, blue: 0.66), Color(red: 0.20, green: 0.59, blue: 0.76)]
        ]
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(eyebrows[heroVariant])
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(titles[heroVariant])
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineSpacing(-3)
                }
                Spacer()
                Image(systemName: icons[heroVariant])
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            }

            Text("\(currentWeekDates.first?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "") – \(currentWeekDates.last?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "")  •  \(filledSlotsCount) meals planned")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))

            let metrics = [
                ("\(selectedDayFilledCount)/3", "Meals planned today", "sun.max.fill"),
                ("\(filledSlotsCount)", "Meals scheduled this week", "calendar.badge.checkmark"),
                ("\(max(0, 21 - filledSlotsCount))", "Open opportunities", "square.dashed"),
                (nutritionTargets.map { "\($0.protein)g" } ?? "Set goals", "Daily protein target", "bolt.heart.fill")
            ]
            let metric = metrics[heroMetricIndex % metrics.count]
            HStack(spacing: 13) {
                Image(systemName: metric.2)
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.0).font(.system(size: 23, weight: .heavy, design: .rounded))
                    Text(metric.1.uppercased())
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.70))
                }
                Spacer()
            }
            .id(heroMetricIndex)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .padding(13)
            .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .padding(21)
        .background(
            LinearGradient(
                colors: gradients[heroVariant],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .shadow(color: .indigo.opacity(0.24), radius: 18, y: 9)
    }

    private var mealPlanHelpLink: some View {
        Button {
            showMealPlanHelp = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.indigo)
                Text("How planning and nutrition targets work")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func mealPlanHeroMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
            Text(label.uppercased())
                .font(.system(size: 9, weight: .black, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var displayModeSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(MealPlanDisplayMode.allCases) { mode in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        displayMode = mode
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: mode == .day ? "sun.max.fill" : "square.grid.2x2.fill")
                        Text(mode.rawValue)
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(displayMode == mode ? .white : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(displayMode == mode ? Color.indigo : Color.clear, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    private var dayPlannerContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(days, id: \.self) { day in
                        let plannedCount = mealTypes
                            .compactMap { slotFor(day: day, type: $0) }
                            .flatMap(\.plannedEntries)
                            .filter { !$0.displayTitle.isEmpty }
                            .count

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                                selectedDay = day
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Text(shortDay(day).uppercased())
                                    .font(.system(size: 10, weight: .black, design: .rounded))
                                    .opacity(0.78)
                                Text(date(for: day)?.formatted(.dateTime.day()) ?? "—")
                                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(plannedCount >= 3 ? Color.green : Color.orange)
                                        .frame(width: 5, height: 5)
                                    Text("\(plannedCount) dish\(plannedCount == 1 ? "" : "es")")
                                        .font(.system(size: 8, weight: .bold, design: .rounded))
                                }
                            }
                            .foregroundStyle(selectedDay == day ? .white : .primary)
                            .frame(width: 66, height: 70)
                            .background(
                                selectedDay == day ? Color.indigo : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let nutritionTargets {
                Button {
                    showNutritionTargetSetup = true
                } label: {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack(spacing: 12) {
                            Image(systemName: "scope")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(
                                    LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Daily nutrition guide")
                                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                                Text("Planned so far compared with your full-day targets")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.indigo)
                        }

                        HStack(spacing: 9) {
                            nutritionGuideMetric(
                                current: nutritionNumericValue(from: selectedDayNutritionSummary.calories),
                                target: Double(nutritionTargets.calories),
                                label: "Calories",
                                unit: "kcal",
                                color: .indigo
                            )
                            nutritionGuideMetric(
                                current: nutritionNumericValue(from: selectedDayNutritionSummary.protein),
                                target: Double(nutritionTargets.protein),
                                label: "Protein",
                                unit: "g",
                                color: .green
                            )
                            nutritionGuideMetric(
                                current: nutritionNumericValue(from: selectedDayNutritionSummary.sodium),
                                target: Double(nutritionTargets.sodium),
                                label: "Sodium",
                                unit: "mg",
                                color: .purple
                            )
                        }
                    }
                    .padding(15)
                    .background(
                        LinearGradient(
                            colors: [Color.indigo.opacity(0.11), Color.blue.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.indigo.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                nutritionTargetSetupButton
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedDay)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                        Text("\(compactDateLabel(for: selectedDay))  ·  \(selectedDayFilledCount) of 3 planned")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        dayAssistantMealTypes = Set(mealTypes)
                        dayAssistantPrompt = ""
                        showDayAssistant = true
                    } label: {
                        Label("Adjust Day", systemImage: "wand.and.stars")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                        .background(Color.indigo, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                ForEach(mealTypes, id: \.self) { type in
                    SimplifiedMealPlanRow(
                        mealType: type,
                        slot: slotFor(type: type),
                        onAdd: { addMeal(to: type) },
                        onOpenEntry: { entry in
                            if let slot = slotFor(type: type) {
                                openMealEntry(entry, in: slot)
                            }
                        },
                        onRemoveEntry: { entry in removeEntry(type: type, entry: entry) },
                        onStatusChange: { entry, status in updateEntryStatus(type: type, entry: entry, status: status) }
                    )
                }
            }
            .padding(17)
            .background(
                LinearGradient(
                    colors: [Color.indigo.opacity(0.12), Color.blue.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 25, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(Color.indigo.opacity(0.18)))
        }
    }

    private var nutritionTargetSetupButton: some View {
        Button {
            showNutritionTargetSetup = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "scope")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 48, height: 48)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set your daily nutrition targets")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Use recommended targets or enter your own before ChefBuddy builds the week.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var weekPlannerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your week at a glance")
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                    Text("Each row is one day. Scan breakfast, lunch, and dinner without opening seven separate cards.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if nutritionTargets != nil {
                    Button("Targets") { showNutritionTargetSetup = true }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.10), in: Capsule())
                }
            }

            if let nutritionTargets {
                HStack(spacing: 8) {
                    weekTargetPill(value: "\(nutritionTargets.calories)", label: "kcal")
                    weekTargetPill(value: "\(nutritionTargets.protein)g", label: "protein")
                    weekTargetPill(value: "≤\(nutritionTargets.sodium)", label: "sodium")
                }
            } else {
                nutritionTargetSetupButton
            }

            VStack(spacing: 11) {
                ForEach(days, id: \.self) { day in
                    weekDayCard(day: day, targets: nutritionTargets)
                }
            }
        }
    }

    private func weekTargetPill(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
            Text(label.uppercased())
                .font(.system(size: 8, weight: .black, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func nutritionGuideMetric(
        current: Double,
        target: Double,
        label: String,
        unit: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .black, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text("\(Int(current.rounded())) / \(Int(target.rounded()))\(unit)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.12))
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * min(current / max(target, 1), 1))
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func weekDayCard(day: String, targets: NutritionTargets?) -> some View {
        let summary = nutritionSummary(for: day)
        let calories = nutritionNumericValue(from: summary.calories)
        let calorieText = "\(Int(calories.rounded())) kcal"
        let dishCount = mealTypes
            .compactMap { slotFor(day: day, type: $0) }
            .flatMap(\.plannedEntries)
            .filter { !$0.displayTitle.isEmpty }
            .count
        let isPastOrDone = isPastDay(day) || isCompletedDay(day)

        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedDay = day
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                displayMode = .day
            }
        } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    HStack(spacing: 11) {
                        VStack(spacing: 0) {
                            Text(shortDay(day).uppercased())
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundStyle(day == currentWeekday ? .white.opacity(0.78) : .secondary)
                            Text(date(for: day)?.formatted(.dateTime.day()) ?? "—")
                                .font(.system(size: 21, weight: .heavy, design: .rounded))
                                .foregroundStyle(day == currentWeekday ? .white : .primary)
                        }
                        .frame(width: 48, height: 51)
                        .background(day == currentWeekday ? Color.orange : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(day)
                                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                                if day == currentWeekday {
                                    Text("TODAY")
                                        .font(.system(size: 8, weight: .black, design: .rounded))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text(dishCount == 0 ? "Open day—tap to plan it" : "\(dishCount) meal\(dishCount == 1 ? "" : "s") • \(calorieText)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 8) {
                    ForEach(mealTypes, id: \.self) { mealType in
                        weekMealTile(day: day, mealType: mealType)
                    }
                }

                if let targets, calories > 0 {
                    ProgressView(value: min(calories / Double(max(targets.calories, 1)), 1))
                        .tint(calories > Double(targets.calories) ? .red : .green)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(day == currentWeekday ? Color.orange.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: day == currentWeekday ? 2 : 1)
            )
            .opacity(isPastOrDone && day != currentWeekday ? 0.62 : 1)
        }
        .buttonStyle(.plain)
    }

    private func weekMealTile(day: String, mealType: String) -> some View {
        let entries = slotFor(day: day, type: mealType)?.plannedEntries ?? []
        let title = entries.first?.displayTitle ?? "Add meal"
        let icon = mealType == "Breakfast" ? "sunrise.fill" : mealType == "Lunch" ? "sun.max.fill" : "moon.stars.fill"
        let tint: Color = mealType == "Breakfast" ? .orange : mealType == "Lunch" ? .green : .indigo

        return VStack(alignment: .leading, spacing: 6) {
            Image(systemName: entries.isEmpty ? "plus.circle.fill" : icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
            Text(mealType.uppercased())
                .font(.system(size: 8, weight: .black, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(entries.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 25, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(entries.isEmpty ? 0.055 : 0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func weekDayStatChip(dishCount: Int, calorieText: String, isMuted: Bool) -> some View {
        HStack(spacing: 7) {
            Label("\(dishCount)", systemImage: "fork.knife")
            Text(calorieText)
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundStyle(isMuted ? Color.secondary : Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background((isMuted ? Color.primary : Color.orange).opacity(0.09), in: Capsule())
    }

    private func weekMealSummaryRow(day: String, mealType: String) -> some View {
        let slot = slotFor(day: day, type: mealType)
        let entries = slot?.plannedEntries ?? []
        let isEmpty = entries.isEmpty
        let isComplete = slot?.isCompleted == true
        let iconName = isEmpty ? "circle.dashed" : (isComplete ? "checkmark.circle.fill" : "circle.fill")
        let iconColor: Color = isEmpty ? .secondary : (isComplete ? .green : .orange)
        let title = isEmpty ? "Not planned" : entries.prefix(2).map(\.displayTitle).joined(separator: ", ")

        return HStack(spacing: 9) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(iconColor)
            Text(mealType)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
            Spacer()
            if entries.count > 1 {
                Text("+\(entries.count - 1)")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var legacyBody: some View {
        ZStack {
            ChefBuddyBackground()
            Circle()
                .fill(Color.orange.opacity(pulseHero ? 0.16 : 0.08))
                .blur(radius: 90)
                .offset(x: -170, y: -250)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: pulseHero)
            Circle()
                .fill(Color.green.opacity(pulseHero ? 0.14 : 0.07))
                .blur(radius: 100)
                .offset(x: 180, y: 320)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: pulseHero)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    AnimatedScreenHeader(
                        eyebrow: "Meal Plan",
                        title: "Shape your week",
                        subtitle: "\(filledSlotsCount)/21 slots planned and \(selectedDayFilledCount)/3 filled for \(selectedDay).",
                        systemImage: "calendar",
                        accent: .orange,
                        badgeText: "\(selectedDayFilledCount)/3 today"
                    )
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -12)

                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Planner controls")
                                .font(.system(size: 18, weight: .bold, design: .rounded))

                            Spacer()

                            Button(action: {
                                dayAssistantMealTypes = Set(mealTypes)
                                dayAssistantPrompt = ""
                                showDayAssistant = true
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "wand.and.stars")
                                    Text("Customize \(selectedDay) with AI")
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                }
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                                )
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(days, id: \.self) { day in
                                    DayButton(
                                        day: day,
                                        shortDay: shortDay(day),
                                        isSelected: selectedDay == day
                                    )
                                    .onTapGesture {
                                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                            selectedDay = day
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(18)
                    .background(.ultraThinMaterial.opacity(0.96), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -10)

                    DayNutritionSummaryCard(day: selectedDay, summary: selectedDayNutritionSummary)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : -8)

                    DisclosureGroup(isExpanded: $showDayInsights) {
                        VStack(spacing: 12) {
                            DailyExecutionSummaryCard(
                                day: selectedDay,
                                completedCount: selectedDayCompletionCount,
                                loggedCount: selectedDayMealLogs.count,
                                onLogMeal: { showMealLogSheet = true }
                            )

                            DayRealityComparisonCard(summary: selectedDayRealitySummary)

                            DailyCoachCard(
                                insight: displayedDailyCoachInsight,
                                isLoading: aiCoachLoading,
                                isAI: aiCoachInsight != nil
                            )
                        }
                        .padding(.top, 14)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.orange)
                                .frame(width: 42, height: 42)
                                .background(Color.orange.opacity(0.11), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Day insights and progress")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                Text("Cooking status, actual nutrition, and ChefBuddy guidance")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.orange)
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.primary.opacity(0.06), lineWidth: 1))
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -6)

                    VStack(spacing: 12) {
                        ForEach(mealTypes, id: \.self) { type in
                            MealSlotRow(
                                type: type,
                                slot: slotFor(type: type),
                                onTap: { handleSlotTap(type: type) },
                                onRemove: { removeSlot(type: type) },
                                onStatusSelect: { newStatus in
                                    updateSlotStatus(type: type, status: newStatus)
                                }
                            )
                        }
                    }
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -6)

                    Button(action: generateWeeklyPlan) {
                        HStack(spacing: 10) {
                            if vm.isGenerating {
                                ProgressView()
                                    .tint(.white)
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 14, weight: .bold))
                            }

                            Text(vm.isGenerating ? "Building Your Week..." : "Generate Weekly Plan")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: vm.isGenerating ? [.orange.opacity(0.95), .orange.opacity(0.85)] : [.orange, .green.opacity(0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .orange.opacity(0.28), radius: 12, y: 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isGenerating)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -2)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 150)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            heroVariant = Int.random(in: 0..<3)
            pulseHero = true
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(0.05)) {
                hasAppeared = true
            }
            selectedDay = currentWeekday

            if let uid = authVM.userSession?.uid {
                vm.startListening(userId: uid)
                recipesVM.startListening(userId: uid)
                startPantryListener(userId: uid)
            }
            requestAIDailyCoach()
        }
        .onDisappear {
            pantryListener?.remove()
            pantryListener = nil
            aiCoachTask?.cancel()
            aiCoachTask = nil
        }
        .onChange(of: authVM.currentUserProfile?.activePantryId) { pantryId in
            guard pantryId != selectedPantryId else { return }
            if let pantryId,
               pantrySpaces.contains(where: { $0.id == pantryId }) {
                selectedPantryId = pantryId
            } else if pantryId == nil, selectedPantryId != nil {
                selectedPantryId = pantrySpaces.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activePantrySelectionDidChange)) { note in
            let pantryId = note.userInfo?["pantryId"] as? String
            guard pantryId != selectedPantryId else { return }
            if let pantryId,
               pantrySpaces.contains(where: { $0.id == pantryId }) {
                selectedPantryId = pantryId
            } else if pantryId == nil {
                selectedPantryId = pantrySpaces.first?.id
            }
        }
        .onChange(of: coachContextSignature) { _ in
            requestAIDailyCoach()
        }
        .sheet(item: $selectedRecipeForDetail) { recipe in
            RecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                pantryIngredients: pantryIngredients,
                pantrySpaces: pantrySpaces,
                selectedPantryId: selectedPantryId,
                onFavorite: {
                    if let uid = authVM.userSession?.uid {
                        recipesVM.toggleFavorite(recipe, userId: uid)
                    }
                },
                onDelete: {
                    if let uid = authVM.userSession?.uid {
                        recipesVM.deleteRecipe(recipe, userId: uid)
                        selectedRecipeForDetail = nil
                    }
                },
                userId: authVM.userSession?.uid ?? "",
                onSelectPantry: { pantryId in
                    selectedPantryId = pantryId
                    authVM.updateActivePantrySelection(pantryId)
                }
            )
        }
        .sheet(item: $selectedPlannedRecipeForDetail) { recipe in
            SuggestedRecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                onSave: {
                    guard let uid = authVM.userSession?.uid else { return }
                    recipesVM.saveSuggestedRecipe(recipe, userId: uid)
                    selectedPlannedRecipeForDetail = nil
                    selectedPlanSlotForDetail = nil
                },
                onDislike: nil,
                onRecipeUpdated: { updatedRecipe in
                    guard let uid = authVM.userSession?.uid,
                          let slot = selectedPlanSlotForDetail else { return }
                    vm.updatePlannedRecipe(updatedRecipe, for: slot, userId: uid)
                    selectedPlannedRecipeForDetail = updatedRecipe
                },
                onLiveHelp: nil
            )
        }
        .sheet(isPresented: $showRecipePicker) {
            NavigationStack {
                ZStack {
                    ChefBuddyBackground()

                    if recipesVM.recipes.isEmpty {
                        VStack(spacing: 10) {
                            Text("No saved recipes yet")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Text("Create recipes first, then add them to your meal plan.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 28)
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Choose a recipe for \(selectedDay) \(selectedMealType ?? "")")
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 8)

                                LazyVGrid(
                                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                                    spacing: 14
                                ) {
                                    ForEach(recipesVM.recipes) { recipe in
                                        RecipeCard(
                                            recipe: recipe,
                                            onTap: {
                                                if let mealType = selectedMealType,
                                                   let uid = authVM.userSession?.uid {
                                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                                    vm.addToPlan(
                                                        recipe: recipe,
                                                        day: selectedDay,
                                                        mealType: mealType,
                                                        userId: uid
                                                    )
                                                }
                                                showRecipePicker = false
                                            },
                                            onFavorite: {
                                                if let uid = authVM.userSession?.uid {
                                                    recipesVM.toggleFavorite(recipe, userId: uid)
                                                }
                                            },
                                            isCooked: recipe.hasBeenCooked
                                        )
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                            .padding(.bottom, 16)
                        }
                    }
                }
                .navigationTitle("Choose Recipe")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { showRecipePicker = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showDayAssistant) {
            DayCustomizationSheet(
                day: selectedDay,
                mealTypes: mealTypes,
                selectedMealTypes: $dayAssistantMealTypes,
                prompt: $dayAssistantPrompt,
                occupiedMealTypes: Set(mealTypes.filter { slotFor(type: $0)?.displayTitle.isEmpty == false }),
                nutritionTargets: nutritionTargets,
                isGenerating: vm.isGenerating,
                errorMessage: vm.generationError,
                onGenerate: customizeSelectedDay
            )
        }
        .sheet(isPresented: $showMealLogSheet) {
            MealLogEntrySheet(
                day: selectedDay,
                defaultMealType: "Dinner",
                assistant: assistant,
                onSave: { draft in
                    saveMealLog(draft)
                }
            )
        }
    }

    private func startPantryListener(userId: String) {
        pantryListener?.remove()
        pantryListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("pantrySpaces")
            .addSnapshotListener { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                let spaces = docs.compactMap { document -> SimplePantrySpace? in
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
                    pantrySpaces = spaces
                    let preferred = authVM.currentUserProfile?.activePantryId
                    if selectedPantryId == nil,
                       let preferred,
                       spaces.contains(where: { $0.id == preferred }) {
                        selectedPantryId = preferred
                    } else if selectedPantryId == nil {
                        selectedPantryId = spaces.first?.id
                    } else if let selectedPantryId,
                                !spaces.contains(where: { $0.id == selectedPantryId }) {
                        self.selectedPantryId = spaces.first?.id
                    }
                }
            }
    }

    private func requestAIDailyCoach() {
        guard let userId = authVM.userSession?.uid, !userId.isEmpty else {
            aiCoachInsight = nil
            aiCoachLoading = false
            return
        }

        let cacheKey = "\(userId)|\(coachContextSignature)"
        if let cached = aiCoachCache[cacheKey] {
            aiCoachInsight = cached
            aiCoachLoading = false
            return
        }

        aiCoachTask?.cancel()
        aiCoachLoading = true

        let plannedRows = mealTypes.compactMap { type -> String? in
            guard let slot = slotFor(type: type), !slot.displayTitle.isEmpty else { return nil }
            return "\(type): \(slot.displayTitle)"
        }
        let logRows = selectedDayMealLogs.map { "\($0.mealType): \($0.title) (\($0.calories))" }
        let recentLogs = vm.mealLogEvents.prefix(7).map { "\($0.day) \($0.mealType): \($0.title) \($0.calories)" }
        let macroGoal = authVM.currentUserProfile?.macroTags.joined(separator: ", ") ?? "Balanced"
        let targetGoal = authVM.currentUserProfile?.targetGoal ?? "Maintain"
        let dailyCalorieTarget = authVM.currentUserProfile?.dailyCalorieTarget ?? 0
        let weeklyEntries = vm.weeklySlots.flatMap(\.plannedEntries)
        let weeklyPlannedCount = weeklyEntries.filter { !$0.displayTitle.isEmpty }.count
        let weeklyCompletedCount = weeklyEntries.filter(\.isCompleted).count
        let weeklyAdherenceRate = weeklyPlannedCount == 0 ? 0 : Int((Double(weeklyCompletedCount) / Double(weeklyPlannedCount) * 100).rounded())
        let plannedCalories = nutritionNumericValue(from: selectedDayNutritionSummary.calories)
        let consumedCalories = nutritionNumericValue(from: selectedDayConsumedSummary.calories)
        let calorieDelta = consumedCalories - plannedCalories
        let plannedProtein = nutritionNumericValue(from: selectedDayNutritionSummary.protein)
        let consumedProtein = nutritionNumericValue(from: selectedDayConsumedSummary.protein)
        let proteinDelta = consumedProtein - plannedProtein
        let cuisineTags = vm.weeklySlots
            .flatMap(\.plannedEntries)
            .compactMap { $0.plannedRecipe?.tags.first?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cuisineDiversity = Set(cuisineTags.map { $0.lowercased() }).count

        aiCoachTask = Task {
            do {
                try await assistant.waitUntilReady()

                let prompt = """
                You are ChefBuddy's nutrition and habit coach.
                Give a thoughtful, personalized daily coaching insight based on behavior patterns.
                Be specific, non-judgmental, and helpful.
                Sound like a sharp coach, not a calorie calculator.
                Keep every field concise and punchy.

                Return ONLY valid JSON:
                {
                  "focus": "Protein|Timing|Balance|Prep|Variety|Recovery|Consistency|Feedback|Momentum",
                  "headline": "max 8 words",
                  "nextAction": "one clear action, max 60 chars",
                  "benefit": "why this helps, max 42 chars"
                }

                Context:
                day: \(selectedDay)
                targetGoal: \(targetGoal)
                macroGoal: \(macroGoal)
                dailyCalorieTarget: \(dailyCalorieTarget)
                plannedTotals: calories=\(selectedDayNutritionSummary.calories), carbs=\(selectedDayNutritionSummary.carbs), protein=\(selectedDayNutritionSummary.protein), fat=\(selectedDayNutritionSummary.fat), sodium=\(selectedDayNutritionSummary.sodium)
                consumedTotals: calories=\(selectedDayConsumedSummary.calories), carbs=\(selectedDayConsumedSummary.carbs), protein=\(selectedDayConsumedSummary.protein), fat=\(selectedDayConsumedSummary.fat), sodium=\(selectedDayConsumedSummary.sodium)
                calorieDeltaToday: \(Int(calorieDelta.rounded())) kcal
                proteinDeltaToday: \(Int(proteinDelta.rounded())) g
                completion: \(selectedDayCompletionCount)/3 planned meals completed
                weeklyCompletion: \(weeklyCompletedCount)/\(weeklyPlannedCount) (\(weeklyAdherenceRate)%)
                cuisineDiversityThisWeek: \(cuisineDiversity)
                plannedMeals: \(plannedRows.joined(separator: " | "))
                loggedMeals: \(logRows.joined(separator: " | "))
                recentLogs: \(recentLogs.joined(separator: " | "))
                """

                let raw = try await assistant.getHelp(question: prompt)
                let aiInsight: DailyCoachInsight
                if let json = extractJSONObject(from: raw),
                   let data = json.data(using: .utf8),
                   let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let focus = (object["focus"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let headline = (object["headline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let nextAction = (object["nextAction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let benefit = (object["benefit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let candidate = DailyCoachInsight(
                        focus: focus.isEmpty ? fallbackDailyCoachInsight.focus : focus,
                        headline: headline.isEmpty ? fallbackDailyCoachInsight.headline : headline,
                        nextAction: nextAction.isEmpty ? fallbackDailyCoachInsight.nextAction : nextAction,
                        benefit: benefit.isEmpty ? fallbackDailyCoachInsight.benefit : benefit
                    )
                    aiInsight = candidate
                } else {
                    aiInsight = fallbackDailyCoachInsight
                }

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    aiCoachCache[cacheKey] = aiInsight
                    aiCoachInsight = aiInsight
                    aiCoachLoading = false
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    aiCoachInsight = nil
                    aiCoachLoading = false
                }
            }
        }
    }

    private func extractJSONObject(from text: String) -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("{"), source.hasSuffix("}") {
            return source
        }

        guard let start = source.firstIndex(of: "{"),
              let end = source.lastIndex(of: "}") else {
            return nil
        }
        return String(source[start...end])
    }
}

private struct DailyCoachInsight: Equatable {
    var focus: String
    var headline: String
    var nextAction: String
    var benefit: String
}


private struct SimplifiedMealPlanRow: View {
    let mealType: String
    let slot: MealPlanSlot?
    let onAdd: () -> Void
    let onOpenEntry: (MealPlanEntry) -> Void
    let onRemoveEntry: (MealPlanEntry) -> Void
    let onStatusChange: (MealPlanEntry, MealPlanSlotStatus) -> Void

    private var icon: String {
        switch mealType {
        case "Breakfast": return "sunrise.fill"
        case "Lunch": return "sun.max.fill"
        default: return "moon.stars.fill"
        }
    }

    private var entries: [MealPlanEntry] {
        slot?.plannedEntries ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 42, height: 42)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(mealType)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                    Text(entries.isEmpty ? "No dishes planned yet" : "\(entries.count) dish\(entries.count == 1 ? "" : "es") planned")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.orange, in: Circle())
                }
                .buttonStyle(.plain)
            }

            if entries.isEmpty {
                Button(action: onAdd) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Add a \(mealType.lowercased()) dish")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Spacer()
                    }
                    .padding(13)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 9) {
                    ForEach(entries) { entry in
                        mealEntryRow(entry)
                    }
                }
            }
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func mealEntryRow(_ entry: MealPlanEntry) -> some View {
        HStack(spacing: 11) {
            Button {
                onOpenEntry(entry)
            } label: {
                HStack(spacing: 11) {
                    Text(entry.plannedRecipe?.emoji ?? "🍽️")
                        .font(.system(size: 22))
                        .frame(width: 38, height: 38)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.displayTitle.isEmpty ? "Untitled dish" : entry.displayTitle)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let recipe = entry.plannedRecipe {
                            Text("\(recipe.calories) • \(recipe.cookTime)")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(MealPlanSlotStatus.allCases, id: \.self) { status in
                    Button(status.title) { onStatusChange(entry, status) }
                }
                Divider()
                Button("Remove Dish", role: .destructive) { onRemoveEntry(entry) }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: entry.isCompleted ? "checkmark.circle.fill" : "ellipsis.circle")
                        .font(.system(size: 20, weight: .semibold))
                    Text(entry.resolvedStatus.title)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .foregroundStyle(entry.isCompleted ? .green : .secondary)
                .frame(width: 54)
            }
        }
        .padding(11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct NutritionTargetProgressCard: View {
    let day: String
    let summary: DayNutritionSummary
    let targets: NutritionTargets
    let onEdit: () -> Void

    private var calorieCurrent: Double {
        nutritionNumericValue(from: summary.calories)
    }

    private var calorieProgress: Double {
        min(calorieCurrent / Double(max(targets.calories, 1)), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(day) nutrition guide")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                    Text("Planned meals compared with your full-day targets")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit", action: onEdit)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.10), in: Capsule())
            }

            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(Color.indigo.opacity(0.12), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: calorieProgress)
                        .stroke(
                            LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text("\(Int(calorieCurrent.rounded()))")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                        Text("of \(targets.calories)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("KCAL")
                            .font(.system(size: 7, weight: .black, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(.indigo)
                    }
                }
                .frame(width: 112, height: 112)

                VStack(alignment: .leading, spacing: 7) {
                    Text(calorieProgress >= 0.85 ? "The day is taking shape" : "There is room in the plan")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(calorieProgress >= 0.85
                         ? "Your planned meals are tracking near the saved energy target."
                         : "Add or adjust meals to move the plan toward your daily guide.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(targets.source == .recommended ? "ChefBuddy recommended" : "Manually set")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.indigo.opacity(0.10), in: Capsule())
                }
            }

            VStack(spacing: 9) {
                macroTile("Protein", current: nutritionNumericValue(from: summary.protein), target: targets.protein, color: .green, unit: "g")
                macroTile("Carbs", current: nutritionNumericValue(from: summary.carbs), target: targets.carbs, color: .blue, unit: "g")
                macroTile("Fat", current: nutritionNumericValue(from: summary.fat), target: targets.fat, color: .pink, unit: "g")
                macroTile("Sodium", current: nutritionNumericValue(from: summary.sodium), target: targets.sodium, color: .purple, unit: "mg")
            }

        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func macroTile(_ title: String, current: Double, target: Int, color: Color, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Text("\(Int(current.rounded())) of \(target)\(unit)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.12))
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * min(current / Double(max(target, 1)), 1))
                }
            }
            .frame(height: 7)
        }
        .padding(12)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func targetRow(_ title: String, current: Double, target: Double, color: Color, unit: String) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Text("\(Int(current.rounded())) / \(Int(target.rounded())) \(unit)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(current / max(target, 1), 1))
                .tint(color)
        }
    }
}

private struct NutritionTargetSetupSheet: View {
    let profile: DBUser
    @ObservedObject var assistant: CookingAssistant
    let currentTargets: NutritionTargets?
    let onSave: (NutritionTargets) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var calories = 2000
    @State private var carbs = 250
    @State private var protein = 100
    @State private var fat = 70
    @State private var sodium = 2300
    @State private var source: NutritionTargetSource = .manual
    @State private var isRecommending = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Nutrition Targets")
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                            Text("Set the daily guide ChefBuddy should use when building and evaluating your meal plan.")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                        }

                        Picker("Target source", selection: $source) {
                            Text("Recommended").tag(NutritionTargetSource.recommended)
                            Text("Manual").tag(NutritionTargetSource.manual)
                        }
                        .pickerStyle(.segmented)

                        if source == .recommended {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 13) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(.orange)
                                        .frame(width: 46, height: 46)
                                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Personalized starting point")
                                            .font(.system(size: 16, weight: .bold, design: .rounded))
                                        Text("Uses your body profile, activity, goal, and macro preferences.")
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Button {
                                    recommendTargets()
                                } label: {
                                    HStack {
                                        if isRecommending { ProgressView().tint(.white) }
                                        Text(isRecommending ? "Calculating..." : "Refresh Recommended Targets")
                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(isRecommending)
                            }
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Daily targets")
                                .font(.system(size: 18, weight: .heavy, design: .rounded))

                            targetEditorCard("Calories", icon: "flame.fill", value: $calories, unit: "kcal", step: 50, range: 800...6000, color: .orange)
                            targetEditorCard("Carbohydrates", icon: "chart.bar.fill", value: $carbs, unit: "g", step: 5, range: 25...800, color: .blue)
                            targetEditorCard("Protein", icon: "bolt.heart.fill", value: $protein, unit: "g", step: 5, range: 20...400, color: .green)
                            targetEditorCard("Fat", icon: "drop.fill", value: $fat, unit: "g", step: 5, range: 15...300, color: .pink)
                            targetEditorCard("Sodium", icon: "waveform.path", value: $sodium, unit: "mg", step: 50, range: 500...6000, color: .purple)
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.red)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        Text("ChefBuddy recommendations are general estimates. Check with a registered dietitian or healthcare professional for personalized nutrition advice.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)

                        Spacer(minLength: 90)
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onSave(
                        NutritionTargets.validated(
                            calories: calories,
                            carbs: carbs,
                            protein: protein,
                            fat: fat,
                            sodium: sodium,
                            source: source
                        )
                    )
                } label: {
                    Label("Save Nutrition Targets", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            LinearGradient(colors: [.orange, .green.opacity(0.86)], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.regularMaterial)
            }
            .onAppear {
                if let currentTargets {
                    calories = currentTargets.calories
                    carbs = currentTargets.carbs
                    protein = currentTargets.protein
                    fat = currentTargets.fat
                    sodium = currentTargets.sodium
                    source = currentTargets.source
                } else {
                    calories = profile.dailyCalorieTarget ?? 2000
                }
            }
        }
    }

    private func targetEditorCard(
        _ title: String,
        icon: String,
        value: Binding<Int>,
        unit: String,
        step: Int,
        range: ClosedRange<Int>,
        color: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                HStack(spacing: 4) {
                    TextField("0", value: value, format: .number)
                        .keyboardType(.numberPad)
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .frame(width: 80)
                    Text(unit)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in
                    if !isRecommending { source = .manual }
                }
        }
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(color.opacity(0.14), lineWidth: 1)
        )
    }

    private func recommendTargets() {
        isRecommending = true
        errorMessage = nil

        Task {
            do {
                let prompt = """
                Recommend reasonable daily nutrition targets for meal planning.
                Return ONLY JSON with integer values:
                {"calories":2000,"carbs":250,"protein":120,"fat":65,"sodium":2300}

                Age: \(profile.age)
                Height inches: \(profile.height)
                Weight pounds: \(profile.weight)
                Sex: \(profile.sex)
                Activity: \(profile.activityLevel)
                Goal: \(profile.targetGoal)
                Macro preferences: \(profile.macroTags.joined(separator: ", "))
                Current calorie estimate: \(profile.dailyCalorieTarget ?? 0)
                """
                let response = try await assistant.getHelp(question: prompt)
                guard let json = CookingAssistant.extractJSONObject(from: response),
                      let data = json.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let recommendedCalories = (object["calories"] as? NSNumber)?.intValue,
                      let recommendedCarbs = (object["carbs"] as? NSNumber)?.intValue,
                      let recommendedProtein = (object["protein"] as? NSNumber)?.intValue,
                      let recommendedFat = (object["fat"] as? NSNumber)?.intValue,
                      let recommendedSodium = (object["sodium"] as? NSNumber)?.intValue else {
                    throw CookingAssistantError.invalidRecipeResponse
                }

                let validated = NutritionTargets.validated(
                    calories: recommendedCalories,
                    carbs: recommendedCarbs,
                    protein: recommendedProtein,
                    fat: recommendedFat,
                    sodium: recommendedSodium,
                    source: .recommended
                )

                await MainActor.run {
                    calories = validated.calories
                    carbs = validated.carbs
                    protein = validated.protein
                    fat = validated.fat
                    sodium = validated.sodium
                    source = .recommended
                    isRecommending = false
                }
            } catch {
                await MainActor.run {
                    isRecommending = false
                    errorMessage = "ChefBuddy couldn’t calculate targets right now. You can still enter them manually."
                }
            }
        }
    }
}

struct DayButton: View {
    let day: String
    let shortDay: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(shortDay)
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Text(day.prefix(1))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .opacity(0.65)
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .frame(width: 42, height: 44)
        .background(
            Group {
                if isSelected {
                    LinearGradient(
                        colors: [.orange, .green.opacity(0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                } else {
                    Color.primary.opacity(0.08)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(isSelected ? 0 : 0.07), lineWidth: 1)
        )
    }
}

private struct DayCustomizationSheet: View {
    let day: String
    let mealTypes: [String]
    @Binding var selectedMealTypes: Set<String>
    @Binding var prompt: String
    let occupiedMealTypes: Set<String>
    let nutritionTargets: NutritionTargets?
    let isGenerating: Bool
    let errorMessage: String?
    let onGenerate: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIntent: String?
    @State private var didStartGeneration = false

    private let intents = [
        ("Lighter", "leaf.fill", "Make the selected meals lighter and vegetable-forward."),
        ("High Protein", "bolt.heart.fill", "Prioritize high-protein meals with balanced sides."),
        ("Quick", "timer", "Keep every selected meal quick and practical."),
        ("Comfort Food", "heart.fill", "Make the selected meals cozy and comforting."),
        ("Budget", "dollarsign.circle.fill", "Use affordable, reusable ingredients.")
    ]

    private var targetPrompt: String? {
        guard let nutritionTargets else { return nil }
        return """
        Auto-fill the selected meals so the complete day moves as close as practical to my daily targets: \
        \(nutritionTargets.calories) calories, \(nutritionTargets.protein)g protein, \
        \(nutritionTargets.carbs)g carbohydrates, \(nutritionTargets.fat)g fat, and no more than \
        \(nutritionTargets.sodium)mg sodium. Balance the selected meals against anything already planned.
        """
    }

    private var selectedOccupiedMeals: [String] {
        mealTypes.filter { selectedMealTypes.contains($0) && occupiedMealTypes.contains($0) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Adjust \(day)")
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .padding(.top, 8)

                            Text("Choose the meals, set the direction, then review exactly what ChefBuddy will replace.")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Label("1. Choose meals", systemImage: "checklist")
                                .font(.system(size: 15, weight: .bold, design: .rounded))

                            VStack(spacing: 9) {
                                ForEach(mealTypes, id: \.self) { mealType in
                                    let selected = selectedMealTypes.contains(mealType)
                                    Button {
                                        if selected {
                                            selectedMealTypes.remove(mealType)
                                        } else {
                                            selectedMealTypes.insert(mealType)
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 20, weight: .bold))
                                                .foregroundStyle(selected ? .orange : .secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(mealType)
                                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                                Text(occupiedMealTypes.contains(mealType) ? "Currently planned • will be replaced" : "Empty slot • will be filled")
                                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: mealType == "Breakfast" ? "sunrise.fill" : mealType == "Lunch" ? "sun.max.fill" : "moon.stars.fill")
                                                .foregroundStyle(selected ? .orange : .secondary)
                                        }
                                        .padding(13)
                                        .background(
                                            selected ? Color.orange.opacity(0.10) : Color.primary.opacity(0.045),
                                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(selected ? Color.orange.opacity(0.40) : Color.primary.opacity(0.05), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isGenerating)
                                }
                            }
                        }
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                        VStack(alignment: .leading, spacing: 12) {
                            Label("2. Pick a direction", systemImage: "wand.and.stars")
                                .font(.system(size: 15, weight: .bold, design: .rounded))

                            if let targetPrompt, let nutritionTargets {
                                Button {
                                    selectedIntent = "Meet My Targets"
                                    prompt = targetPrompt
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selectedIntent == "Meet My Targets" ? "checkmark.circle.fill" : "scope")
                                            .font(.system(size: 20, weight: .bold))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Auto-fill to meet my targets")
                                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                            Text("\(nutritionTargets.calories) kcal • \(nutritionTargets.protein)g protein • ≤\(nutritionTargets.sodium)mg sodium")
                                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                                .foregroundStyle(selectedIntent == "Meet My Targets" ? .white.opacity(0.82) : .secondary)
                                        }
                                        Spacer()
                                    }
                                    .foregroundStyle(selectedIntent == "Meet My Targets" ? .white : .primary)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        selectedIntent == "Meet My Targets"
                                            ? AnyShapeStyle(LinearGradient(colors: [.orange, .green.opacity(0.88)], startPoint: .leading, endPoint: .trailing))
                                            : AnyShapeStyle(Color.primary.opacity(0.06)),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isGenerating)
                            }

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 9)], spacing: 9) {
                                ForEach(intents, id: \.0) { intent in
                                    Button {
                                        selectedIntent = intent.0
                                        prompt = intent.2
                                    } label: {
                                        Label(intent.0, systemImage: intent.1)
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .foregroundStyle(selectedIntent == intent.0 ? .white : .primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 11)
                                            .background(
                                                selectedIntent == intent.0 ? Color.orange : Color.primary.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isGenerating)
                                }
                            }

                            TextField("Add details: cuisine, ingredients, time, or anything to avoid…", text: $prompt, axis: .vertical)
                                .font(.system(size: 14, design: .rounded))
                                .lineLimit(3...6)
                                .padding(14)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .disabled(isGenerating)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                        VStack(alignment: .leading, spacing: 11) {
                            Label("3. Review changes", systemImage: "eye.fill")
                                .font(.system(size: 15, weight: .bold, design: .rounded))

                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selectedOccupiedMeals.isEmpty ? "checkmark.shield.fill" : "arrow.triangle.2.circlepath.circle.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(selectedOccupiedMeals.isEmpty ? .green : .orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(selectedOccupiedMeals.isEmpty
                                         ? "No existing meals will be overwritten"
                                         : "\(selectedOccupiedMeals.joined(separator: ", ")) will be replaced")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                    Text("\(selectedMealTypes.count) meal slot\(selectedMealTypes.count == 1 ? "" : "s") selected. Other meals on \(day) stay unchanged.")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                        if isGenerating {
                            HStack(spacing: 13) {
                                ProgressView().tint(.orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Refreshing \(day)")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                    Text("ChefBuddy is balancing your choices against the rest of the day.")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        } else if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.red)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        Spacer(minLength: 90)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(isGenerating)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    didStartGeneration = true
                    onGenerate()
                } label: {
                    HStack(spacing: 10) {
                        if isGenerating { ProgressView().tint(.white) }
                        Image(systemName: "sparkles")
                        Text(isGenerating
                             ? "Building \(day)…"
                             : selectedOccupiedMeals.isEmpty ? "Fill Selected Meals" : "Replace Selected Meals")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        selectedMealTypes.isEmpty ? Color.secondary.opacity(0.35) : Color.orange,
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(selectedMealTypes.isEmpty || isGenerating)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.regularMaterial)
            }
            .interactiveDismissDisabled(isGenerating)
            .onChange(of: isGenerating) { wasGenerating, nowGenerating in
                if wasGenerating && !nowGenerating && didStartGeneration && errorMessage == nil {
                    dismiss()
                }
            }
        }
    }
}

struct DayNutritionSummaryCard: View {
    let day: String
    let summary: DayNutritionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(day)'s Nutrition Snapshot")
                    .font(.system(size: 18, weight: .bold, design: .rounded))

                Text("Total intake from the meals planned for this day.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                NutritionChip(label: "Calories", value: summary.calories, color: .red)
                NutritionChip(label: "Carbs", value: summary.carbs, color: .orange)
            }

            HStack(spacing: 10) {
                NutritionChip(label: "Protein", value: summary.protein, color: .green)
                NutritionChip(label: "Fat", value: summary.fat, color: .blue)
            }

            NutritionChip(label: "Sodium", value: summary.sodium, color: .purple)
        }
        .padding(18)
        .background(.ultraThinMaterial.opacity(0.93), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct NutritionChip: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct MealPlanNutritionWheel: View {
    let protein: Double
    let carbs: Double
    let fat: Double

    private var total: Double {
        max(1, protein + carbs + fat)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 14)

            Circle()
                .trim(from: 0, to: CGFloat(protein / total))
                .stroke(Color.green, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle()
                .trim(from: CGFloat(protein / total), to: CGFloat((protein + carbs) / total))
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle()
                .trim(from: CGFloat((protein + carbs) / total), to: 1)
                .stroke(Color.pink, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 2) {
                Text("\(Int((protein + carbs + fat).rounded()))g")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                Text("Macros")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DailyExecutionSummaryCard: View {
    let day: String
    let completedCount: Int
    let loggedCount: Int
    let onLogMeal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(day) execution")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("\(completedCount)/3 planned meals completed • \(loggedCount) extra logs")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Button(action: onLogMeal) {
                    Label("Log Off-App Meal", systemImage: "square.and.pencil")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue.opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial.opacity(0.93), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct DayRealityComparisonCard: View {
    let summary: DayNutritionRealitySummary

    var deltaColor: Color {
        if summary.deltaCalories.hasPrefix("+") {
            return .orange
        }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Planned vs consumed")
                .font(.system(size: 17, weight: .bold, design: .rounded))

            HStack(spacing: 10) {
                NutritionChip(label: "Planned", value: summary.planned.calories, color: .blue)
                NutritionChip(label: "Consumed", value: summary.consumed.calories, color: .green)
            }

            HStack {
                Label("Calorie delta", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(summary.deltaCalories)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(deltaColor)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial.opacity(0.93), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct DailyCoachCard: View {
    let insight: DailyCoachInsight
    var isLoading: Bool = false
    var isAI: Bool = false

    private var accent: Color {
        switch insight.focus.lowercased() {
        case "protein": return .green
        case "timing": return .orange
        case "balance": return .blue
        case "prep": return .purple
        case "variety": return .pink
        case "recovery": return .teal
        case "feedback": return .indigo
        case "consistency": return .orange
        default: return .orange
        }
    }

    private var iconName: String {
        switch insight.focus.lowercased() {
        case "protein": return "bolt.heart.fill"
        case "timing": return "clock.fill"
        case "balance": return "scale.3d"
        case "prep": return "list.bullet.clipboard.fill"
        case "variety": return "sparkles"
        case "recovery": return "leaf.fill"
        case "feedback": return "waveform.path.ecg"
        case "consistency": return "flame.fill"
        default: return "sparkles"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.16))
                        .frame(width: 40, height: 40)
                    Image(systemName: iconName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("AI Daily Coach")
                            .font(.system(size: 14, weight: .bold, design: .rounded))

                        Text(insight.focus)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(accent.opacity(0.12), in: Capsule())
                    }
                    Text(isLoading ? "Reading your day..." : insight.headline)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if isAI {
                    Text("AI")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.85), in: Capsule())
                }
            }

            if isLoading {
                Text("ChefBuddy is comparing your plan, completions, and what you actually ate.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    coachMiniPill(text: insight.benefit, systemImage: "sparkles", tint: accent)

                    Text(insight.nextAction)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.93), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func coachMiniPill(text: String, systemImage: String, tint: Color, fill: Color? = nil) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background((fill ?? tint.opacity(0.12)), in: Capsule())
    }
}

struct MealSlotRow: View {
    let type: String
    let slot: MealPlanSlot?
    let onTap: () -> Void
    var onRemove: (() -> Void)? = nil
    var onStatusSelect: ((MealPlanSlotStatus) -> Void)? = nil

    private var iconName: String {
        switch type {
        case "Breakfast": return "sunrise.fill"
        case "Lunch": return "sun.max.fill"
        default: return "moon.stars.fill"
        }
    }

    private var accent: Color {
        switch type {
        case "Breakfast": return .orange
        case "Lunch": return .green
        default: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.18))
                            .frame(width: 34, height: 34)
                        Image(systemName: iconName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(accent)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(type)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)

                        Text(slot?.displayTitle.isEmpty == false ? slot?.displayTitle ?? "" : "Tap to add recipe")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle((slot?.displayTitle.isEmpty ?? true) ? .secondary : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if let plannedRecipe = slot?.plannedRecipe {
                            HStack(spacing: 8) {
                                Text(plannedRecipe.calories.isEmpty ? "Nutrition pending" : plannedRecipe.calories)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.red)

                                Text(plannedRecipe.description)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        if let status = slot?.status {
                            Text(status.title)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(status == .cooked || status == .logged ? .green : .secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    (status == .cooked || status == .logged ? Color.green : Color.primary)
                                        .opacity(0.12),
                                    in: Capsule()
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if slot?.displayTitle.isEmpty ?? true {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if !(slot?.displayTitle.isEmpty ?? true) {
                if onStatusSelect != nil {
                    Menu {
                        ForEach(MealPlanSlotStatus.allCases, id: \.rawValue) { status in
                            Button(status.title) {
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                onStatusSelect?(status)
                            }
                        }
                    } label: {
                        Image(systemName: "checklist.checked")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(10)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onRemove?()
                }) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.red)
                        .padding(10)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct MealLogEntrySheet: View {
    let day: String
    let defaultMealType: String
    @ObservedObject var assistant: CookingAssistant
    let onSave: (MealLogDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = MealLogDraft()
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedPhotoImage: UIImage? = nil
    @State private var isEstimating = false
    @State private var isSaving = false

    private let mealTypeOptions = ["Breakfast", "Lunch", "Dinner", "Snack"]

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.calories.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Log what you actually ate")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .padding(.top, 8)

                        Text("Track off-plan meals with quick AI estimates or manual values so your plan learns from real intake.")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        Picker("Input", selection: $draft.mode) {
                            ForEach(MealLogInputMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Meal slot")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Picker("Meal slot", selection: $draft.mealType) {
                                ForEach(mealTypeOptions, id: \.self) { type in
                                    Text(type).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Meal name")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                            TextField("Paneer wrap, protein bowl, cereal + fruit...", text: $draft.title)
                                .textInputAutocapitalization(.words)
                                .padding(12)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Notes / portion")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                            TextField("Example: medium bowl, 1.5 cups", text: $draft.notes, axis: .vertical)
                                .lineLimit(2...4)
                                .padding(12)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        if draft.mode == .photo {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Photo")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)

                                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                    Label(selectedPhotoImage == nil ? "Choose meal photo" : "Change photo", systemImage: "photo")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)

                                if selectedPhotoImage != nil {
                                    Label("Photo selected", systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.green)
                                }
                            }
                        }

                        if draft.mode != .manual {
                            Button(action: estimateWithAI) {
                                HStack(spacing: 10) {
                                    if isEstimating {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "sparkles")
                                    }
                                    Text(isEstimating ? "Estimating..." : "Estimate Nutrition")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isEstimating || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        nutritionFieldsSection

                        Button(action: save) {
                            HStack(spacing: 8) {
                                if isSaving {
                                    ProgressView()
                                        .tint(.white)
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                Text(isSaving ? "Saving..." : "Save Meal Log")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(colors: [.green.opacity(0.85), .teal.opacity(0.75)], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSave || isSaving)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 26)
                }
            }
            .navigationTitle("\(day) meal log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            draft.mealType = defaultMealType
        }
        .onChange(of: selectedPhotoItem) { _ in
            Task { await loadSelectedPhoto() }
        }
        .onChange(of: draft.mode) { mode in
            if mode == .manual {
                draft.isEstimated = false
                draft.confidence = nil
            }
        }
    }

    private var nutritionFieldsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nutrition")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    nutritionField("kcal", text: $draft.calories, unit: "kcal", color: .orange)
                    nutritionField("Carbs", text: $draft.carbs, unit: "g", color: .blue)
                    nutritionField("Protein", text: $draft.protein, unit: "g", color: .green)
                    nutritionField("Fat", text: $draft.fat, unit: "g", color: .pink)
                    nutritionField("Sodium", text: $draft.sodium, unit: "mg", color: .purple)
                }
                .frame(maxWidth: .infinity)

                MealPlanNutritionWheel(
                    protein: nutritionNumericValue(from: draft.protein),
                    carbs: nutritionNumericValue(from: draft.carbs),
                    fat: nutritionNumericValue(from: draft.fat)
                )
                .frame(width: 108, height: 108)
            }

            if let confidence = draft.confidence, !confidence.isEmpty {
                Text("AI confidence: \(confidence)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func nutritionField(_ label: String, text: Binding<String>, unit: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            TextField("0", text: text)
                .keyboardType(.numbersAndPunctuation)
                .font(.system(size: 13, weight: .bold, design: .rounded))

            Text(unit)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func editableRowsSection(
        title: String,
        subtitle: String,
        rows: Binding<[String]>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    rows.wrappedValue.append("")
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(rows.wrappedValue.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 8) {
                    TextField(placeholder, text: Binding(
                        get: { rows.wrappedValue[index] },
                        set: { rows.wrappedValue[index] = $0 }
                    ))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        guard rows.wrappedValue.count > 1 else { return }
                        rows.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(rows.wrappedValue.count > 1 ? .red : .secondary.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func normalizeNutrition(_ value: String, unit: String) -> String {
        let numeric = nutritionNumericValue(from: value)
        guard numeric > 0 else { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if numeric.rounded() == numeric {
            if unit == "kcal" {
                return "\(Int(numeric)) kcal"
            }
            return "\(Int(numeric))\(unit)"
        }
        if unit == "kcal" {
            return "\(String(format: "%.1f", numeric)) kcal"
        }
        return "\(String(format: "%.1f", numeric))\(unit)"
    }

    private func save() {
        guard !isSaving, canSave else { return }
        isSaving = true
        Task {
            var finalDraft = draft
            finalDraft.calories = normalizeNutrition(finalDraft.calories, unit: "kcal")
            finalDraft.carbs = normalizeNutrition(finalDraft.carbs, unit: "g")
            finalDraft.protein = normalizeNutrition(finalDraft.protein, unit: "g")
            finalDraft.fat = normalizeNutrition(finalDraft.fat, unit: "g")
            finalDraft.sodium = normalizeNutrition(finalDraft.sodium, unit: "mg")
            finalDraft.ingredients = []
            finalDraft.steps = []
            await MainActor.run {
                onSave(finalDraft)
                isSaving = false
                dismiss()
            }
        }
    }

    private func loadSelectedPhoto() async {
        guard let selectedPhotoItem else { return }
        do {
            guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                selectedPhotoImage = image
            }
        } catch {
            print("Failed to load selected meal log photo: \(error.localizedDescription)")
        }
    }

    private func estimateWithAI() {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        isEstimating = true
        Task {
            do {
                let prompt = """
                Estimate nutrition for this meal log.
                Return ONLY valid JSON:
                {
                  "calories": "420 kcal",
                  "carbs": "42g",
                  "protein": "30g",
                  "fat": "14g",
                  "sodium": "540mg",
                  "confidence": "high|medium|low"
                }

                Meal: \(title)
                Portion notes: \(draft.notes)
                """

                let responseText: String
                if draft.mode == .photo, let image = selectedPhotoImage {
                    responseText = try await assistant.getLiveHelp(image: image, question: prompt)
                } else {
                    responseText = try await assistant.getHelp(question: prompt)
                }

                guard let jsonObject = extractJSONObject(from: responseText),
                      let data = jsonObject.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    await MainActor.run { isEstimating = false }
                    return
                }

                await MainActor.run {
                    draft.calories = (object["calories"] as? String) ?? draft.calories
                    draft.carbs = (object["carbs"] as? String) ?? draft.carbs
                    draft.protein = (object["protein"] as? String) ?? draft.protein
                    draft.fat = (object["fat"] as? String) ?? draft.fat
                    draft.sodium = (object["sodium"] as? String) ?? draft.sodium
                    draft.confidence = (object["confidence"] as? String)?.capitalized
                    draft.isEstimated = true
                    isEstimating = false
                }
            } catch {
                await MainActor.run {
                    isEstimating = false
                }
            }
        }
    }

    private func extractJSONObject(from text: String) -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("{"), source.hasSuffix("}") {
            return source
        }

        guard let start = source.firstIndex(of: "{"),
              let end = source.lastIndex(of: "}") else {
            return nil
        }
        return String(source[start...end])
    }

    private func polishDraftWithAI(_ source: MealLogDraft) async -> MealLogDraft {
        let cleanIngredients = source.ingredients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanSteps = source.steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleanIngredients.isEmpty || !cleanSteps.isEmpty else {
            return source
        }

        do {
            let prompt = """
            Polish this meal log ingredient list and step list so they are clear and complete.
            Return ONLY JSON:
            {
              "ingredients": ["..."],
              "steps": ["..."]
            }
            Meal: \(source.title)
            Notes: \(source.notes)
            Ingredients: \(cleanIngredients.joined(separator: " | "))
            Steps: \(cleanSteps.joined(separator: " | "))
            """
            let raw = try await assistant.getHelp(question: prompt)
            guard let json = extractJSONObject(from: raw),
                  let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return source
            }

            var updated = source
            if let ingredients = object["ingredients"] as? [String], !ingredients.isEmpty {
                updated.ingredients = ingredients
            }
            if let steps = object["steps"] as? [String], !steps.isEmpty {
                updated.steps = steps
            }
            return updated
        } catch {
            return source
        }
    }
}

private struct CustomMealRecipeSheet: View {
    let day: String
    let defaultMealType: String
    @ObservedObject var assistant: CookingAssistant
    let onSave: (CustomMealRecipeDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CustomMealRecipeDraft()
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedPhotoImage: UIImage? = nil
    @State private var isAIFilling = false
    @State private var isSaving = false

    private let mealTypeOptions = ["Breakfast", "Lunch", "Dinner"]

    private var canSave: Bool {
        let titleOk = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ingredientsOk = draft.ingredients.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let stepsOk = draft.steps.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return titleOk && ingredientsOk && stepsOk
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Create custom recipe card")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .padding(.top, 8)

                        Text("Build your own recipe and drop it directly into \(day)’s plan.")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 12) {
                            Picker("Meal", selection: $draft.mealType) {
                                ForEach(mealTypeOptions, id: \.self) { type in
                                    Text(type).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)

                            HStack(spacing: 10) {
                                TextField("Emoji", text: $draft.emoji)
                                    .frame(width: 76)
                                    .padding(10)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                                TextField("Recipe title", text: $draft.title)
                                    .textInputAutocapitalization(.words)
                                    .padding(10)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            HStack(spacing: 10) {
                                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                    Label(selectedPhotoImage == nil ? "Add Photo" : "Change Photo", systemImage: "photo")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(Color.blue.opacity(0.84), in: Capsule())
                                }

                                Button(action: fillWithAI) {
                                    HStack(spacing: 8) {
                                        if isAIFilling {
                                            ProgressView()
                                                .tint(.white)
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "sparkles")
                                        }
                                        Text(isAIFilling ? "ChefBuddy is filling..." : "ChefBuddy Fill")
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
                                        in: Capsule()
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isAIFilling || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            TextField("Short description", text: $draft.description, axis: .vertical)
                                .lineLimit(2...4)
                                .padding(10)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Recipe Filters")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 10) {
                                    filterMetricCard(
                                        icon: "clock.fill",
                                        label: "Prep",
                                        value: "\(draft.prepMinutes) mins"
                                    ) {
                                        Stepper("", value: $draft.prepMinutes, in: 5...240, step: 5)
                                            .labelsHidden()
                                    }

                                    filterMetricCard(
                                        icon: "person.2.fill",
                                        label: "Serves",
                                        value: "\(draft.servingsCount)"
                                    ) {
                                        Stepper("", value: $draft.servingsCount, in: 1...12)
                                            .labelsHidden()
                                    }
                                }

                                Picker("Difficulty", selection: $draft.difficulty) {
                                    Text("🟢 Easy").tag("Easy")
                                    Text("🟠 Medium").tag("Medium")
                                    Text("🔴 Hard").tag("Hard")
                                }
                                .pickerStyle(.segmented)

                                TextField("Tags (comma-separated)", text: $draft.tagsText)
                                    .padding(10)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Nutrition")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)

                                HStack(alignment: .top, spacing: 14) {
                                    VStack(spacing: 8) {
                                        nutritionStepperRow(title: "kcal", value: $draft.calories, step: 10, color: .orange)
                                        nutritionStepperRow(title: "Carbs", value: $draft.carbs, step: 1, color: .blue)
                                        nutritionStepperRow(title: "Protein", value: $draft.protein, step: 1, color: .green)
                                        nutritionStepperRow(title: "Fat", value: $draft.fat, step: 1, color: .pink)
                                        nutritionStepperRow(title: "Sodium", value: $draft.sodium, step: 10, color: .purple)
                                    }
                                    .frame(maxWidth: .infinity)

                                    MealPlanNutritionWheel(
                                        protein: Double(draft.protein),
                                        carbs: Double(draft.carbs),
                                        fat: Double(draft.fat)
                                    )
                                    .frame(width: 114, height: 114)
                                }
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            editableRowsSection(
                                title: "Ingredients",
                                subtitle: "Add measured ingredients one by one.",
                                rows: $draft.ingredients,
                                placeholder: "1 cup diced onions"
                            )

                            editableRowsSection(
                                title: "Steps",
                                subtitle: "Build the process step by step.",
                                rows: $draft.steps,
                                placeholder: "Heat oil in a pan over medium heat."
                            )

                            Toggle(isOn: $draft.autoPolishWithAI) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("AI polish before save")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                    Text("ChefBuddy checks quantities and fills missing transitions.")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        Button(action: save) {
                            HStack(spacing: 8) {
                                if isSaving {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                Text(isSaving ? "Saving..." : "Save + Add to \(day)")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSave || isSaving)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Custom Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            draft.mealType = defaultMealType
        }
        .onChange(of: selectedPhotoItem) { _ in
            Task { await loadSelectedPhoto() }
        }
    }

    private func filterMetricCard<Control: View>(
        icon: String,
        label: String,
        value: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: 22, height: 22)
                .background(Color.orange.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }

            Spacer(minLength: 4)

            control()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func nutritionStepperRow(
        title: String,
        value: Binding<Int>,
        step: Int,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Stepper(value: value, in: 0...3000, step: step) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        Task {
            var finalDraft = draft
            if draft.autoPolishWithAI {
                finalDraft = await polishDraftWithAI(draft)
            }
            await MainActor.run {
                onSave(finalDraft)
                isSaving = false
                dismiss()
            }
        }
    }

    private func fillWithAI() {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isAIFilling else { return }
        isAIFilling = true
        Task {
            do {
                let prompt = """
                Generate a full recipe draft from this title and optional image.
                Return ONLY JSON:
                {
                  "emoji": "🍲",
                  "description": "short description",
                  "prepMinutes": 25,
                  "servingsCount": 2,
                  "difficulty": "Easy|Medium|Hard",
                  "tagsText": "Indian, High Protein",
                  "calories": 420,
                  "carbs": 40,
                  "protein": 25,
                  "fat": 15,
                  "sodium": 520,
                  "ingredients": ["1 cup ...", "..."],
                  "steps": ["Step 1...", "Step 2..."]
                }
                Title: \(title)
                """
                let raw: String
                if let selectedPhotoImage {
                    raw = try await assistant.getLiveHelp(image: selectedPhotoImage, question: prompt)
                } else {
                    raw = try await assistant.getHelp(question: prompt)
                }

                guard let json = extractJSONObject(from: raw),
                      let data = json.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    await MainActor.run { isAIFilling = false }
                    return
                }

                await MainActor.run {
                    draft.emoji = (object["emoji"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? draft.emoji
                    draft.description = (object["description"] as? String) ?? draft.description
                    draft.prepMinutes = max(5, object["prepMinutes"] as? Int ?? draft.prepMinutes)
                    draft.servingsCount = max(1, object["servingsCount"] as? Int ?? draft.servingsCount)
                    draft.difficulty = (object["difficulty"] as? String) ?? draft.difficulty
                    draft.tagsText = (object["tagsText"] as? String) ?? draft.tagsText
                    draft.calories = max(0, object["calories"] as? Int ?? draft.calories)
                    draft.carbs = max(0, object["carbs"] as? Int ?? draft.carbs)
                    draft.protein = max(0, object["protein"] as? Int ?? draft.protein)
                    draft.fat = max(0, object["fat"] as? Int ?? draft.fat)
                    draft.sodium = max(0, object["sodium"] as? Int ?? draft.sodium)
                    if let ingredients = object["ingredients"] as? [String], !ingredients.isEmpty {
                        draft.ingredients = ingredients
                    }
                    if let steps = object["steps"] as? [String], !steps.isEmpty {
                        draft.steps = steps
                    }
                    if draft.ingredients.isEmpty { draft.ingredients = [""] }
                    if draft.steps.isEmpty { draft.steps = [""] }
                    isAIFilling = false
                }
            } catch {
                await MainActor.run {
                    isAIFilling = false
                }
            }
        }
    }

    private func polishDraftWithAI(_ source: CustomMealRecipeDraft) async -> CustomMealRecipeDraft {
        do {
            let prompt = """
            Polish this recipe so ingredients are properly quantified and steps are complete.
            Return ONLY JSON:
            {
              "description": "...",
              "ingredients": ["..."],
              "steps": ["..."]
            }
            Title: \(source.title)
            Ingredients: \(source.ingredients.joined(separator: " | "))
            Steps: \(source.steps.joined(separator: " | "))
            """
            let raw = try await assistant.getHelp(question: prompt)
            guard let json = extractJSONObject(from: raw),
                  let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return source
            }

            var updated = source
            if let description = object["description"] as? String, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.description = description
            }
            if let ingredients = object["ingredients"] as? [String], !ingredients.isEmpty {
                updated.ingredients = ingredients
            }
            if let steps = object["steps"] as? [String], !steps.isEmpty {
                updated.steps = steps
            }
            return updated
        } catch {
            return source
        }
    }

    private func editableRowsSection(
        title: String,
        subtitle: String,
        rows: Binding<[String]>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    rows.wrappedValue.append("")
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(rows.wrappedValue.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 8) {
                    TextField(placeholder, text: Binding(
                        get: { rows.wrappedValue[index] },
                        set: { rows.wrappedValue[index] = $0 }
                    ))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        guard rows.wrappedValue.count > 1 else { return }
                        rows.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(rows.wrappedValue.count > 1 ? .red : .secondary.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func extractJSONObject(from text: String) -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("{"), source.hasSuffix("}") {
            return source
        }
        guard let start = source.firstIndex(of: "{"),
              let end = source.lastIndex(of: "}") else {
            return nil
        }
        return String(source[start...end])
    }

    private func loadSelectedPhoto() async {
        guard let selectedPhotoItem else { return }
        do {
            guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                selectedPhotoImage = image
            }
        } catch {
            print("Failed to load custom recipe photo: \(error.localizedDescription)")
        }
    }
}
