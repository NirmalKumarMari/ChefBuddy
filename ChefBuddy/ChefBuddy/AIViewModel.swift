// AIViewModel.swift
// Defines CookingAssistant — the central AI brain of ChefBuddy.
// Owns the Gemini model instance and exposes every AI operation the app uses:
// recipe suggestions, pantry scanning, live cooking help, and fridge image analysis.
// All AI calls go through this single class so model setup and error handling stay in one place.

import Combine
import FirebaseFirestore
import FirebaseAILogic
import SwiftUI
import UIKit

struct PantryScanSession: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case completed
        case emptyResult
        case failed(String)
    }

    let id: UUID
    let pantryId: String
    let pantryName: String
    let mode: PantryScanMode
    var state: State
    var scannedCategories: [String: [String]]
    var didApplyResult: Bool
}

// A single AI-generated recipe card shown in the suggestion carousel.
// Identifiable so SwiftUI lists can diff them; Equatable so we can deduplicate.
struct RecipeSuggestion: Identifiable, Codable, Equatable {
    let id = UUID()
    let title: String
    let emoji: String
    let description: String
    let prepTime: String
    let servings: String
    let difficulty: String
    let calories: String
    let carbs: String
    let protein: String
    let fat: String
    let saturatedFat: String
    let sugar: String
    let fiber: String
    let sodium: String
    let tags: [String]
    let ingredients: [String]
    let steps: [String]
    let matchReason: String

    // Explicit keys let us rename Swift properties without breaking the JSON contract.
enum CodingKeys: String, CodingKey {
        case title
        case emoji
        case description
        case prepTime
        case servings
        case difficulty
        case calories
        case carbs
        case protein
        case fat
        case saturatedFat
        case sugar
        case fiber
        case sodium
        case tags
        case ingredients
        case steps
        case matchReason
    }

    init(
        title: String,
        emoji: String,
        description: String,
        prepTime: String,
        servings: String,
        difficulty: String,
        calories: String,
        carbs: String,
        protein: String,
        fat: String,
        saturatedFat: String,
        sugar: String,
        fiber: String,
        sodium: String,
        tags: [String],
        ingredients: [String],
        steps: [String],
        matchReason: String
    ) {
        self.title = title
        self.emoji = emoji
        self.description = description
        self.prepTime = prepTime
        self.servings = servings
        self.difficulty = difficulty
        self.calories = calories
        self.carbs = carbs
        self.protein = protein
        self.fat = fat
        self.saturatedFat = saturatedFat
        self.sugar = sugar
        self.fiber = fiber
        self.sodium = sodium
        self.tags = tags
        self.ingredients = ingredients
        self.steps = steps
        self.matchReason = matchReason
    }

    // Custom decoder because the AI sometimes returns numbers or booleans instead
    // of strings. decodeFlexibleString handles all those edge cases gracefully.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.title = container.decodeFlexibleString(forKey: .title)
        self.emoji = container.decodeFlexibleString(forKey: .emoji, defaultValue: "🍽️")
        self.description = container.decodeFlexibleString(forKey: .description)
        self.prepTime = container.decodeFlexibleString(forKey: .prepTime, defaultValue: "20 mins")
        self.servings = container.decodeFlexibleString(forKey: .servings, defaultValue: "1 person")
        self.difficulty = container.decodeFlexibleString(forKey: .difficulty, defaultValue: "Intermediate")
        self.calories = container.decodeFlexibleString(forKey: .calories, defaultValue: "0 kcal")
        self.carbs = container.decodeFlexibleString(forKey: .carbs, defaultValue: "0g")
        self.protein = container.decodeFlexibleString(forKey: .protein, defaultValue: "0g")
        self.fat = container.decodeFlexibleString(forKey: .fat, defaultValue: "0g")
        self.saturatedFat = container.decodeFlexibleString(forKey: .saturatedFat, defaultValue: "0g")
        self.sugar = container.decodeFlexibleString(forKey: .sugar, defaultValue: "0g")
        self.fiber = container.decodeFlexibleString(forKey: .fiber, defaultValue: "0g")
        self.sodium = container.decodeFlexibleString(forKey: .sodium, defaultValue: "0mg")
        let parsedTags = container.decodeFlexibleStringArray(forKey: .tags)
        self.tags = parsedTags.isEmpty ? ["Fusion"] : parsedTags
        self.ingredients = container.decodeFlexibleStringArray(forKey: .ingredients)
        self.steps = container.decodeFlexibleStringArray(forKey: .steps)
        self.matchReason = container.decodeFlexibleString(forKey: .matchReason)
    }

    // Convenience computed property so callers get a NutritionInfo without
    // having to manually assemble it from the individual macro fields.
    var nutrition: NutritionInfo {
        NutritionInfo(
            calories: calories,
            carbs: carbs,
            protein: protein,
            fat: fat,
            saturatedFat: saturatedFat,
            sugar: sugar,
            fiber: fiber,
            sodium: sodium
        )
    }

    func asRecipe(createdAt: Date = Date()) -> Recipe {
        Recipe(
            title: title.isEmpty ? "ChefBuddy Recipe" : title,
            emoji: emoji.isEmpty ? "🍽️" : emoji,
            description: description,
            ingredients: ingredients,
            steps: steps,
            cookTime: prepTime,
            servings: servings,
            difficulty: difficulty,
            tags: tags.isEmpty ? [detectedCuisineTag(title: title, description: description, tags: tags)] : tags,
            calories: calories,
            nutrition: nutrition,
            createdAt: createdAt
        )
    }
}

// Extension that makes JSON decoding resilient to the AI returning numbers,
// booleans, or nested dicts where strings are expected. Without this the app
// would crash whenever Gemini slightly deviates from the requested format.
private extension KeyedDecodingContainer {
    // Tries String first, then falls back to Int, Double, Bool, and dict lookups.
    // Returns defaultValue if nothing works so the recipe still renders.
    func decodeFlexibleString(forKey key: K, defaultValue: String = "") -> String {
        if let value = try? decode(String.self, forKey: key) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let intValue = try? decode(Int.self, forKey: key) {
            return String(intValue)
        }

        if let doubleValue = try? decode(Double.self, forKey: key) {
            if doubleValue.rounded() == doubleValue {
                return String(Int(doubleValue))
            }
            return String(doubleValue)
        }

        if let boolValue = try? decode(Bool.self, forKey: key) {
            return boolValue ? "true" : "false"
        }

        if let dictValue = try? decode([String: String].self, forKey: key) {
            let preferredKeys = ["text", "value", "name", "title", "label", "description"]
            for preferredKey in preferredKeys {
                if let value = dictValue[preferredKey], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if let firstNonEmpty = dictValue.values.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return firstNonEmpty.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return defaultValue
    }

    // Handles arrays that may arrive as comma-separated strings or as arrays
    // of dicts (Gemini occasionally wraps items in {"text": "..."} objects).
    func decodeFlexibleStringArray(forKey key: K) -> [String] {
        if let value = try? decode([String].self, forKey: key) {
            return value
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        if let value = try? decode(String.self, forKey: key) {
            let split = value
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if !split.isEmpty {
                return split
            }

            let single = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return single.isEmpty ? [] : [single]
        }

        if let value = try? decode([[String: String]].self, forKey: key) {
            return value.compactMap { dictionary in
                let preferredKeys = ["text", "value", "name", "title", "ingredient", "step", "description", "item"]
                for preferredKey in preferredKeys {
                    if let found = dictionary[preferredKey] {
                        let trimmed = found.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            return trimmed
                        }
                    }
                }

                if let firstNonEmpty = dictionary.values.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    return firstNonEmpty.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                return nil
            }
        }

        if let value = try? decode([[String: AnyDecodable]].self, forKey: key) {
            return value.compactMap { dictionary in
                let preferredKeys = ["text", "value", "name", "title", "ingredient", "step", "description", "item"]
                for preferredKey in preferredKeys {
                    if let found = dictionary[preferredKey]?.stringValue {
                        let trimmed = found.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            return trimmed
                        }
                    }
                }

                if let firstNonEmpty = dictionary.values.compactMap({ $0.stringValue }).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    return firstNonEmpty.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                return nil
            }
        }

        return []
    }
}

// Type-erased Decodable used when we need to peek inside heterogeneous JSON
// arrays or dicts before committing to a concrete Swift type.
struct AnyDecodable: Decodable {
    let value: Any

    var stringValue: String? {
        switch value {
        case let string as String:
            return string
        case let int as Int:
            return String(int)
        case let double as Double:
            if double.rounded() == double {
                return String(Int(double))
            }
            return String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        default:
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            self.value = string
            return
        }

        if let int = try? container.decode(Int.self) {
            self.value = int
            return
        }

        if let double = try? container.decode(Double.self) {
            self.value = double
            return
        }

        if let bool = try? container.decode(Bool.self) {
            self.value = bool
            return
        }

        if let dictionary = try? container.decode([String: String].self) {
            self.value = dictionary
            return
        }

        if let array = try? container.decode([String].self) {
            self.value = array
            return
        }

        self.value = ""
    }
}

// Typed errors so the UI can show useful messages instead of raw system errors.
enum CookingAssistantError: LocalizedError {
    case modelNotReady
    case imageProcessingFailed
    case invalidRecipeResponse

    var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "ChefBuddy is still loading. Please wait a moment and try again."
        case .imageProcessingFailed:
            return "Couldn't process the image. Please try again."
        case .invalidRecipeResponse:
            return "ChefBuddy generated an incomplete recipe. Please try again."
        }
    }
}

enum ChefBuddyAIErrorKind: Equatable {
    case offline
    case timeout
    case busy
    case incompleteResponse
    case blockedRequest
    case temporary
}

struct ChefBuddyAIErrorPresentation: Equatable {
    let kind: ChefBuddyAIErrorKind
    let message: String
    let retryGuidance: String
    let isTransient: Bool
}

func chefBuddyAIErrorPresentation(for error: Error) -> ChefBuddyAIErrorPresentation {
    if let assistantError = error as? CookingAssistantError {
        switch assistantError {
        case .modelNotReady:
            return ChefBuddyAIErrorPresentation(
                kind: .busy,
                message: "ChefBuddy is still warming up.",
                retryGuidance: "Give it a moment and try the same request again.",
                isTransient: true
            )
        case .invalidRecipeResponse:
            return ChefBuddyAIErrorPresentation(
                kind: .incompleteResponse,
                message: "ChefBuddy’s recipe came back incomplete.",
                retryGuidance: "Your request is saved. Try again and ChefBuddy will rebuild it.",
                isTransient: true
            )
        case .imageProcessingFailed:
            return ChefBuddyAIErrorPresentation(
                kind: .incompleteResponse,
                message: "ChefBuddy couldn’t read that photo clearly.",
                retryGuidance: "Try a brighter photo or add a title before trying again.",
                isTransient: false
            )
        }
    }

    let nsError = error as NSError
    let searchable = [
        nsError.domain,
        nsError.localizedDescription,
        String(describing: error)
    ]
    .joined(separator: " ")
    .lowercased()

    if nsError.domain == NSURLErrorDomain,
       [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(nsError.code)
        || searchable.contains("offline")
        || searchable.contains("network connection")
        || searchable.contains("not connected to the internet") {
        return ChefBuddyAIErrorPresentation(
            kind: .offline,
            message: "ChefBuddy can’t reach the kitchen right now.",
            retryGuidance: "Check your connection. Your request will stay here for another try.",
            isTransient: true
        )
    }

    if nsError.code == NSURLErrorTimedOut
        || searchable.contains("timed out")
        || searchable.contains("timeout")
        || searchable.contains("deadline exceeded") {
        return ChefBuddyAIErrorPresentation(
            kind: .timeout,
            message: "That recipe is taking longer than usual.",
            retryGuidance: "Your request is saved. Try again in a moment.",
            isTransient: true
        )
    }

    if searchable.contains("rate limit")
        || searchable.contains("resource exhausted")
        || searchable.contains("too many requests")
        || searchable.contains("429")
        || searchable.contains("unavailable")
        || searchable.contains("overloaded") {
        return ChefBuddyAIErrorPresentation(
            kind: .busy,
            message: "ChefBuddy’s kitchen is extra busy.",
            retryGuidance: "Wait a few seconds, then try the same request again.",
            isTransient: true
        )
    }

    if searchable.contains("blocked")
        || searchable.contains("safety")
        || searchable.contains("prohibited")
        || searchable.contains("finish reason") {
        return ChefBuddyAIErrorPresentation(
            kind: .blockedRequest,
            message: "ChefBuddy couldn’t complete that request.",
            retryGuidance: "Try describing the meal in a different way.",
            isTransient: false
        )
    }

    if searchable.contains("decode")
        || searchable.contains("invalid response")
        || searchable.contains("incomplete")
        || searchable.contains("json") {
        return ChefBuddyAIErrorPresentation(
            kind: .incompleteResponse,
            message: "ChefBuddy’s recipe came back incomplete.",
            retryGuidance: "Your request is saved. Try again and ChefBuddy will rebuild it.",
            isTransient: true
        )
    }

    return ChefBuddyAIErrorPresentation(
        kind: .temporary,
        message: "ChefBuddy couldn’t finish that recipe.",
        retryGuidance: "Nothing was lost. Try the same request again in a moment.",
        isTransient: true
    )
}

func retryingTransientChefBuddyAI<T>(
    delayNanoseconds: UInt64 = 800_000_000,
    operation: () async throws -> T
) async throws -> T {
    do {
        return try await operation()
    } catch {
        guard chefBuddyAIErrorPresentation(for: error).isTransient else {
            throw error
        }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try await operation()
    }
}

// The AI model wrapper. One instance lives in HomeView and is passed down
// so all child views share the same warmed-up model — avoids re-initialising
// Gemini every time a sheet opens.
class CookingAssistant: ObservableObject {
    private let db = Firestore.firestore()

    @Published var model: GenerativeModel?
    @Published var isModelReady = false
    @Published var suggestions: [RecipeSuggestion] = []
    @Published var pantryScanSession: PantryScanSession?

    private var pantryScanTask: Task<Void, Never>?

    private func beginBackgroundTask(named name: String) async -> UIBackgroundTaskIdentifier {
        await MainActor.run {
            var taskId: UIBackgroundTaskIdentifier = .invalid
            taskId = UIApplication.shared.beginBackgroundTask(withName: name) {
                UIApplication.shared.endBackgroundTask(taskId)
            }
            return taskId
        }
    }

    private func endBackgroundTask(_ taskId: UIBackgroundTaskIdentifier) async {
        await MainActor.run {
            guard taskId != .invalid else { return }
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }

    private func runWithBackgroundAllowance<T>(
        name: String,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let taskId = await beginBackgroundTask(named: name)
        defer {
            Task {
                await endBackgroundTask(taskId)
            }
        }
        return try await operation()
    }

    // Polls isModelReady up to 10 seconds so callers can safely await the model
    // without hardcoding delays or risking a crash on a cold launch.
    func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(10)

        while !isModelReady {
            if Date() > deadline {
                throw CookingAssistantError.modelNotReady
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // Strips markdown fences and locates the first [...] block in the response.
    // Gemini sometimes wraps JSON in ```json blocks even when instructed not to.
    private func cleanJSONArrayString(from rawText: String?) -> String? {
        guard var jsonString = rawText else { return nil }

        jsonString = jsonString
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = jsonString.firstIndex(of: "[") {
            jsonString = String(jsonString[start...])
        }

        if let end = jsonString.lastIndex(of: "]") {
            jsonString = String(jsonString[...end])
        }

        return jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Same as cleanJSONArrayString but for single-object responses.
    private func cleanJSONObjectString(from rawText: String?) -> String? {
        guard var jsonString = rawText else { return nil }

        jsonString = jsonString
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = jsonString.firstIndex(of: "{") {
            jsonString = String(jsonString[start...])
        }

        if let end = jsonString.lastIndex(of: "}") {
            jsonString = String(jsonString[...end])
        }

        return jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractJSONObject(from rawText: String?) -> String? {
        guard var jsonString = rawText else { return nil }

        jsonString = jsonString
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = jsonString.firstIndex(of: "{") {
            jsonString = String(jsonString[start...])
        }

        if let end = jsonString.lastIndex(of: "}") {
            jsonString = String(jsonString[...end])
        }

        return jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractJSONArray(from rawText: String?) -> String? {
        guard var jsonString = rawText else { return nil }

        jsonString = jsonString
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = jsonString.firstIndex(of: "[") {
            jsonString = String(jsonString[start...])
        }

        if let end = jsonString.lastIndex(of: "]") {
            jsonString = String(jsonString[...end])
        }

        return jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedSuggestion(from suggestion: RecipeSuggestion, fallbackText rawText: String) -> RecipeSuggestion {
        let fallbackRecipe = RecipesViewModel.parseRecipe(from: rawText)

        let normalizedIngredients = (suggestion.ingredients.isEmpty ? fallbackRecipe.ingredients : suggestion.ingredients)
            .map(Self.cleanListItem)
            .filter { !$0.isEmpty }

        let normalizedSteps = (suggestion.steps.isEmpty ? fallbackRecipe.steps : suggestion.steps)
            .map(Self.cleanInstructionStep)
            .filter { !$0.isEmpty }

        let normalizedTags = (suggestion.tags.isEmpty ? fallbackRecipe.tags : suggestion.tags)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackRecipe.title
            : suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)

        return RecipeSuggestion(
            title: title.isEmpty ? "ChefBuddy Recipe" : title,
            emoji: suggestion.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.emoji : suggestion.emoji,
            description: suggestion.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.description : suggestion.description,
            prepTime: suggestion.prepTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.cookTime : suggestion.prepTime,
            servings: suggestion.servings.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.servings : suggestion.servings,
            difficulty: suggestion.difficulty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.difficulty : suggestion.difficulty,
            calories: suggestion.calories.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.calories : suggestion.calories,
            carbs: suggestion.carbs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.nutrition.carbs : suggestion.carbs,
            protein: suggestion.protein.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.nutrition.protein : suggestion.protein,
            fat: suggestion.fat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.nutrition.fat : suggestion.fat,
            saturatedFat: suggestion.saturatedFat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.nutrition.saturatedFat : suggestion.saturatedFat,
            sugar: suggestion.sugar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.nutrition.sugar : suggestion.sugar,
            fiber: suggestion.fiber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.nutrition.fiber : suggestion.fiber,
            sodium: suggestion.sodium.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackRecipe.nutrition.sodium : suggestion.sodium,
            tags: normalizedTags.isEmpty ? [detectedCuisineTag(title: title, description: suggestion.description, tags: fallbackRecipe.tags)] : normalizedTags,
            ingredients: normalizedIngredients,
            steps: normalizedSteps,
            matchReason: suggestion.matchReason.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func cleanListItem(_ item: String) -> String {
        item
            .replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\d+[\.\)]\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanInstructionStep(_ item: String) -> String {
        item
            .replacingOccurrences(of: #"^\d+[\.\)]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeSuggestionArray(from rawText: String?) throws -> [RecipeSuggestion] {
        guard let jsonString = cleanJSONArrayString(from: rawText),
              let data = jsonString.data(using: .utf8) else {
            throw CookingAssistantError.invalidRecipeResponse
        }

        let decoded = try JSONDecoder().decode([RecipeSuggestion].self, from: data)
        let normalized = decoded.map { normalizedSuggestion(from: $0, fallbackText: rawText ?? "") }
        guard !normalized.isEmpty,
              normalized.allSatisfy({ !$0.ingredients.isEmpty && !$0.steps.isEmpty }) else {
            throw CookingAssistantError.invalidRecipeResponse
        }
        return normalized
    }

    private func decodeSuggestionObject(from rawText: String?) throws -> RecipeSuggestion {
        guard let jsonString = cleanJSONObjectString(from: rawText),
              let data = jsonString.data(using: .utf8) else {
            throw CookingAssistantError.invalidRecipeResponse
        }

        let decoded = try JSONDecoder().decode(RecipeSuggestion.self, from: data)
        let normalized = normalizedSuggestion(from: decoded, fallbackText: rawText ?? "")
        guard !normalized.ingredients.isEmpty, !normalized.steps.isEmpty else {
            throw CookingAssistantError.invalidRecipeResponse
        }
        return normalized
    }

    func generateRecipe(from request: String) async throws -> Recipe {
        try await waitUntilReady()
        guard let model else {
            throw CookingAssistantError.modelNotReady
        }

        let prompt = """
        Create exactly 1 complete recipe for this request:
        \(request)

        Return ONLY valid JSON as a single object in this exact shape:
        {
          "title": "Recipe name",
          "emoji": "🍝",
          "description": "One vivid sentence describing the dish.",
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
          "tags": ["Italian", "High Protein", "Weeknight"],
          "ingredients": ["1 tbsp olive oil", "200g chicken breast"],
          "steps": ["Pat the chicken dry and season both sides with salt and pepper before heating the pan.", "Cook over medium heat for 4 to 5 minutes per side until the center reaches 165F and the outside is deeply golden."],
          "matchReason": "Why this recipe fits the request."
        }

        Rules:
        - Output JSON only. No markdown, prose, code fences, or bullet lists outside the JSON.
        - ingredients must be an array of plain strings with concrete amounts and units.
        - steps must be an array of plain strings only.
        - Provide 5 to 8 detailed steps that a beginner could follow.
        - Include prep, heat level, timing ranges, texture cues, and doneness/safety cues where relevant.
        - Keep the recipe coherent, realistic, and fully cookable as written.
        - Include at least one cuisine tag in tags.
        - Use a single relevant food emoji.
        """

        let response = try await runWithBackgroundAllowance(name: "chefbuddy.generate.recipe") {
            try await model.generateContent(prompt)
        }

        let suggestion = try decodeSuggestionObject(from: response.text)
        return suggestion.asRecipe()
    }

    func generateSinglePantryRecipe(ingredients: [String], excludingTitles: [String]) async throws -> RecipeSuggestion {
        try await waitUntilReady()
        guard let model else {
            throw CookingAssistantError.modelNotReady
        }

        let cleanIngredients = ingredients.map { item -> String in
            let parts = item.split(separator: " ", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : item
        }

        let excludedTitles = excludingTitles.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let prompt = """
        Create exactly 1 fully detailed recipe using ONLY the following ingredients from my pantry:
        \(cleanIngredients.joined(separator: ", "))

        You may also use basic kitchen staples only: salt, pepper, olive oil, neutral oil, butter, and water.
        STRICTLY respect the dietary preferences, allergies, and restrictions in your system instructions.

        Existing recipe titles that must not be repeated:
        \(excludedTitles.isEmpty ? "None" : excludedTitles.joined(separator: ", "))

        Return ONLY valid JSON as a single object in this exact shape:
        {
          "title": "Recipe name",
          "emoji": "🥗",
          "description": "Short enticing description",
          "prepTime": "20 mins",
          "servings": "2 people",
          "difficulty": "Easy",
          "calories": "350 kcal",
          "carbs": "42g",
          "protein": "35g",
          "fat": "12g",
          "saturatedFat": "4g",
          "sugar": "8g",
          "fiber": "5g",
          "sodium": "620mg",
          "tags": ["Mediterranean", "Quick"],
          "ingredients": ["1 tbsp olive oil", "2 cups spinach"],
          "steps": ["Wash and dry the spinach thoroughly before starting.", "Cook until ..."],
          "matchReason": "Why this pantry recipe works."
        }

        Rules:
        - Output JSON only with no markdown or code fences.
        - ingredients and steps must be arrays of plain strings only.
        - ingredients must include exact quantities and units.
        - steps must be detailed, beginner-friendly, and include prep, timing, and doneness cues.
        - title must be clearly different from every excluded title.
        - include at least one cuisine tag in tags.
        """

        let response = try await runWithBackgroundAllowance(name: "chefbuddy.generate.pantry.recipe") {
            try await model.generateContent(prompt)
        }

        return try decodeSuggestionObject(from: response.text)
    }

    func generateRecipeSuggestions(
        personalizationSummary: String = "",
        count: Int = 5,
        excludingTitles: [String] = []
    ) async throws -> [RecipeSuggestion] {
        try await waitUntilReady()
        guard let model = model else {
            throw CookingAssistantError.modelNotReady
        }

        let cleanedTitles = excludingTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let feedbackSection = personalizationSummary.isEmpty ? "" : """


        Important — personalise based on this user behavior summary:
        \(personalizationSummary)
        Use this to tune the deck toward what they save and cook, what they skip, and how adventurous they seem.
        """

        let exclusionSection = cleanedTitles.isEmpty ? "" : """


        Existing titles already in the deck or saved library:
        \(cleanedTitles.joined(separator: ", "))
        Avoid generating titles that match or feel too similar to these.
        """

        let prompt = """
        Generate exactly \(count) fully detailed recipe suggestions based on my profile.\(feedbackSection)\(exclusionSection)

        Return ONLY valid JSON.

        Format exactly like this:

        [
          {
            "title": "Recipe name",
            "emoji": "🍝",
            "description": "Short description",
            "prepTime": "20 mins",
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
            "tags": ["Healthy", "Quick", "High Protein"],
            "ingredients": ["ingredient 1", "ingredient 2", "ingredient 3"],
            "steps": ["step one", "step two", "step three"],
            "matchReason": "Why it fits the user"
          }
        ]

        Rules:
        - Do not include markdown
        - Do not include backticks
        - Do not include explanations
        - tags must be a JSON array of strings and must include at least one cuisine tag
        - ingredients must be a JSON array of strings
        - steps must be a JSON array of strings
        - never return dictionaries inside ingredients or steps
        - ingredients must include concrete quantities and units
        - each recipe must have 5 to 8 steps
        - steps must be detailed and precise, including prep steps (wash/chop/preheat where relevant)
        - steps must include heat level, timing, texture cues, and doneness cues where relevant
        - descriptions should make the dishes sound distinct from each other
        - emoji must be a single relevant food emoji
        - make all \(count) recipe titles different from each other
        - do not make the entire set all one cuisine even if the user often cooks one cuisine
        - if one cuisine seems dominant in the behavior summary, include at most 2 suggestions from that cuisine
        - at least 2 suggestions should feel like tasteful exploration outside their most repeated recent cuisine while still fitting their timing, calorie style, dietary rules, and budget
        - include at least 1 suggestion from a cuisine they do not often cook, as long as it still feels approachable for their preferences
        - some suggestions should feel comfortably familiar and some should feel save-worthy but slightly new
        """

        let response = try await runWithBackgroundAllowance(name: "chefbuddy.fetch.suggestions") {
            try await model.generateContent(prompt)
        }
        let decoded = try decodeSuggestionArray(from: response.text)
        let normalizedExcluded = Set(cleanedTitles.map { $0.lowercased() })
        var seenTitles: Set<String> = []

        return decoded.filter { suggestion in
            let normalizedTitle = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedExcluded.contains(normalizedTitle) else { return false }
            guard seenTitles.insert(normalizedTitle).inserted else { return false }
            return true
        }
    }

    // Generates a swipe-ready batch of personalised recipe suggestions and
    // stores them in self.suggestions. The personalization summary can include
    // saved/cooked/skip behavior so discovery feels more human and less random.
    func fetchRecipeSuggestions(
        personalizationSummary: String = "",
        count: Int = 5,
        excludingTitles: [String] = [],
        append: Bool = false
    ) async {
        do {
            let generated = try await generateRecipeSuggestions(
                personalizationSummary: personalizationSummary,
                count: count,
                excludingTitles: excludingTitles
            )

            await MainActor.run {
                let filtered = generated.filter { suggestion in
                    let normalizedTitle = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return !self.suggestions.contains(where: {
                        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
                    })
                }

                if append {
                    self.suggestions.append(contentsOf: filtered)
                } else {
                    self.suggestions = filtered
                }
            }
        } catch {
            print("Failed to generate suggestions: \(error)")
        }
    }

    // Appends one new suggestion to the discovery deck without duplicating
    // existing ones. Passing excluded titles and the personalization summary
    // helps the replacement stay relevant while still keeping some variety.
    func fetchOneMoreRecipeSuggestion(excludingTitles: [String], personalizationSummary: String = "") async throws {
        try await waitUntilReady()
        guard let model = model else {
            throw CookingAssistantError.modelNotReady
        }

        let cleanedTitles = excludingTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let excludedTitlesText: String
        if cleanedTitles.isEmpty {
            excludedTitlesText = "None"
        } else {
            excludedTitlesText = cleanedTitles.joined(separator: ", ")
        }

        let feedbackSection = personalizationSummary.isEmpty ? "" : """


        Important — personalise based on this user behavior summary:
        \(personalizationSummary)
        Use this to suggest a recipe they will enjoy more while still mixing in some fresh ideas.
        """

        let prompt = """
        Generate exactly 1 fully detailed recipe suggestion based on my profile.\(feedbackSection)

        The recipe title MUST be different from all of these existing titles:
        \(excludedTitlesText)

        Return ONLY valid JSON as a single object.

        Format exactly like this:

        {
          "title": "Recipe name",
          "emoji": "🍝",
          "description": "Short description",
          "prepTime": "20 mins",
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
          "tags": ["Healthy", "Quick", "High Protein"],
          "ingredients": ["ingredient 1", "ingredient 2", "ingredient 3"],
          "steps": ["step one", "step two", "step three"],
          "matchReason": "Why it fits the user"
        }

        Rules:
        - Do not include markdown
        - Do not include backticks
        - Do not include explanations
        - tags must be a JSON array of strings and must include at least one cuisine tag
        - ingredients must be a JSON array of strings
        - steps must be a JSON array of strings
        - never return dictionaries inside ingredients or steps
        - ingredients must include concrete quantities and units
        - steps must be detailed and precise, including prep steps (wash/chop/preheat where relevant)
        - steps must include timing/doneness cues where relevant
        - emoji must be a single relevant food emoji
        - title must not match or be too similar to any excluded title
        - if the user has one very dominant cuisine pattern, do not keep repeating it every time
        - this replacement should either be a strong fit or a tasteful stretch from their usual pattern, not a duplicate vibe
        """

        let response = try await runWithBackgroundAllowance(name: "chefbuddy.fetch.one.suggestion") {
            try await model.generateContent(prompt)
        }

        let decoded = try decodeSuggestionObject(from: response.text)

        let normalizedExcluded = Set(
            cleanedTitles.map { $0.lowercased() }
        )

        let normalizedNewTitle = decoded.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        await MainActor.run {
            if !normalizedExcluded.contains(normalizedNewTitle) &&
                !self.suggestions.contains(where: {
                    $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedNewTitle
                }) {
                self.suggestions.append(decoded)
            }
        }
    }

    // Generates 3 recipes constrained to the ingredients the user has on hand.
    // Strips emoji prefixes from pantry item strings before sending to the model.
    func generatePantryRecipes(ingredients: [String]) async throws -> [RecipeSuggestion] {
        try await waitUntilReady()
        guard let model else {
            throw CookingAssistantError.modelNotReady
        }

        let cleanIngredients = ingredients.map { item -> String in
            let parts = item.split(separator: " ", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : item
        }

        let ingredientList = cleanIngredients.joined(separator: ", ")

        let prompt = """
        Create 3 fully detailed recipes using ONLY the following ingredients from my pantry:
        \(ingredientList)

        You may add basic kitchen staples (salt, pepper, olive oil, water, butter).
        CRITICAL: You MUST strictly adhere to my dietary preferences, allergies, and restrictions defined in your system instructions.

        Return ONLY valid JSON in this format:

        [
          {
            "title": "Recipe name",
            "emoji": "🥗",
            "description": "Short description",
            "prepTime": "20 mins",
            "servings": "2 people",
            "difficulty": "Easy",
            "calories": "350 kcal",
            "carbs": "42g",
            "protein": "35g",
            "fat": "12g",
            "saturatedFat": "4g",
            "sugar": "8g",
            "fiber": "5g",
            "sodium": "620mg",
            "tags": ["Healthy", "Quick"],
            "ingredients": ["ingredient 1", "ingredient 2"],
            "steps": ["step one", "step two"],
            "matchReason": "Why this recipe works with the ingredients"
          }
        ]

        Rules:
        - Do not include markdown or backticks
        - tags must be an array of strings only and must include at least one cuisine tag
        - ingredients must be an array of strings only
        - steps must be an array of strings only
        - never return objects inside ingredients or steps
        - ingredients must include concrete quantities and units
        - each recipe must have 5 to 8 steps
        - steps must be detailed and precise, including prep steps (wash/chop/preheat where relevant)
        - steps must include heat level, timing, texture cues, and doneness cues where relevant
        - make all 3 recipe titles different from each other
        """

        let response = try await runWithBackgroundAllowance(name: "chefbuddy.generate.pantry") {
            try await model.generateContent(prompt)
        }

        return try decodeSuggestionArray(from: response.text)
    }

    // Fetches the user's full profile from Firestore and builds a system prompt
    // that pins Gemini's persona to their preferences. Called once on HomeView
    // appear — subsequent AI calls inherit the context without re-fetching.
    func setupAssistant(userId: String) async {
        do {
            let snapshot = try await db.collection("users").document(userId).getDocument()
            let data = snapshot.data() ?? [:]

            let level = data["chefLevel"] as? String ?? "Beginner"
            let diets = (data["dietTags"] as? [String])?.joined(separator: ", ") ?? "none"
            let allergies = (data["allergies"] as? [String])?.joined(separator: ", ") ?? "none"
            let appliances = (data["appliances"] as? [String])?.joined(separator: ", ") ?? "basic kitchen tools"
            let macros = (data["macroTags"] as? [String])?.joined(separator: ", ") ?? "balanced"
            let dislikes = data["dislikes"] as? String ?? "none"
            let spice = data["spiceTolerance"] as? String ?? "Medium"
            let cookTime = data["cookTime"] as? String ?? "30 mins"
            let budget = data["budget"] as? String ?? "Standard"
            let servings = data["servingSize"] as? String ?? "1 Person"
            let measurementSystem = data["measurementSystem"] as? String ?? "US cups and ounces"
            let goalPace = data["goalPace"] as? String ?? "Steady"
            let cookingFrequency = data["cookingFrequency"] as? String ?? "3 to 4 days per week"
            let cleanupPreference = data["cleanupPreference"] as? String ?? "Balanced cleanup"
            let leftoverPreference = data["leftoverPreference"] as? String ?? "Enjoy leftovers"
            let aiCoachingStyle = data["aiCoachingStyle"] as? String ?? "Direct and practical"
            let aiCreativity = data["aiCreativity"] as? String ?? "Balanced"

            let systemPrompt = """
            You are ChefBuddy, a friendly and professional sous-chef AI assistant.

            USER PROFILE:
            - Experience Level: \(level)
            - Dietary Preferences: \(diets)
            - STRICT Allergies (NEVER suggest these): \(allergies)
            - Ingredients to Avoid: \(dislikes)
            - Available Kitchen Appliances: \(appliances)
            - Macro Goals: \(macros)
            - Spice Tolerance: \(spice)
            - Preferred Cook Time: \(cookTime)
            - Budget: \(budget)
            - Serving Size: \(servings)
            - Measurement System: \(measurementSystem)
            - Goal Pace: \(goalPace)
            - Cooking Frequency: \(cookingFrequency)
            - Cleanup Preference: \(cleanupPreference)
            - Leftover Preference: \(leftoverPreference)
            - Coaching Style: \(aiCoachingStyle)
            - Recipe Creativity: \(aiCreativity)

            ROLE:
            - Provide real-time, friendly cooking help tailored to the user's \(level) experience.
            - If the user shares an image, identify visible ingredients and suggest recipes accordingly.
            - Always respect allergies strictly — never include them even as optional suggestions.
            - Scale recipes to \(servings) and keep instructions appropriate for a \(level) cook.
            - Use \(measurementSystem) for quantities unless the user asks otherwise.
            - When the user is a beginner and "Measuring Cups & Spoons" is not listed, explain unfamiliar quantities in plain visual terms inside each relevant step (for example, a teaspoon is roughly a small eating spoon). Clearly label these as practical approximations and keep safety-sensitive baking ratios exact.
            - Respect the user's \(cleanupPreference) and \(leftoverPreference) when choosing recipes.
            - Match the \(aiCoachingStyle) coaching style and \(aiCreativity) creativity preference.
            - Keep responses encouraging, practical, and appropriate for their stated coaching style.
            """

            let newModel = FirebaseAI.firebaseAI().generativeModel(
                modelName: "gemini-2.5-flash",
                systemInstruction: ModelContent(
                    role: "system",
                    parts: [TextPart(systemPrompt)]
                )
            )

            await MainActor.run {
                self.model = newModel
                self.isModelReady = true
            }
        } catch {
            print("ChefBuddy setup error: \(error.localizedDescription)")
        }
    }

    // General-purpose text question to the model. Used for typed chat questions
    // in LiveCookingView and for recipe generation prompts in RecipesViewModel.
    func getHelp(question: String) async throws -> String {
        try await waitUntilReady()
        guard let model = model else {
            throw CookingAssistantError.modelNotReady
        }

        let response = try await runWithBackgroundAllowance(name: "chefbuddy.get.help") {
            try await model.generateContent(question)
        }
        return response.text ?? "Hmm, I couldn't come up with anything. Try rephrasing!"
    }

    // Multimodal call — sends both an image frame and a text prompt so Gemini
    // can see what the user is cooking and give step-specific visual guidance.
    func getLiveHelp(image: UIImage, question: String) async throws -> String {
        try await waitUntilReady()
        guard let model = model else {
            throw CookingAssistantError.modelNotReady
        }

        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw CookingAssistantError.imageProcessingFailed
        }

        let imagePart = InlineDataPart(data: imageData, mimeType: "image/jpeg")
        let response = try await runWithBackgroundAllowance(name: "chefbuddy.get.live.help") {
            try await model.generateContent(imagePart, question)
        }
        return response.text ?? "I'm not sure — could you show me the ingredients again?"
    }

    func generateRecipesFromIngredients(_ ingredients: [String]) async {
        do {
            let decoded = try await generatePantryRecipes(ingredients: ingredients)

            await MainActor.run {
                self.suggestions = decoded
            }
        } catch {
            print("Recipe generation failed:", error)
        }
    }

    func startPantryScan(
        images: [UIImage],
        pantryId: String,
        pantryName: String,
        mode: PantryScanMode
    ) {
        guard !images.isEmpty else { return }

        pantryScanTask?.cancel()

        let sessionId = UUID()
        pantryScanSession = PantryScanSession(
            id: sessionId,
            pantryId: pantryId,
            pantryName: pantryName,
            mode: mode,
            state: .running,
            scannedCategories: [:],
            didApplyResult: false
        )

        pantryScanTask = Task {
            do {
                let scannedCategories = try await scanMultipleImages(images: images)
                await MainActor.run {
                    guard self.pantryScanSession?.id == sessionId else { return }
                    self.pantryScanSession?.scannedCategories = scannedCategories
                    self.pantryScanSession?.state = self.hasDetectedPantryIngredients(scannedCategories) ? .completed : .emptyResult
                }
            } catch {
                await MainActor.run {
                    guard self.pantryScanSession?.id == sessionId else { return }
                    self.pantryScanSession?.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func markPantryScanApplied(_ sessionId: UUID) {
        guard pantryScanSession?.id == sessionId else { return }
        pantryScanSession?.didApplyResult = true
    }

    func clearPantryScanIfFinished(for pantryId: String? = nil) {
        guard let session = pantryScanSession else { return }
        if let pantryId, session.pantryId != pantryId {
            return
        }

        switch session.state {
        case .running:
            return
        case .completed where session.didApplyResult:
            pantryScanSession = nil
        case .emptyResult:
            pantryScanSession = nil
        case .failed:
            pantryScanSession = nil
        default:
            return
        }
    }

    private func hasDetectedPantryIngredients(_ categories: [String: [String]]) -> Bool {
        categories.values
            .flatMap { $0 }
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // Accepts one or more fridge/pantry photos and returns a categorised
    // ingredient dictionary. Sending all images in one request reduces latency
    // and gives the model full context of the fridge contents at once.
    func scanMultipleImages(images: [UIImage]) async throws -> [String: [String]] {
        try await waitUntilReady()
        guard let model else {
            throw CookingAssistantError.modelNotReady
        }

        var parts: [any Part] = []

        for image in images {
            if let imageData = image.jpegData(compressionQuality: 0.8) {
                parts.append(InlineDataPart(data: imageData, mimeType: "image/jpeg"))
            }
        }

        guard !parts.isEmpty else {
            throw CookingAssistantError.imageProcessingFailed
        }

        let prompt = """
        Look at these images of a fridge/pantry and identify all the raw food ingredients visible.
        Categorize them into exactly these categories: "Produce", "Protein", "Dairy", "Pantry", "Condiments", and "Other".
        Return ONLY a valid JSON object where keys are the categories and values are arrays of strings.
        Each string MUST start with a single highly relevant emoji, followed by a space, and then the ingredient name in lowercase.
        Do not duplicate ingredients.

        Example:
        {
          "Produce": ["🥬 spinach", "🍅 tomato"],
          "Protein": ["🍗 chicken", "🥚 eggs"],
          "Dairy": ["🥛 milk", "🧀 cheese"],
          "Pantry": ["🍚 rice", "🍝 pasta"],
          "Condiments": ["🥫 ketchup"],
          "Other": ["🧃 juice"]
        }
        """

        parts.append(TextPart(prompt))

        let content = ModelContent(role: "user", parts: parts)
        let response = try await runWithBackgroundAllowance(name: "chefbuddy.scan.pantry") {
            try await model.generateContent([content])
        }

        guard let text = response.text else { return [:] }

        let cleaned = text
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return [:] }
        return try JSONDecoder().decode([String: [String]].self, from: data)
    }
}
