// RecipesView.swift
// The core recipe management screen and its supporting types.
//
// Recipe            — Firestore-backed data model for a saved recipe including
//                     nutrition, cook history, and favourite state.
// NutritionInfo     — Embedded nutrition struct stored inside each Recipe doc.
// RecipesViewModel  — ObservableObject that owns the Firestore listener, drives
//                     AI recipe generation, handles reviews, cooked-state tracking,
//                     nutrition backfill for older recipes, and suggestion loading.
// RecipesView       — The main grid UI: fresh recipes on top, cooked below,
//                     AI suggestion carousel, filter pills, and generate sheet.
// RecipeReviewView  — Post-cook review flow: liked tags, improvement prompt,
//                     optional AI recipe revision, and cooked-count update.
// NutritionBreakdownCard — Reusable macro display used in detail and review views.

import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import Combine
import UIKit
import PhotosUI

private struct CookedDishImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: CookedDishImagePicker

        init(parent: CookedDishImagePicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                parent.dismiss()
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async {
                    if let image = object as? UIImage {
                        self.parent.onPick(image)
                    }
                    self.parent.dismiss()
                }
            }
        }
    }
}

private struct CookedDishPhoto: Identifiable {
    let id: String
    let downloadURL: String
    let storagePath: String
    let createdAt: Date
}

private enum CookedDishGalleryError: LocalizedError {
    case preparation
    case permission
    case upload
    case confirmation

    var errorDescription: String? {
        switch self {
        case .preparation:
            return "ChefBuddy could not prepare that image. Please choose a different photo."
        case .permission:
            return "ChefBuddy does not have permission to save gallery photos yet. Update the Firebase Storage rules for your account and try again."
        case .upload:
            return "The photo could not be uploaded. Check your connection and try again."
        case .confirmation:
            return "The upload did not finish confirming. Please wait a moment and try again."
        }
    }
}

private enum CookedDishGalleryStore {
    static func upload(image: UIImage, userId: String, recipeId: String, recipeTitle: String, recipeEmoji: String) async throws {
        guard let data = preparedImageData(image) else {
            throw CookedDishGalleryError.preparation
        }

        let photoId = UUID().uuidString
        let storagePath = "users/\(userId)/recipes/\(recipeId)/gallery/\(photoId).jpg"
        let reference = Storage.storage().reference(withPath: storagePath)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.putData(data, metadata: metadata) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == StorageErrorDomain,
               nsError.code == StorageErrorCode.unauthorized.rawValue {
                throw CookedDishGalleryError.permission
            }
            throw CookedDishGalleryError.upload
        }

        var confirmedDownloadURL: URL?
        for attempt in 0..<4 {
            do {
                confirmedDownloadURL = try await downloadURL(for: reference)
                break
            } catch {
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 350_000_000)
                }
            }
        }

        guard let downloadURL = confirmedDownloadURL else {
            throw CookedDishGalleryError.confirmation
        }

        let document = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("recipes")
            .document(recipeId)
            .collection("gallery")
            .document(photoId)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.setData([
                "userId": userId,
                "recipeId": recipeId,
                "recipeTitle": recipeTitle,
                "recipeEmoji": recipeEmoji,
                "downloadURL": downloadURL.absoluteString,
                "storagePath": storagePath,
                "createdAt": Date()
            ]) { error in
                if let error {
                    reference.delete(completion: nil)
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func downloadURL(for reference: StorageReference) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            reference.downloadURL { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: CookedDishGalleryError.confirmation)
                }
            }
        }
    }

    private static func preparedImageData(_ image: UIImage) -> Data? {
        let maximumDimension: CGFloat = 1600
        let longestSide = max(image.size.width, image.size.height)
        let scale = longestSide > maximumDimension ? maximumDimension / longestSide : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.78)
    }
}


// Embeds as a sub-document inside each Recipe. Stored separately from the
// top-level calories field so the detail view can show a full macro breakdown.
struct NutritionInfo: Codable, Equatable {
    var calories: String
    var carbs: String
    var protein: String
    var fat: String
    var saturatedFat: String
    var sugar: String
    var fiber: String
    var sodium: String

    // Sentinel value used when a recipe was saved before nutrition backfill ran.
    // Lets the UI safely check if nutrition data exists without optional unwrapping.
    static var empty: NutritionInfo {
        NutritionInfo(calories: "", carbs: "", protein: "", fat: "",
                      saturatedFat: "", sugar: "", fiber: "", sodium: "")
    }
}

// The core data model stored in Firestore at users/{uid}/recipes/{id}.
// @DocumentID auto-populates id from the Firestore doc key so we never
// manually manage the primary key.
struct Recipe: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
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
    var createdAt: Date
    var isFavorite: Bool

    var cookedCount: Int
    var lastCookedAt: Date?

    init(
        title: String,
        emoji: String = "🍽️",
        description: String,
        ingredients: [String],
        steps: [String],
        cookTime: String,
        servings: String,
        difficulty: String,
        tags: [String] = [],
        calories: String = "",
        nutrition: NutritionInfo = .empty,
        createdAt: Date = Date(),
        isFavorite: Bool = false,
        cookedCount: Int = 0,
        lastCookedAt: Date? = nil
    ) {
        self.title = title
        self.emoji = emoji
        self.description = description
        self.ingredients = ingredients
        self.steps = steps
        self.cookTime = cookTime
        self.servings = servings
        self.difficulty = difficulty
        self.tags = tags
        self.calories = calories
        self.nutrition = nutrition
        self.createdAt = createdAt
        self.isFavorite = isFavorite
        self.cookedCount = cookedCount
        self.lastCookedAt = lastCookedAt
    }

    // Computed from cookedCount so the UI never gets out of sync with the
// actual cook history — there's no separate boolean that could drift.
var hasBeenCooked: Bool { cookedCount > 0 }
}

enum GroceryStore: String, CaseIterable, Codable, Identifiable {
    case safeway = "Safeway"
    case walmart = "Walmart"
    case costco = "Costco"
    case traderJoes = "Trader Joe's"
    case amazon = "Amazon"

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .safeway: return "🛒"
        case .walmart: return "🏬"
        case .costco: return "📦"
        case .traderJoes: return "🥕"
        case .amazon: return "📦"
        }
    }

    func searchURL(for product: GroceryStoreProduct) -> URL? {
        let query = [product.brand, product.name]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")

        var components: URLComponents
        switch self {
        case .safeway:
            components = URLComponents(string: "https://www.safeway.com/shop/search-results.html")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .walmart:
            components = URLComponents(string: "https://www.walmart.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .costco:
            components = URLComponents(string: "https://www.costco.com/s")!
            components.queryItems = [URLQueryItem(name: "keyword", value: query)]
        case .traderJoes:
            components = URLComponents(string: "https://www.traderjoes.com/home/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .amazon:
            components = URLComponents(string: "https://www.amazon.com/s")!
            components.queryItems = [URLQueryItem(name: "k", value: query)]
        }
        return components.url
    }
}

struct GroceryStoreProduct: Codable, Equatable, Identifiable {
    var name: String
    var brand: String
    var size: String
    var price: String
    var section: String
    var note: String

    var id: String {
        "\(name)|\(brand)|\(size)|\(price)"
    }
}

struct GroceryListItem: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var ingredientDisplay: String
    var normalizedIngredient: String
    var quantityHint: String
    var recipeId: String?
    var recipeTitle: String
    var recipeEmoji: String
    var isPurchased: Bool
    var createdAt: Date
    var matchesByStore: [String: [GroceryStoreProduct]]
    var matchAttemptedStores: [String: Date]?

    func hasStoreMatchAttempt(for store: GroceryStore) -> Bool {
        if let products = matchesByStore[store.rawValue], products.isEmpty == false {
            return true
        }
        return matchAttemptedStores?[store.rawValue] != nil
    }
}

private let ingredientStopWords: Set<String> = [
    "a", "an", "and", "or", "of", "to", "taste", "for", "with", "from", "optional",
    "cup", "cups", "tbsp", "tsp", "teaspoon", "teaspoons", "tablespoon", "tablespoons",
    "oz", "ounce", "ounces", "g", "kg", "ml", "l", "lb", "lbs", "pound", "pounds",
    "small", "medium", "large", "fresh", "dried", "minced", "diced", "chopped", "sliced",
    "shredded", "grated", "ground", "crushed", "extra", "virgin", "boneless", "skinless",
    "halved", "quartered", "rinsed", "washed", "peeled", "cubed", "thinly", "thickly",
    "pinch", "handful", "dash", "pack", "packet", "can", "cans", "jar", "jars"
]

func normalizedIngredientKey(from raw: String) -> String {
    let lowered = raw.lowercased()
    let stripped = lowered.replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
    let pieces = stripped
        .split(separator: " ")
        .map(String.init)
        .filter { token in
            guard token.count > 1 else { return false }
            guard ingredientStopWords.contains(token) == false else { return false }
            return Int(token) == nil
        }

    if pieces.isEmpty {
        return stripped.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return pieces.prefix(3).joined(separator: " ")
}

func isAlwaysAvailableIngredient(_ raw: String) -> Bool {
    let normalized = normalizedIngredientKey(from: raw)
    guard !normalized.isEmpty else { return true }
    let tokens = Set(normalized.split(separator: " ").map(String.init))
    return normalized == "water" || tokens == ["water"]
}

func quantityHint(from ingredientLine: String) -> String {
    let trimmed = ingredientLine.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = trimmed.split(separator: " ")
    guard !components.isEmpty else { return "" }
    if components.count == 1 { return "" }

    let first = String(components[0]).lowercased()
    let second = String(components[1]).lowercased()
    let looksNumeric = first.range(of: #"^\d+([./]\d+)?$"#, options: .regularExpression) != nil
    let fraction = ["1/2", "1/3", "1/4", "2/3", "3/4", "¼", "½", "¾"].contains(first)
    let unitLike = ["cup", "cups", "tbsp", "tsp", "oz", "g", "kg", "ml", "l", "lb", "lbs", "clove", "cloves", "can", "cans"]
        .contains(second)

    if looksNumeric || fraction {
        return components.prefix(2).joined(separator: " ")
    }
    if unitLike {
        return String(components[0])
    }
    return ""
}

func displayIngredientText(from raw: String) -> String {
    raw
        .replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

let chefBuddyMeasurementSystemDefaultsKey = "chefBuddy.measurementSystem"

func persistChefBuddyMeasurementSystem(_ value: String) {
    UserDefaults.standard.set(value, forKey: chefBuddyMeasurementSystemDefaultsKey)
}

func preferredIngredientText(_ raw: String) -> String {
    let cleaned = displayIngredientText(from: raw)
    let preference = UserDefaults.standard.string(forKey: chefBuddyMeasurementSystemDefaultsKey)
        ?? "🇺🇸 US cups & ounces"
    return convertIngredientMeasurement(in: cleaned, toMetric: preference.localizedCaseInsensitiveContains("metric"))
}

private func convertIngredientMeasurement(in raw: String, toMetric: Bool) -> String {
    let pattern = #"^(\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?|[¼½¾⅓⅔⅛⅜⅝⅞])\s*(cups?|cup|tablespoons?|tbsp|teaspoons?|tsp|ounces?|oz|pounds?|lbs?|grams?|g|kilograms?|kg|millilit(?:er|re)s?|ml|lit(?:er|re)s?|l)\b(.*)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
          match.numberOfRanges == 4,
          let amountRange = Range(match.range(at: 1), in: raw),
          let unitRange = Range(match.range(at: 2), in: raw),
          let suffixRange = Range(match.range(at: 3), in: raw),
          let amount = parsedIngredientAmount(String(raw[amountRange])) else {
        return raw
    }

    let unit = String(raw[unitRange]).lowercased()
    let suffix = String(raw[suffixRange])
    let converted: (Double, String)?

    if toMetric {
        switch unit {
        case "cup", "cups":
            converted = (amount * 240, "ml")
        case "tablespoon", "tablespoons", "tbsp":
            converted = (amount * 15, "ml")
        case "teaspoon", "teaspoons", "tsp":
            converted = (amount * 5, "ml")
        case "ounce", "ounces", "oz":
            converted = (amount * 28.35, "g")
        case "pound", "pounds", "lb", "lbs":
            converted = (amount * 453.6, "g")
        default:
            converted = nil
        }
    } else {
        switch unit {
        case "gram", "grams", "g":
            converted = (amount / 28.35, "oz")
        case "kilogram", "kilograms", "kg":
            converted = (amount * 2.205, "lb")
        case "milliliter", "milliliters", "millilitre", "millilitres", "ml":
            converted = amount >= 60 ? (amount / 240, "cups") : (amount / 15, "tbsp")
        case "liter", "liters", "litre", "litres", "l":
            converted = (amount * 4.227, "cups")
        default:
            converted = nil
        }
    }

    guard var converted else { return raw }
    if toMetric, converted.0 >= 1000, converted.1 == "g" {
        converted = (converted.0 / 1000, "kg")
    } else if toMetric, converted.0 >= 1000, converted.1 == "ml" {
        converted = (converted.0 / 1000, "l")
    }
    let displayUnit = converted.1 == "cups" && abs(converted.0 - 1) < 0.05 ? "cup" : converted.1
    return "\(formattedIngredientAmount(converted.0)) \(displayUnit)\(suffix)"
}

private func parsedIngredientAmount(_ raw: String) -> Double? {
    let fractions: [Character: Double] = [
        "¼": 0.25, "½": 0.5, "¾": 0.75, "⅓": 1.0 / 3.0, "⅔": 2.0 / 3.0,
        "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875
    ]
    if raw.count == 1, let character = raw.first, let value = fractions[character] {
        return value
    }

    let parts = raw.split(separator: " ").map(String.init)
    if parts.count == 2, let whole = Double(parts[0]), let fraction = parsedIngredientAmount(parts[1]) {
        return whole + fraction
    }
    if raw.contains("/") {
        let values = raw.split(separator: "/").compactMap { Double($0) }
        guard values.count == 2, values[1] != 0 else { return nil }
        return values[0] / values[1]
    }
    return Double(raw)
}

private func formattedIngredientAmount(_ value: Double) -> String {
    if abs(value.rounded() - value) < 0.05 {
        return String(Int(value.rounded()))
    }
    if value >= 10 {
        return String(Int(value.rounded()))
    }
    return String(format: "%.1f", value)
        .replacingOccurrences(of: ".0", with: "")
}

struct IngredientDisplayParts: Equatable {
    let quantity: String
    let name: String
}

func ingredientDisplayParts(from raw: String) -> IngredientDisplayParts {
    let cleaned = preferredIngredientText(raw)
    let pieces = cleaned.split(separator: " ").map(String.init)
    guard !pieces.isEmpty else {
        return IngredientDisplayParts(quantity: "", name: "")
    }

    var startIndex = 0
    if let first = pieces.first,
       first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
        startIndex = 1
    }

    let ingredientPieces = Array(pieces.dropFirst(startIndex))
    guard let first = ingredientPieces.first else {
        return IngredientDisplayParts(quantity: "", name: cleaned)
    }

    let numericPattern = #"^(\d+([./]\d+)?|[¼½¾⅓⅔⅛⅜⅝⅞])$"#
    let units: Set<String> = [
        "cup", "cups", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon", "teaspoons",
        "oz", "ounce", "ounces", "g", "kg", "ml", "l", "lb", "lbs", "pound", "pounds",
        "clove", "cloves", "can", "cans", "jar", "jars", "slice", "slices", "piece", "pieces",
        "pinch", "dash", "handful", "bunch", "sprig", "sprigs"
    ]

    var quantityCount = 0
    if first.range(of: numericPattern, options: .regularExpression) != nil {
        quantityCount = 1
        if ingredientPieces.count > 1,
           ingredientPieces[1].range(of: numericPattern, options: .regularExpression) != nil {
            quantityCount = 2
        }
        if ingredientPieces.count > quantityCount,
           units.contains(ingredientPieces[quantityCount].lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            quantityCount += 1
        }
    } else if units.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
        quantityCount = 1
    }

    guard quantityCount > 0, ingredientPieces.count > quantityCount else {
        return IngredientDisplayParts(quantity: "", name: ingredientPieces.joined(separator: " "))
    }

    return IngredientDisplayParts(
        quantity: ingredientPieces.prefix(quantityCount).joined(separator: " "),
        name: ingredientPieces.dropFirst(quantityCount).joined(separator: " ")
    )
}

func ingredientEmoji(for raw: String) -> String {
    let cleaned = displayIngredientText(from: raw)
    if let token = cleaned.split(separator: " ").first,
       token.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
        return String(token)
    }

    let text = normalizedIngredientKey(from: cleaned)
    let matches: [(String, [String])] = [
        ("🍗", ["chicken", "turkey"]),
        ("🥩", ["beef", "steak", "pork", "lamb"]),
        ("🐟", ["salmon", "tuna", "fish", "cod", "shrimp", "prawn"]),
        ("🥚", ["egg"]),
        ("🧀", ["cheese", "parmesan", "mozzarella", "feta"]),
        ("🥛", ["milk", "cream", "yogurt", "buttermilk"]),
        ("🧈", ["butter"]),
        ("🍅", ["tomato"]),
        ("🧅", ["onion", "shallot", "scallion"]),
        ("🧄", ["garlic"]),
        ("🥕", ["carrot"]),
        ("🥦", ["broccoli", "cauliflower"]),
        ("🥬", ["spinach", "lettuce", "kale", "cabbage", "greens"]),
        ("🫑", ["pepper", "chili", "chilli", "jalapeno"]),
        ("🥔", ["potato"]),
        ("🍄", ["mushroom"]),
        ("🥑", ["avocado"]),
        ("🍋", ["lemon", "lime", "citrus"]),
        ("🍎", ["apple"]),
        ("🍌", ["banana"]),
        ("🍓", ["strawberry", "berry", "berries"]),
        ("🍚", ["rice", "quinoa", "couscous"]),
        ("🍝", ["pasta", "spaghetti", "noodle"]),
        ("🍞", ["bread", "flour", "tortilla", "breadcrumb"]),
        ("🫘", ["bean", "lentil", "chickpea"]),
        ("🥜", ["peanut", "almond", "cashew", "walnut", "nut"]),
        ("🌿", ["basil", "cilantro", "parsley", "thyme", "rosemary", "herb"]),
        ("🧂", ["salt", "seasoning", "spice", "paprika", "cumin", "turmeric"]),
        ("🫒", ["olive oil", "oil"]),
        ("🥫", ["sauce", "paste", "ketchup", "mustard", "mayo", "soy"]),
        ("🍯", ["honey", "syrup"]),
        ("💧", ["water", "broth", "stock", "vinegar"])
    ]

    for (emoji, keywords) in matches where keywords.contains(where: { text.contains($0) }) {
        return emoji
    }
    return "🥣"
}

private func ingredientTokenSet(_ raw: String) -> Set<String> {
    let normalized = normalizedIngredientKey(from: raw)
    return Set(normalized.split(separator: " ").map(String.init))
}

func pantryContainsIngredient(_ ingredient: String, pantryIngredients: [String]) -> Bool {
    if isAlwaysAvailableIngredient(ingredient) { return true }
    let key = normalizedIngredientKey(from: ingredient)
    guard !key.isEmpty else { return true }
    let keyTokens = ingredientTokenSet(key)

    for pantryItem in pantryIngredients {
        let pantryKey = normalizedIngredientKey(from: pantryItem)
        guard !pantryKey.isEmpty else { continue }

        if pantryKey == key || pantryKey.contains(key) || key.contains(pantryKey) {
            return true
        }

        let pantryTokens = ingredientTokenSet(pantryKey)
        let overlap = keyTokens.intersection(pantryTokens).count
        if overlap >= 2 || (overlap == 1 && (keyTokens.count == 1 || pantryTokens.count == 1)) {
            return true
        }
    }

    return false
}

func missingIngredients(from ingredients: [String], pantryIngredients: [String]) -> [String] {
    ingredients.filter { pantryContainsIngredient($0, pantryIngredients: pantryIngredients) == false }
}

func sanitizedDocumentId(_ raw: String) -> String {
    let lowered = raw.lowercased()
    let cleaned = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? UUID().uuidString : trimmed
}

func detectedCuisineTag(title: String, description: String, tags: [String]) -> String {
    let knownCuisines = [
        "Italian", "Mexican", "Indian", "Chinese", "Japanese", "Thai",
        "Mediterranean", "Korean", "Vietnamese", "Greek", "American",
        "French", "Spanish", "Middle Eastern"
    ]

    for cuisine in knownCuisines {
        if tags.contains(where: { $0.localizedCaseInsensitiveContains(cuisine) }) {
            return cuisine
        }
    }

    let text = "\(title) \(description)".lowercased()
    let keywordMap: [(String, [String])] = [
        ("Italian", ["pasta", "risotto", "marinara", "alfredo"]),
        ("Mexican", ["taco", "burrito", "enchilada", "salsa"]),
        ("Indian", ["curry", "masala", "paneer", "dal", "tikka"]),
        ("Chinese", ["stir-fry", "fried rice", "noodle", "wok"]),
        ("Japanese", ["teriyaki", "ramen", "miso", "sushi"]),
        ("Thai", ["pad thai", "thai", "lemongrass"]),
        ("Mediterranean", ["mediterranean", "hummus", "tzatziki"]),
        ("Korean", ["kimchi", "gochujang", "bulgogi"]),
        ("Vietnamese", ["pho", "banh mi"]),
        ("Greek", ["gyro", "feta", "greek"]),
        ("Middle Eastern", ["falafel", "shawarma", "tahini"])
    ]

    for (cuisine, keywords) in keywordMap where keywords.contains(where: { text.contains($0) }) {
        return cuisine
    }

    return "Fusion"
}

func primaryCuisineTag(for tags: [String], title: String, description: String) -> String {
    detectedCuisineTag(title: title, description: description, tags: tags)
}

func prepMinutes(from raw: String) -> Int? {
    let lowered = raw.lowercased()
    let numbers = lowered
        .components(separatedBy: CharacterSet.decimalDigits.inverted)
        .compactMap { Int($0) }

    guard let first = numbers.first else { return nil }

    if lowered.contains("hour") || lowered.contains("hr") {
        let minutes = numbers.dropFirst().first ?? 0
        return (first * 60) + minutes
    }

    return first
}

func calorieNumber(from raw: String) -> Int? {
    raw
        .components(separatedBy: CharacterSet.decimalDigits.inverted)
        .compactMap { Int($0) }
        .first
}

func pantryOverlapRatio(ingredients: [String], pantryIngredients: [String]) -> Double {
    guard !ingredients.isEmpty, !pantryIngredients.isEmpty else { return 0 }

    let matches = ingredients.reduce(0) { partial, ingredient in
        partial + (pantryContainsIngredient(ingredient, pantryIngredients: pantryIngredients) ? 1 : 0)
    }

    return Double(matches) / Double(max(ingredients.count, 1))
}

extension CookingAssistant {
    func fetchStoreMatches(
        ingredients: [String],
        store: GroceryStore,
        budgetPreference: String
    ) async throws -> [String: [GroceryStoreProduct]] {
        let uniqueIngredients = Array(Set(ingredients
            .map { normalizedIngredientKey(from: $0) }
            .filter { !$0.isEmpty }))
            .sorted()

        guard !uniqueIngredients.isEmpty else { return [:] }

        let prompt = """
        I need grocery product matches for \(store.rawValue).

        Budget preference: \(budgetPreference)
        Ingredients to match: \(uniqueIngredients.joined(separator: ", "))

        Return ONLY valid JSON in this exact shape:
        {
          "items": [
            {
              "ingredient": "tofu",
              "products": [
                {
                  "name": "Firm Tofu",
                  "brand": "Nasoya",
                  "size": "14 oz",
                  "price": "$2.99",
                  "section": "Produce",
                  "note": "Best value for stir-fry"
                }
              ]
            }
          ]
        }

        Rules:
        - Do not include markdown or backticks
        - 2 to 3 products per ingredient
        - price must be a string like $3.49
        - products must be realistic for \(store.rawValue)
        - prioritize options aligned with the budget preference
        """

        let response = try await getHelp(question: prompt)
        guard let jsonString = Self.extractJSONObject(from: response),
              let data = jsonString.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["items"] as? [[String: Any]] else {
            return [:]
        }

        var output: [String: [GroceryStoreProduct]] = [:]

        for row in rows {
            let ingredient = (row["ingredient"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedIngredientKey(from: ingredient)
            guard !key.isEmpty else { continue }

            let productsRaw = row["products"] as? [[String: Any]] ?? []
            let products: [GroceryStoreProduct] = productsRaw.compactMap { product in
                let name = (product["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return GroceryStoreProduct(
                    name: name,
                    brand: (product["brand"] as? String ?? "Store Brand").trimmingCharacters(in: .whitespacesAndNewlines),
                    size: (product["size"] as? String ?? "Standard").trimmingCharacters(in: .whitespacesAndNewlines),
                    price: (product["price"] as? String ?? "—").trimmingCharacters(in: .whitespacesAndNewlines),
                    section: (product["section"] as? String ?? "Grocery").trimmingCharacters(in: .whitespacesAndNewlines),
                    note: (product["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            if !products.isEmpty {
                output[key] = products
            }
        }

        return output
    }

}


// Central controller for all recipe operations: Firestore CRUD, AI generation,
// suggestion loading, review saving, and nutrition backfill.
// Owned by RecipesView and kept alive as long as that view is on screen.
enum RecipeGenerationState: Equatable {
    case idle
    case generating
    case succeeded
    case failed(String)
}

class RecipesViewModel: ObservableObject {
    @Published var recipes: [Recipe] = []
    @Published var isGenerating = false
    @Published var errorMessage: String? = nil
    @Published var selectedFilter = "All"
    @Published var selectedCuisineFilter = "All Cuisines"
    @Published var justGeneratedRecipe: Recipe? = nil
    @Published var elapsedSeconds: Int = 0
    @Published var generationState: RecipeGenerationState = .idle

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var timerTask: Task<Void, Never>? = nil

    let filters = ["All", "❤️ Saved", "✅ Cooked"]

    var filteredRecipes: [Recipe] {
        let focused: [Recipe]
        switch selectedFilter {
        case "❤️ Saved":
            focused = recipes.filter { $0.isFavorite }
        case "✅ Cooked":
            focused = recipes.filter { $0.hasBeenCooked }
        case "⚡ Quick":
            focused = recipes.filter {
                (prepMinutes(from: $0.cookTime) ?? 999) <= 30
            }
        case "💪 Protein":
            focused = recipes.filter {
                $0.tags.contains(where: { $0.lowercased().contains("protein") })
            }
        case "🥗 Healthy":
            focused = recipes.filter {
                $0.tags.contains(where: {
                    $0.lowercased().contains("healthy") || $0.lowercased().contains("low cal")
                })
            }
        default:
            focused = recipes
        }

        guard selectedCuisineFilter != "All Cuisines" else { return focused }
        return focused.filter {
            detectedCuisineTag(title: $0.title, description: $0.description, tags: $0.tags) == selectedCuisineFilter
        }
    }

    var previewRecipes: [Recipe] {
        Array(filteredRecipes.prefix(4))
    }

    // Opens a real-time Firestore snapshot listener so the recipe grid updates
    // the moment any recipe is added, changed, or deleted — no manual refresh needed.
    func startListening(userId: String) {
        guard !userId.isEmpty else { return }

        listener?.remove()
        listener = db.collection("users")
            .document(userId)
            .collection("recipes")
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { [weak self] snap, _ in
                guard let docs = snap?.documents else { return }

                DispatchQueue.main.async {
                    self?.recipes = docs.compactMap { try? $0.data(as: Recipe.self) }
                }
            }
    }

    // Removes the snapshot listener when the view disappears to avoid holding
    // an open connection and triggering spurious updates in the background.
    func stopListening() {
        listener?.remove()
        listener = nil
    }

    // Generates recipes one-by-one until the user has 3, sequentially.
    // Uses a wait-cycle loop so each generation finishes before the next starts,
    // preventing the race condition where parallel requests duplicate recipes.
    func autoGenerateIfNeeded(assistant: CookingAssistant, userId: String) {
        guard recipes.count < 3, !isGenerating, !userId.isEmpty else { return }

        db.collection("users").document(userId).getDocument { [weak self] snap, _ in
            guard let self = self else { return }

            let data = snap?.data() ?? [:]

            let diets = (data["dietTags"] as? [String])?.joined(separator: ", ") ?? ""
            let allergies = (data["allergies"] as? [String])?.joined(separator: ", ") ?? ""
            let macros = (data["macroTags"] as? [String])?.joined(separator: ", ") ?? ""
            let spice = data["spiceTolerance"] as? String ?? "Medium"
            let cookTime = data["cookTime"] as? String ?? "30 mins"
            let budget = data["budget"] as? String ?? "Standard"
            let servings = data["servingSize"] as? String ?? "1 Person"
            let cuisines = (data["cuisines"] as? [String])?.joined(separator: ", ") ?? ""
            let appliances = (data["appliances"] as? [String])?.joined(separator: ", ") ?? "basic kitchen tools"
            let goal = data["targetGoal"] as? String ?? "Maintain"
            let dislikes = data["dislikes"] as? String ?? ""

            var ctx = ""
            if !diets.isEmpty { ctx += "Diet: \(diets). " }
            if !allergies.isEmpty { ctx += "Allergies to avoid: \(allergies). " }
            if !macros.isEmpty { ctx += "Macro goal: \(macros). " }
            if !cuisines.isEmpty { ctx += "Preferred cuisines: \(cuisines). " }
            if !dislikes.isEmpty { ctx += "Ingredients to avoid: \(dislikes). " }

            ctx += "Spice tolerance: \(spice). Cook time: \(cookTime). Budget: \(budget). Serving size: \(servings). Goal: \(goal). Available appliances: \(appliances)."

            let starterPrompts = [
                "A delicious \(cookTime) dinner that fits these preferences — \(ctx)",
                "A nutritious breakfast or lunch using these preferences — \(ctx)",
                "A crowd-pleasing meal that matches these tastes — \(ctx)"
            ]

            let prompt = starterPrompts[min(self.recipes.count, starterPrompts.count - 1)]

            DispatchQueue.main.async {
                self.generateAndSave(prompt: prompt, assistant: assistant, userId: userId)
            }
        }
    }

    func toggleFavorite(_ recipe: Recipe, userId: String) {
        guard let id = recipe.id, !userId.isEmpty else { return }
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { return }

        let newValue = !recipes[index].isFavorite

        recipes[index].isFavorite = newValue

        db.collection("users")
            .document(userId)
            .collection("recipes")
            .document(id)
            .updateData(["isFavorite": newValue]) { [weak self] error in
                if let error = error {
                    DispatchQueue.main.async {
                        guard let self = self,
                              let rollbackIndex = self.recipes.firstIndex(where: { $0.id == id }) else { return }

                        self.recipes[rollbackIndex].isFavorite.toggle()
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
    }

    func deleteRecipe(_ recipe: Recipe, userId: String) {
        guard let id = recipe.id, !userId.isEmpty else { return }

        db.collection("users")
            .document(userId)
            .collection("recipes")
            .document(id)
            .delete()
    }

    // Increments cookedCount and sets lastCookedAt both locally (for immediate
    // UI response) and in Firestore (for persistence). Updating locally first
    // means the green tint appears instantly without waiting for a round trip.
    func markAsCooked(_ recipe: Recipe, userId: String) {
        guard let id = recipe.id, !userId.isEmpty else { return }
        let newCount = recipe.cookedCount + 1
        let now = Date()

        if let idx = recipes.firstIndex(where: { $0.id == id }) {
            recipes[idx].cookedCount = newCount
            recipes[idx].lastCookedAt = now
        }
        db.collection("users").document(userId).collection("recipes").document(id)
            .updateData(["cookedCount": newCount, "lastCookedAt": now])

        Task {
            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .recipeCooked,
                eventKey: "recipe_cooked_\(id)_\(newCount)",
                metadata: [
                    "recipeId": id,
                    "title": recipe.title
                ]
            )
        }
    }

    // Replaces the entire recipe document so revised recipes (from the review
    // flow AI rewrite) overwrite the old version atomically.
    func updateRecipeAfterReview(_ updatedRecipe: Recipe, userId: String) {
        guard let id = updatedRecipe.id, !userId.isEmpty else { return }

        if let idx = recipes.firstIndex(where: { $0.id == id }) {
            recipes[idx] = updatedRecipe
        }
        guard let encoded = try? Firestore.Encoder().encode(updatedRecipe) else { return }
        db.collection("users").document(userId).collection("recipes").document(id).setData(encoded)
    }

    // Writes a review to the reviews sub-collection at recipes/{id}/reviews.
    // Kept as a sub-collection (not an array field) so it scales without
    // hitting Firestore's 1 MB document limit.
    func saveReview(recipeId: String, liked: [String], likedNote: String, improvement: String, userId: String) {
        guard !userId.isEmpty else { return }
        let data: [String: Any] = [
            "likedTags": liked,
            "likedNote": likedNote,
            "improvement": improvement,
            "createdAt": Date()
        ]
        db.collection("users").document(userId).collection("recipes").document(recipeId)
            .collection("reviews").addDocument(data: data)
    }

    func saveSuggestedRecipe(_ recipe: Recipe, userId: String, openAfterSave: Bool = true) {
        guard !userId.isEmpty else { return }

        Task {
            do {
                let encoded = try Firestore.Encoder().encode(recipe)
                let ref = try await db.collection("users")
                    .document(userId)
                    .collection("recipes")
                    .addDocument(data: encoded)

                var savedRecipe = recipe
                savedRecipe.id = ref.documentID

                await MainActor.run {
                    if openAfterSave {
                        self.justGeneratedRecipe = savedRecipe
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    print("Save suggested recipe error: \(error)")
                }
            }
        }
    }

    func generateAndSave(prompt: String, assistant: CookingAssistant, userId: String) {
        guard !userId.isEmpty, !isGenerating else { return }

        isGenerating = true
        generationState = .generating
        elapsedSeconds = 0
        errorMessage = nil
        justGeneratedRecipe = nil

        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    self.elapsedSeconds += 1
                }
            }
        }

        Task {
            do {
                var recipe = try await retryingTransientChefBuddyAI {
                    try await assistant.waitUntilReady()
                    return try await assistant.generateRecipe(from: prompt)
                }

                let encoded = try Firestore.Encoder().encode(recipe)
                let ref = try await db.collection("users")
                    .document(userId)
                    .collection("recipes")
                    .addDocument(data: encoded)

                recipe.id = ref.documentID

                await MainActor.run {
                    self.timerTask?.cancel()
                    self.isGenerating = false
                    self.generationState = .succeeded
                    self.justGeneratedRecipe = recipe
                }
            } catch {
                let presentation = chefBuddyAIErrorPresentation(for: error)
                let message = "\(presentation.message) \(presentation.retryGuidance)"
                await MainActor.run {
                    self.timerTask?.cancel()
                    self.isGenerating = false
                    self.errorMessage = message
                    self.generationState = .failed(message)
                }
            }
        }
    }

    func resetGenerationPresentation() {
        guard !isGenerating else { return }
        generationState = .idle
        errorMessage = nil
    }

    static func parseRecipe(from text: String) -> Recipe {
        var title = "New Recipe"
        var emoji = "🍽️"
        var description = ""
        var ingredients: [String] = []
        var steps: [String] = []
        var cookTime = "30 mins"
        var servings = "2 people"
        var difficulty = "Medium"
        var tags: [String] = []
        var calories = ""
        var carbs = ""
        var protein = ""
        var fat = ""
        var saturatedFat = ""
        var sugar = ""
        var fiber = ""
        var sodium = ""
        var section = ""

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let low = line.lowercased()

            if low.hasPrefix("title:") {
                title = after("Title:", in: line)
            } else if low.hasPrefix("emoji:") {
                emoji = after("Emoji:", in: line)
            } else if low.hasPrefix("description:") {
                description = after("Description:", in: line)
            } else if low.hasPrefix("cook time:") {
                cookTime = after("Cook Time:", in: line)
            } else if low.hasPrefix("servings:") {
                servings = after("Servings:", in: line)
            } else if low.hasPrefix("difficulty:") {
                difficulty = after("Difficulty:", in: line)
            } else if low.hasPrefix("calories:") {
                calories = after("Calories:", in: line)
            } else if low.hasPrefix("carbs:") || low.hasPrefix("carbohydrates:") {
                carbs = after(low.hasPrefix("carbs:") ? "Carbs:" : "Carbohydrates:", in: line)
            } else if low.hasPrefix("protein:") {
                protein = after("Protein:", in: line)
            } else if low.hasPrefix("saturated fat:") {
                saturatedFat = after("Saturated Fat:", in: line)
            } else if low.hasPrefix("fat:") {
                fat = after("Fat:", in: line)
            } else if low.hasPrefix("sugar:") {
                sugar = after("Sugar:", in: line)
            } else if low.hasPrefix("fiber:") || low.hasPrefix("fibre:") {
                fiber = after(low.hasPrefix("fiber:") ? "Fiber:" : "Fibre:", in: line)
            } else if low.hasPrefix("sodium:") {
                sodium = after("Sodium:", in: line)
            } else if low.hasPrefix("tags:") {
                tags = after("Tags:", in: line)
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else if low.contains("ingredient") {
                section = "ingredients"
            } else if low.contains("instruction") || low.contains("direction") {
                section = "steps"
            } else if line.hasPrefix("-") || line.hasPrefix("•") {
                let item = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty {
                    if section == "steps" {
                        steps.append(item)
                    } else {
                        ingredients.append(item)
                    }
                }
            } else if let first = line.first, first.isNumber, line.count > 2 {
                let secondIdx = line.index(line.startIndex, offsetBy: 1)
                if line[secondIdx] == "." {
                    let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !item.isEmpty && section == "steps" {
                        steps.append(item)
                    }
                }
            }
        }

        if description.isEmpty {
            description = "A delicious recipe generated just for you by ChefBuddy."
        }

        let nutrition = NutritionInfo(
            calories: calories,
            carbs: carbs,
            protein: protein,
            fat: fat,
            saturatedFat: saturatedFat,
            sugar: sugar,
            fiber: fiber,
            sodium: sodium
        )

        let normalizedTags = tags.isEmpty ? [detectedCuisineTag(title: title, description: description, tags: tags)] : tags

        return Recipe(
            title: title,
            emoji: emoji,
            description: description,
            ingredients: ingredients,
            steps: steps,
            cookTime: cookTime,
            servings: servings,
            difficulty: difficulty,
            tags: normalizedTags,
            calories: calories,
            nutrition: nutrition
        )
    }

    private static func after(_ prefix: String, in line: String) -> String {
        guard let r = line.range(of: prefix, options: .caseInsensitive) else { return line }
        return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}

private enum DiscoveryFeedbackAction: String {
    case saved
    case skipped
}

private struct DiscoveryBehaviorSnapshot: Equatable {
    var favoriteCuisines: [String] = []
    var skippedCuisines: [String] = []
    var averagePrepMinutes: Int? = nil
    var averageCalories: Int? = nil
    var pantryUsageRate: Double = 0
    var savedCount: Int = 0
    var cookedCount: Int = 0

    static let empty = DiscoveryBehaviorSnapshot()

    var dominantCuisine: String? {
        favoriteCuisines.first
    }

    var highlightPills: [String] {
        var items: [String] = []

        if let dominantCuisine {
            items.append("Usually \(dominantCuisine)")
        }

        if let averagePrepMinutes {
            items.append("\(averagePrepMinutes) min sweet spot")
        }

        if let averageCalories {
            items.append("Around \(averageCalories) kcal")
        }

        if pantryUsageRate >= 0.55 {
            items.append("Pantry-first")
        } else if pantryUsageRate >= 0.25 {
            items.append("Some pantry pull")
        }

        if items.isEmpty {
            items.append("Learns as you swipe")
        }

        return Array(items.prefix(4))
    }
}

private struct DiscoveryPersonalizationContext {
    let summary: String
    let snapshot: DiscoveryBehaviorSnapshot
}

private final class RecipeDiscoveryStore: ObservableObject {
    static let shared = RecipeDiscoveryStore()

    @Published var chefBuddyPickSuggestions: [RecipeSuggestion] = []
    @Published var swipeDiscoveryDeck: [RecipeSuggestion] = []
    @Published var swipeDiscoverySeenTitles: Set<String> = []
    @Published var isLoadingChefBuddyPicks = false
    @Published var isLoadingSwipeDiscoveryDeck = false
    @Published var isToppingUpSwipeDiscoveryDeck = false
    @Published var discoverySnapshot: DiscoveryBehaviorSnapshot = .empty

    private init() {}
}

private enum DiscoverySuggestionCache {
    private static func key(_ kind: String, userId: String) -> String {
        "chefbuddy.discovery.\(userId).\(kind).v1"
    }

    static func load(_ kind: String, userId: String) -> [RecipeSuggestion] {
        guard !userId.isEmpty,
              let data = UserDefaults.standard.data(forKey: key(kind, userId: userId)),
              let suggestions = try? JSONDecoder().decode([RecipeSuggestion].self, from: data) else {
            return []
        }
        return suggestions
    }

    static func save(_ suggestions: [RecipeSuggestion], kind: String, userId: String) {
        guard !userId.isEmpty,
              let data = try? JSONEncoder().encode(suggestions) else { return }
        UserDefaults.standard.set(data, forKey: key(kind, userId: userId))
    }

    static func loadPantry(userId: String) -> [String: [RecipeSuggestion]] {
        guard !userId.isEmpty,
              let data = UserDefaults.standard.data(forKey: key("pantry", userId: userId)),
              let suggestions = try? JSONDecoder().decode([String: [RecipeSuggestion]].self, from: data) else {
            return [:]
        }
        return suggestions
    }

    static func savePantry(_ suggestions: [String: [RecipeSuggestion]], userId: String) {
        guard !userId.isEmpty,
              let data = try? JSONEncoder().encode(suggestions) else { return }
        UserDefaults.standard.set(data, forKey: key("pantry", userId: userId))
    }

    static func clear(userId: String) {
        ["picks", "deck", "pantry"].forEach {
            UserDefaults.standard.removeObject(forKey: key($0, userId: userId))
        }
    }
}


struct RecipesView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @ObservedObject var assistant: CookingAssistant
    var savedRecipes: [Recipe] = []
    var onOpenLiveCookingPicker: () -> Void = {}
    @StateObject private var vm = RecipesViewModel()
    @StateObject private var discoveryStore = RecipeDiscoveryStore.shared

    @State private var selectedRecipe: Recipe? = nil
    @State private var selectedSuggestionRecipe: Recipe? = nil
    @State private var showGenerateSheet = false
    @State private var showCustomRecipeSheet = false
    @State private var showAllRecipesScreen = false
    @State private var recipeToReview: Recipe? = nil
    @State private var liveHelpRecipe: Recipe? = nil
    @State private var pantryIngredients: [String] = []
    @State private var pantryListener: ListenerRegistration? = nil
    @State private var pantrySpaces: [SimplePantrySpace] = []
    @State private var selectedPantryId: String? = nil
    @State private var showGroceryList = false
    @State private var isGeneratingFromPantry = false
    @State private var pantrySuggestionsById: [String: [RecipeSuggestion]] = [:]
    @State private var pantryIngredientSignatures: [String: String] = [:]
    @State private var selectedPantrySuggestionRecipe: Recipe? = nil
    @State private var infoSheet: RecipesInfoSheet? = nil
    @State private var showSwipeDiscovery = false
    @State private var swipeDiscoveryError: String? = nil
    @State private var swipeDiscoveryActionStep = 0
    @State private var swipeDiscoveryActionTimer: Timer? = nil
    @State private var heroVariant = Int.random(in: 0..<3)
    @State private var recipeHeroMetricIndex = 0
    private let recipeHeroTimer = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    private var userId: String { authVM.userSession?.uid ?? "" }
    private var budgetPreference: String {
        authVM.currentUserProfile?.budget ?? "💵 $$ (Standard)"
    }

    private var chefBuddyPickSuggestions: [RecipeSuggestion] {
        get { discoveryStore.chefBuddyPickSuggestions }
        nonmutating set { discoveryStore.chefBuddyPickSuggestions = newValue }
    }

    private var swipeDiscoveryDeck: [RecipeSuggestion] {
        get { discoveryStore.swipeDiscoveryDeck }
        nonmutating set { discoveryStore.swipeDiscoveryDeck = newValue }
    }

    private var isLoadingChefBuddyPicks: Bool {
        get { discoveryStore.isLoadingChefBuddyPicks }
        nonmutating set { discoveryStore.isLoadingChefBuddyPicks = newValue }
    }

    private var isLoadingSwipeDiscoveryDeck: Bool {
        get { discoveryStore.isLoadingSwipeDiscoveryDeck }
        nonmutating set { discoveryStore.isLoadingSwipeDiscoveryDeck = newValue }
    }

    private var isToppingUpSwipeDiscoveryDeck: Bool {
        get { discoveryStore.isToppingUpSwipeDiscoveryDeck }
        nonmutating set { discoveryStore.isToppingUpSwipeDiscoveryDeck = newValue }
    }

    private var discoverySnapshot: DiscoveryBehaviorSnapshot {
        get { discoveryStore.discoverySnapshot }
        nonmutating set { discoveryStore.discoverySnapshot = newValue }
    }

    private func timeString(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private func recipeFromSuggestion(_ suggestion: RecipeSuggestion) -> Recipe {
        let normalizedTags = suggestion.tags.isEmpty
            ? [detectedCuisineTag(title: suggestion.title, description: suggestion.description, tags: suggestion.tags)]
            : suggestion.tags

        return Recipe(
            title: suggestion.title,
            emoji: suggestion.emoji,
            description: suggestion.description,
            ingredients: suggestion.ingredients,
            steps: suggestion.steps,
            cookTime: suggestion.prepTime,
            servings: suggestion.servings,
            difficulty: suggestion.difficulty,
            tags: normalizedTags,
            calories: suggestion.calories,
            nutrition: suggestion.nutrition
        )
    }

    private func suggestionFromRecipe(_ recipe: Recipe, previous: RecipeSuggestion) -> RecipeSuggestion {
        RecipeSuggestion(
            title: recipe.title,
            emoji: recipe.emoji,
            description: recipe.description,
            prepTime: recipe.cookTime,
            servings: recipe.servings,
            difficulty: recipe.difficulty,
            calories: recipe.calories,
            carbs: recipe.nutrition.carbs,
            protein: recipe.nutrition.protein,
            fat: recipe.nutrition.fat,
            saturatedFat: recipe.nutrition.saturatedFat,
            sugar: recipe.nutrition.sugar,
            fiber: recipe.nutrition.fiber,
            sodium: recipe.nutrition.sodium,
            tags: recipe.tags,
            ingredients: recipe.ingredients,
            steps: recipe.steps,
            matchReason: previous.matchReason
        )
    }

    private func feedbackSuggestion(from recipe: Recipe) -> RecipeSuggestion {
        RecipeSuggestion(
            title: recipe.title,
            emoji: recipe.emoji,
            description: recipe.description,
            prepTime: recipe.cookTime,
            servings: recipe.servings,
            difficulty: recipe.difficulty,
            calories: recipe.calories,
            carbs: recipe.nutrition.carbs,
            protein: recipe.nutrition.protein,
            fat: recipe.nutrition.fat,
            saturatedFat: recipe.nutrition.saturatedFat,
            sugar: recipe.nutrition.sugar,
            fiber: recipe.nutrition.fiber,
            sodium: recipe.nutrition.sodium,
            tags: recipe.tags,
            ingredients: recipe.ingredients,
            steps: recipe.steps,
            matchReason: ""
        )
    }

    private var chefBuddyPicks: [RecipeSuggestion] {
        Array(chefBuddyPickSuggestions.prefix(3))
    }

    private var currentPantry: SimplePantrySpace? {
        pantrySpaces.first(where: { $0.id == selectedPantryId })
    }

    private var currentPantrySuggestions: [RecipeSuggestion] {
        pantrySuggestionsById[selectedPantryId ?? ""] ?? []
    }

    private var recipeLibraryCuisines: [String] {
        let cuisines = vm.recipes.map {
            detectedCuisineTag(title: $0.title, description: $0.description, tags: $0.tags)
        }
        return ["All Cuisines"] + Array(Set(cuisines)).sorted()
    }

    private var recipeFilterCount: Int {
        (vm.selectedFilter == "All" ? 0 : 1)
        + (vm.selectedCuisineFilter == "All Cuisines" ? 0 : 1)
    }

    private func startPantryListener() {
        guard !userId.isEmpty else { return }

        pantryListener?.remove()
        pantryListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("pantrySpaces")
            .addSnapshotListener { snap, _ in
                guard let docs = snap?.documents else { return }

                var spaces: [SimplePantrySpace] = []
                var signatures: [String: String] = [:]
                var changedPantryIds: Set<String> = []
                for doc in docs {
                    let data = doc.data()
                    let name = data["name"] as? String ?? "Pantry"
                    let emoji = data["emoji"] as? String ?? "🥑"
                    let colorTheme = data["colorTheme"] as? String ?? "Orange"
                    let virtualPantry = data["virtualPantry"] as? [String: [String]] ?? [:]
                    let flattenedIngredients = virtualPantry.values.flatMap { $0 }
                    let signature = flattenedIngredients
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        .sorted()
                        .joined(separator: "|")
                    signatures[doc.documentID] = signature
                    if let previous = pantryIngredientSignatures[doc.documentID], previous != signature {
                        changedPantryIds.insert(doc.documentID)
                    }
                    spaces.append(
                        SimplePantrySpace(
                            id: doc.documentID,
                            name: name,
                            emoji: emoji,
                            ingredients: flattenedIngredients,
                            colorTheme: colorTheme
                        )
                    )
                }

                DispatchQueue.main.async {
                    pantrySpaces = spaces.sorted { $0.name < $1.name }
                    pantryIngredientSignatures = signatures

                    for pantryId in changedPantryIds {
                        pantrySuggestionsById.removeValue(forKey: pantryId)
                    }

                    let preferredPantryId = authVM.currentUserProfile?.activePantryId
                    if let selectedPantryId,
                       pantrySpaces.contains(where: { $0.id == selectedPantryId }) == false {
                        self.selectedPantryId = nil
                    }

                    if self.selectedPantryId == nil,
                       let preferredPantryId,
                       pantrySpaces.contains(where: { $0.id == preferredPantryId }) {
                        self.selectedPantryId = preferredPantryId
                    } else if self.selectedPantryId == nil {
                        self.selectedPantryId = pantrySpaces.first?.id
                    }

                    pantryIngredients = pantrySpaces.first(where: { $0.id == self.selectedPantryId })?.ingredients ?? []

                    if let selectedPantry = pantrySpaces.first(where: { $0.id == self.selectedPantryId }),
                       !selectedPantry.ingredients.isEmpty,
                       pantrySuggestionsById[selectedPantry.id] == nil,
                       !isGeneratingFromPantry {
                        generateFromSelectedPantry(selectedPantry)
                    }
                }
            }
    }

    private func stopPantryListener() {
        pantryListener?.remove()
        pantryListener = nil
    }

    private func startSwipeDiscoveryActionTimer() {
        swipeDiscoveryActionTimer?.invalidate()
        swipeDiscoveryActionTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
            swipeDiscoveryActionStep += 1
        }
    }

    private func stopSwipeDiscoveryActionTimer() {
        swipeDiscoveryActionTimer?.invalidate()
        swipeDiscoveryActionTimer = nil
        swipeDiscoveryActionStep = 0
    }

    private func generateFromSelectedPantry(_ pantry: SimplePantrySpace) {
        guard !pantry.ingredients.isEmpty else { return }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            isGeneratingFromPantry = true
        }

        Task {
            do {
                let generated = try await assistant.generatePantryRecipes(ingredients: pantry.ingredients)
                await MainActor.run {
                    pantrySuggestionsById[pantry.id] = generated
                    persistSuggestionCache()
                    if selectedPantryId == pantry.id {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            isGeneratingFromPantry = false
                        }
                    } else {
                        isGeneratingFromPantry = false
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        isGeneratingFromPantry = false
                    }
                }
            }
        }
    }

    private func refreshSelectedPantrySuggestions(_ pantry: SimplePantrySpace) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        pantrySuggestionsById[pantry.id] = []
        persistSuggestionCache()
        generateFromSelectedPantry(pantry)
    }

    private func removeAndReplacePantrySuggestion(_ recipe: Recipe, pantry: SimplePantrySpace) {
        let normalizedTitle = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var currentSuggestions = pantrySuggestionsById[pantry.id] ?? []
        currentSuggestions.removeAll {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
        }
        pantrySuggestionsById[pantry.id] = currentSuggestions
        persistSuggestionCache()

        Task {
            do {
                let excludingTitles = currentSuggestions.map(\.title)
                let replacement = try await assistant.generateSinglePantryRecipe(
                    ingredients: pantry.ingredients,
                    excludingTitles: excludingTitles
                )

                await MainActor.run {
                    var refreshedSuggestions = pantrySuggestionsById[pantry.id] ?? currentSuggestions
                    refreshedSuggestions.append(replacement)
                    pantrySuggestionsById[pantry.id] = refreshedSuggestions
                    persistSuggestionCache()
                }
            } catch {
                print("Failed to fetch replacement pantry recipe: \(error)")
            }
        }
    }

    private func pantrySuggestion(from recipe: Recipe, previous: RecipeSuggestion) -> RecipeSuggestion {
        let normalizedTags = recipe.tags.isEmpty
            ? [detectedCuisineTag(title: recipe.title, description: recipe.description, tags: recipe.tags)]
            : recipe.tags

        return RecipeSuggestion(
            title: recipe.title,
            emoji: recipe.emoji,
            description: recipe.description,
            prepTime: recipe.cookTime,
            servings: recipe.servings,
            difficulty: recipe.difficulty,
            calories: recipe.calories,
            carbs: recipe.nutrition.carbs,
            protein: recipe.nutrition.protein,
            fat: recipe.nutrition.fat,
            saturatedFat: recipe.nutrition.saturatedFat,
            sugar: recipe.nutrition.sugar,
            fiber: recipe.nutrition.fiber,
            sodium: recipe.nutrition.sodium,
            tags: normalizedTags,
            ingredients: recipe.ingredients,
            steps: recipe.steps,
            matchReason: previous.matchReason
        )
    }

    private func addMissingIngredientsToGroceryList(recipe: Recipe, missing: [String]) {
        guard !userId.isEmpty else { return }
        let trimmedMissing = missing
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && isAlwaysAvailableIngredient($0) == false }
        guard !trimmedMissing.isEmpty else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let collection = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("groceryList")
            .document("active")
            .collection("items")

        let group = DispatchGroup()
        let writeLock = NSLock()
        var hasSuccessfulWrite = false

        for ingredient in trimmedMissing {
            let normalized = normalizedIngredientKey(from: ingredient)
            guard !normalized.isEmpty else { continue }

            let recipeIdentifier = recipe.id ?? recipe.title
            let docId = sanitizedDocumentId("\(recipeIdentifier)-\(normalized)")
            let payload = GroceryListItem(
                id: nil,
                ingredientDisplay: ingredient,
                normalizedIngredient: normalized,
                quantityHint: quantityHint(from: ingredient),
                recipeId: recipe.id,
                recipeTitle: recipe.title,
                recipeEmoji: recipe.emoji,
                isPurchased: false,
                createdAt: Date(),
                matchesByStore: [:],
                matchAttemptedStores: [:]
            )

            group.enter()
            do {
                try collection.document(docId).setData(from: payload, merge: true) { error in
                    if error == nil {
                        writeLock.lock()
                        hasSuccessfulWrite = true
                        writeLock.unlock()
                    }
                    group.leave()
                }
            } catch {
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if hasSuccessfulWrite {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    private func normalizedSuggestionTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func discoveryExclusionTitles(
        includeChefBuddyPicks: Bool,
        includeSwipeDeck: Bool,
        additional: [String] = []
    ) -> [String] {
        var titles = vm.recipes.map(\.title)
        titles.append(contentsOf: additional)

        if includeChefBuddyPicks {
            titles.append(contentsOf: chefBuddyPickSuggestions.map(\.title))
        }

        if includeSwipeDeck {
            titles.append(contentsOf: swipeDiscoveryDeck.map(\.title))
            titles.append(contentsOf: discoveryStore.swipeDiscoverySeenTitles)
        }

        var seen: Set<String> = []
        return titles.filter { title in
            let normalized = normalizedSuggestionTitle(title)
            guard !normalized.isEmpty else { return false }
            return seen.insert(normalized).inserted
        }
    }

    private func requestPersonalizedSuggestions(
        count: Int,
        excludingTitles: [String]
    ) async -> [RecipeSuggestion] {
        do {
            try await assistant.waitUntilReady()
            let context = await loadDiscoveryPersonalizationContext()
            await MainActor.run {
                discoverySnapshot = context.snapshot
            }

            return try await assistant.generateRecipeSuggestions(
                personalizationSummary: context.summary,
                count: count,
                excludingTitles: excludingTitles
            )
        } catch {
            print("Personalized suggestion fetch failed: \(error)")
            return []
        }
    }

    private func markSwipeDiscoveryTitlesSeen(_ suggestions: [RecipeSuggestion]) {
        for suggestion in suggestions {
            discoveryStore.swipeDiscoverySeenTitles.insert(normalizedSuggestionTitle(suggestion.title))
        }
    }

    @MainActor
    private func restoreSuggestionCacheIfNeeded() {
        if chefBuddyPickSuggestions.isEmpty {
            chefBuddyPickSuggestions = DiscoverySuggestionCache.load("picks", userId: userId)
        }
        if swipeDiscoveryDeck.isEmpty {
            swipeDiscoveryDeck = DiscoverySuggestionCache.load("deck", userId: userId)
            markSwipeDiscoveryTitlesSeen(swipeDiscoveryDeck)
        }
        if pantrySuggestionsById.isEmpty {
            pantrySuggestionsById = DiscoverySuggestionCache.loadPantry(userId: userId)
        }
    }

    @MainActor
    private func persistSuggestionCache() {
        DiscoverySuggestionCache.save(chefBuddyPickSuggestions, kind: "picks", userId: userId)
        DiscoverySuggestionCache.save(swipeDiscoveryDeck, kind: "deck", userId: userId)
        DiscoverySuggestionCache.savePantry(pantrySuggestionsById, userId: userId)
    }

    private func loadChefBuddyPicks(force: Bool = false) async {
        guard !isLoadingChefBuddyPicks else { return }
        if !force, !chefBuddyPicks.isEmpty { return }

        await MainActor.run {
            isLoadingChefBuddyPicks = true
            if force {
                chefBuddyPickSuggestions = []
            }
        }

        let generated = await requestPersonalizedSuggestions(
            count: 3,
            excludingTitles: await MainActor.run {
                discoveryExclusionTitles(includeChefBuddyPicks: false, includeSwipeDeck: true)
            }
        )

        await MainActor.run {
            chefBuddyPickSuggestions = Array(generated.prefix(3))
            isLoadingChefBuddyPicks = false
            persistSuggestionCache()
        }
    }

    private func topUpChefBuddyPicksIfNeeded() async {
        let currentCount = await MainActor.run { chefBuddyPickSuggestions.count }
        guard currentCount < 3 else { return }
        guard !isLoadingChefBuddyPicks else { return }

        await MainActor.run { isLoadingChefBuddyPicks = true }

        let needed = max(1, 3 - currentCount)
        let generated = await requestPersonalizedSuggestions(
            count: needed,
            excludingTitles: await MainActor.run {
                discoveryExclusionTitles(includeChefBuddyPicks: true, includeSwipeDeck: true)
            }
        )

        await MainActor.run {
            let existingTitles = Set(chefBuddyPickSuggestions.map { normalizedSuggestionTitle($0.title) })
            let filtered = generated.filter { !existingTitles.contains(normalizedSuggestionTitle($0.title)) }
            chefBuddyPickSuggestions.append(contentsOf: filtered)
            chefBuddyPickSuggestions = Array(chefBuddyPickSuggestions.prefix(3))
            isLoadingChefBuddyPicks = false
            persistSuggestionCache()
        }
    }

    private func loadSwipeDiscoveryDeck(force: Bool = false) async {
        let currentCount = await MainActor.run { swipeDiscoveryDeck.count }
        guard force || currentCount < 10 else { return }
        guard !isLoadingSwipeDiscoveryDeck else { return }

        await MainActor.run {
            isLoadingSwipeDiscoveryDeck = true
            swipeDiscoveryError = nil
            if force {
                swipeDiscoveryDeck = []
                discoveryStore.swipeDiscoverySeenTitles = []
            }
        }

        let needed = force ? 10 : max(1, 10 - currentCount)
        let generated = await requestPersonalizedSuggestions(
            count: needed,
            excludingTitles: await MainActor.run {
                discoveryExclusionTitles(includeChefBuddyPicks: true, includeSwipeDeck: true)
            }
        )

        await MainActor.run {
            if force {
                swipeDiscoveryDeck = generated
            } else {
                let existingTitles = Set(swipeDiscoveryDeck.map { normalizedSuggestionTitle($0.title) })
                let filtered = generated.filter { !existingTitles.contains(normalizedSuggestionTitle($0.title)) }
                swipeDiscoveryDeck.append(contentsOf: filtered)
            }
            markSwipeDiscoveryTitlesSeen(swipeDiscoveryDeck)
            isLoadingSwipeDiscoveryDeck = false
            persistSuggestionCache()
            if swipeDiscoveryDeck.isEmpty {
                swipeDiscoveryError = "ChefBuddy couldn’t build a fresh deck right now."
            }
        }
    }

    private func topUpSwipeDiscoveryDeckIfNeeded() async {
        let currentCount = await MainActor.run { swipeDiscoveryDeck.count }
        guard currentCount < 10 else { return }
        guard !isToppingUpSwipeDiscoveryDeck else { return }

        await MainActor.run { isToppingUpSwipeDiscoveryDeck = true }

        let generated = await requestPersonalizedSuggestions(
            count: max(1, 10 - currentCount),
            excludingTitles: await MainActor.run {
                discoveryExclusionTitles(includeChefBuddyPicks: true, includeSwipeDeck: true)
            }
        )

        await MainActor.run {
            let existingTitles = Set(swipeDiscoveryDeck.map { normalizedSuggestionTitle($0.title) })
            let filtered = generated.filter { !existingTitles.contains(normalizedSuggestionTitle($0.title)) }
            swipeDiscoveryDeck.append(contentsOf: filtered)
            markSwipeDiscoveryTitlesSeen(filtered)
            isToppingUpSwipeDiscoveryDeck = false
            persistSuggestionCache()
        }
    }

    private func loadDiscoveryPersonalizationContext() async -> DiscoveryPersonalizationContext {
        guard !userId.isEmpty else {
            return DiscoveryPersonalizationContext(summary: "", snapshot: .empty)
        }

        let recipes = await MainActor.run { vm.recipes }
        let currentPantryIngredients = await MainActor.run { pantryIngredients }
        let profile = await MainActor.run { authVM.currentUserProfile }

        let cookedRecipes = recipes.filter { $0.hasBeenCooked }
        let allBehaviorRecipes = cookedRecipes.isEmpty ? recipes : cookedRecipes + recipes

        var cuisineWeights: [String: Int] = [:]
        var prepValues: [Int] = []
        var calorieValues: [Int] = []
        var pantryOverlapValues: [Double] = []

        for recipe in allBehaviorRecipes {
            let cuisine = primaryCuisineTag(for: recipe.tags, title: recipe.title, description: recipe.description)
            cuisineWeights[cuisine, default: 0] += max(1, recipe.cookedCount + (recipe.isFavorite ? 1 : 0))

            if let minutes = prepMinutes(from: recipe.cookTime) {
                prepValues.append(minutes)
            }

            if let calories = calorieNumber(from: recipe.calories) {
                calorieValues.append(calories)
            }

            pantryOverlapValues.append(
                pantryOverlapRatio(ingredients: recipe.ingredients, pantryIngredients: currentPantryIngredients)
            )
        }

        let db = Firestore.firestore()
        var skippedCuisines: [String: Int] = [:]
        var skippedTitles: [String] = []

        do {
            let feedbackDocuments = try await db.collection("users")
                .document(userId)
                .collection("discoveryFeedback")
                .order(by: "createdAt", descending: true)
                .limit(to: 40)
                .getDocuments()

            for document in feedbackDocuments.documents {
                let data = document.data()
                guard let action = data["action"] as? String, action == DiscoveryFeedbackAction.skipped.rawValue else {
                    continue
                }

                let cuisine = (data["cuisine"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !cuisine.isEmpty {
                    skippedCuisines[cuisine, default: 0] += 1
                }

                let title = (data["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    skippedTitles.append(title)
                }
            }
        } catch {
            print("Failed to load discovery feedback: \(error)")
        }

        let sortedFavoriteCuisines = cuisineWeights
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .map(\.key)

        let sortedSkippedCuisines = skippedCuisines
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .map(\.key)

        let averagePrep = prepValues.isEmpty ? nil : Int((Double(prepValues.reduce(0, +)) / Double(prepValues.count)).rounded())
        let averageCalories = calorieValues.isEmpty ? nil : Int((Double(calorieValues.reduce(0, +)) / Double(calorieValues.count)).rounded())
        let pantryUsageRate = pantryOverlapValues.isEmpty ? 0 : pantryOverlapValues.reduce(0, +) / Double(pantryOverlapValues.count)
        let reviewSummary = await loadReviewFeedbackSummary()

        var summaryParts: [String] = []

        if let profile, !profile.cuisines.isEmpty {
            summaryParts.append("Profile cuisine interests: \(profile.cuisines.prefix(5).joined(separator: ", ")).")
        }

        if !sortedFavoriteCuisines.isEmpty {
            summaryParts.append("Recent saved/cooked cuisines lean toward: \(sortedFavoriteCuisines.prefix(3).joined(separator: ", ")).")
        }

        if !sortedSkippedCuisines.isEmpty {
            summaryParts.append("Recently skipped cuisines or vibes: \(sortedSkippedCuisines.prefix(3).joined(separator: ", ")).")
        }

        if !skippedTitles.isEmpty {
            summaryParts.append("Recently passed on titles similar to: \(Array(skippedTitles.prefix(4)).joined(separator: ", ")).")
        }

        if let averagePrep {
            summaryParts.append("Comfort prep window is around \(averagePrep) minutes.")
        }

        if let averageCalories {
            summaryParts.append("Typical calorie style is around \(averageCalories) kcal per serving.")
        }

        if pantryUsageRate > 0 {
            let usageLabel: String
            switch pantryUsageRate {
            case 0.55...:
                usageLabel = "high"
            case 0.25...:
                usageLabel = "moderate"
            default:
                usageLabel = "light"
            }
            summaryParts.append("Pantry usage rate is \(usageLabel), based on overlap between cooked/saved recipes and the active pantry.")
        }

        if !reviewSummary.isEmpty {
            summaryParts.append(reviewSummary)
        }

        summaryParts.append("Use their habits as guidance, but avoid making every suggestion the same cuisine. Keep the deck balanced between comfort-zone picks and fresh cuisines that still fit their time, calorie style, budget, and restrictions.")

        let snapshot = DiscoveryBehaviorSnapshot(
            favoriteCuisines: Array(sortedFavoriteCuisines.prefix(3)),
            skippedCuisines: Array(sortedSkippedCuisines.prefix(3)),
            averagePrepMinutes: averagePrep,
            averageCalories: averageCalories,
            pantryUsageRate: pantryUsageRate,
            savedCount: recipes.count,
            cookedCount: cookedRecipes.count
        )

        return DiscoveryPersonalizationContext(
            summary: summaryParts.joined(separator: " "),
            snapshot: snapshot
        )
    }


    private func loadReviewFeedbackSummary() async -> String {
        guard !userId.isEmpty else { return "" }
        let db = Firestore.firestore()
        var improvements: [String] = []
        var liked: [String] = []

        do {

            let recipeDocs = try await db.collection("users").document(userId)
                .collection("recipes").getDocuments()

            for recipeDoc in recipeDocs.documents {
                let reviews = try await db.collection("users").document(userId)
                    .collection("recipes").document(recipeDoc.documentID)
                    .collection("reviews")
                    .order(by: "createdAt", descending: true)
                    .limit(to: 3)
                    .getDocuments()

                for review in reviews.documents {
                    let data = review.data()
                    if let imp = data["improvement"] as? String, !imp.trimmingCharacters(in: .whitespaces).isEmpty {
                        improvements.append(imp)
                    }
                    if let tags = data["likedTags"] as? [String] {
                        liked.append(contentsOf: tags)
                    }
                    if let note = data["likedNote"] as? String, !note.trimmingCharacters(in: .whitespaces).isEmpty {
                        liked.append(note)
                    }
                }
            }
        } catch {
            print("Failed to load review feedback: \(error)")
        }

        var summary = ""
        if !liked.isEmpty {
            let topLiked = Array(Set(liked)).prefix(6).joined(separator: ", ")
            summary += "User has previously enjoyed: \(topLiked). "
        }
        if !improvements.isEmpty {
            let topImprovements = improvements.prefix(5).joined(separator: "; ")
            summary += "User has asked for improvements like: \(topImprovements). Avoid repeating these issues."
        }
        return summary
    }

    private func toggleFavoriteEverywhere(_ recipe: Recipe) {
        vm.toggleFavorite(recipe, userId: userId)

        if selectedRecipe?.id == recipe.id {
            selectedRecipe?.isFavorite.toggle()
        }
    }

    private func trackDiscoveryFeedback(_ suggestion: RecipeSuggestion, action: DiscoveryFeedbackAction) async {
        guard !userId.isEmpty else { return }

        let db = Firestore.firestore()
        let cuisine = primaryCuisineTag(for: suggestion.tags, title: suggestion.title, description: suggestion.description)

        var payload: [String: Any] = [
            "title": suggestion.title,
            "emoji": suggestion.emoji,
            "action": action.rawValue,
            "cuisine": cuisine,
            "tags": suggestion.tags,
            "source": "chefbuddy_swipe",
            "createdAt": Date()
        ]

        if let prep = prepMinutes(from: suggestion.prepTime) {
            payload["prepMinutes"] = prep
        }

        if let calories = calorieNumber(from: suggestion.calories) {
            payload["calories"] = calories
        }

        do {
            _ = try await db.collection("users")
                .document(userId)
                .collection("discoveryFeedback")
                .addDocument(data: payload)
        } catch {
            print("Failed to track discovery feedback: \(error)")
        }
    }

    private func refreshDiscoverySnapshot() async {
        let context = await loadDiscoveryPersonalizationContext()
        await MainActor.run {
            discoverySnapshot = context.snapshot
        }
    }

    private func saveChefBuddyPick(_ suggestion: RecipeSuggestion) {
        let recipe = recipeFromSuggestion(suggestion)
        vm.saveSuggestedRecipe(recipe, userId: userId)
        removeSuggestionFromChefBuddyPicks(recipe)

        Task {
            await trackDiscoveryFeedback(suggestion, action: .saved)
            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .swipeSave,
                metadata: [
                    "title": suggestion.title,
                    "source": "chefbuddy_pick"
                ]
            )
            await refreshDiscoverySnapshot()
            await topUpChefBuddyPicksIfNeeded()
        }
    }

    private func dislikeChefBuddyPick(_ recipe: Recipe) {
        let suggestion = feedbackSuggestion(from: recipe)
        removeSuggestionFromChefBuddyPicks(recipe)

        Task {
            await trackDiscoveryFeedback(suggestion, action: .skipped)
            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .swipeSkip,
                metadata: [
                    "title": suggestion.title,
                    "source": "chefbuddy_pick"
                ]
            )
            await refreshDiscoverySnapshot()
            await topUpChefBuddyPicksIfNeeded()
        }
    }

    private func removeSuggestionFromChefBuddyPicks(_ recipe: Recipe) {
        let normalizedTitle = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        chefBuddyPickSuggestions.removeAll {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
        }
        selectedSuggestionRecipe = nil
    }

    private func saveSuggestionFromDiscovery(_ suggestion: RecipeSuggestion) {
        let recipe = recipeFromSuggestion(suggestion)
        vm.saveSuggestedRecipe(recipe, userId: userId, openAfterSave: false)
        removeSuggestionFromSwipeDeck(suggestion)

        Task {
            await trackDiscoveryFeedback(suggestion, action: .saved)
            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .swipeSave,
                metadata: [
                    "title": suggestion.title,
                    "source": "swipe_discovery"
                ]
            )
            await refreshDiscoverySnapshot()
            await topUpSwipeDiscoveryDeckIfNeeded()
            await loadChefBuddyPicks(force: true)
        }
    }

    private func skipSuggestionFromDiscovery(_ suggestion: RecipeSuggestion) {
        removeSuggestionFromSwipeDeck(suggestion)

        Task {
            await trackDiscoveryFeedback(suggestion, action: .skipped)
            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .swipeSkip,
                metadata: [
                    "title": suggestion.title,
                    "source": "swipe_discovery"
                ]
            )
            await refreshDiscoverySnapshot()
            await topUpSwipeDiscoveryDeckIfNeeded()
            await loadChefBuddyPicks(force: true)
        }
    }

    private func removeSuggestionFromSwipeDeck(_ suggestion: RecipeSuggestion) {
        let normalizedTitle = normalizedSuggestionTitle(suggestion.title)
        swipeDiscoveryDeck.removeAll {
            normalizedSuggestionTitle($0.title) == normalizedTitle
        }
        persistSuggestionCache()
    }

    private func openSwipeDiscovery() {
        showSwipeDiscovery = true

        Task {
            await refreshDiscoverySnapshot()
            if !swipeDiscoveryDeck.isEmpty {
                await topUpSwipeDiscoveryDeckIfNeeded()
            }
        }
    }

    private func openGroceryListSheetSafely() {
        if selectedRecipe != nil {
            selectedRecipe = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                showGroceryList = true
            }
            return
        }

        if selectedSuggestionRecipe != nil {
            selectedSuggestionRecipe = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                showGroceryList = true
            }
            return
        }

        if showAllRecipesScreen {
            showAllRecipesScreen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                showGroceryList = true
            }
            return
        }

        showGroceryList = true
    }

    var body: some View {
        contentView

            .onAppear {
                heroVariant = Int.random(in: 0..<3)
                vm.startListening(userId: userId)
                startPantryListener()
                startSwipeDiscoveryActionTimer()
            }
            .onDisappear {
                vm.stopListening()
                stopPantryListener()
                stopSwipeDiscoveryActionTimer()
            }
            .task {
                restoreSuggestionCacheIfNeeded()
                if chefBuddyPickSuggestions.isEmpty {
                    await loadChefBuddyPicks(force: true)
                }
            }
        .onChange(of: vm.justGeneratedRecipe) { recipe in
            if recipe != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    selectedRecipe = recipe
                    vm.justGeneratedRecipe = nil
                }
            }
        }
        .onChange(of: selectedPantryId) { pantryId in
            pantryIngredients = pantrySpaces.first(where: { $0.id == pantryId })?.ingredients ?? []
            authVM.updateActivePantrySelection(pantryId)
            if let pantry = pantrySpaces.first(where: { $0.id == pantryId }),
               !pantry.ingredients.isEmpty,
               pantrySuggestionsById[pantry.id] == nil,
               !isGeneratingFromPantry {
                generateFromSelectedPantry(pantry)
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .discoveryFeedbackDidReset)) { _ in
            Task {
                await MainActor.run {
                    discoveryStore.swipeDiscoverySeenTitles.removeAll()
                    swipeDiscoveryDeck.removeAll()
                    chefBuddyPickSuggestions.removeAll()
                    discoverySnapshot = .empty
                    DiscoverySuggestionCache.clear(userId: userId)
                }
                await refreshDiscoverySnapshot()
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await loadChefBuddyPicks(force: true) }
                    group.addTask { await loadSwipeDiscoveryDeck(force: true) }
                }
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
        .onReceive(recipeHeroTimer) { _ in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                recipeHeroMetricIndex = (recipeHeroMetricIndex + 1) % 4
            }
        }
        .sheet(isPresented: $showGenerateSheet) {
            GenerateRecipeSheet(vm: vm, assistant: assistant, userId: userId)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showCustomRecipeSheet) {
            SimplifiedCustomRecipeSheet(
                assistant: assistant,
                onSave: { recipe in
                    vm.saveSuggestedRecipe(recipe, userId: userId, openAfterSave: false)
                }
            )
        }
        .sheet(item: $selectedRecipe) { recipe in
            RecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                pantryIngredients: pantryIngredients,
                pantrySpaces: pantrySpaces,
                selectedPantryId: selectedPantryId,
                onFavorite: {
                    toggleFavoriteEverywhere(recipe)
                },
                onDelete: {
                    vm.deleteRecipe(recipe, userId: userId)
                    selectedRecipe = nil
                },
                userId: userId,
                onRecipeUpdated: { updated in
                    vm.updateRecipeAfterReview(updated, userId: userId)
                    selectedRecipe = updated
                },
                onMarkCooked: {
                    selectedRecipe = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        recipeToReview = recipe
                    }
                },
                onLiveHelp: {
                    selectedRecipe = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        liveHelpRecipe = recipe
                    }
                },
                onAddMissingToGrocery: { targetRecipe, missing in
                    addMissingIngredientsToGroceryList(recipe: targetRecipe, missing: missing)
                },
                onOpenGroceryList: {
                    openGroceryListSheetSafely()
                },
                onSelectPantry: { pantryId in
                    selectedPantryId = pantryId
                }
            )
        }
        .sheet(item: $selectedSuggestionRecipe) { recipe in
            SuggestedRecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                pantryIngredients: pantryIngredients,
                onSave: {
                    let suggestion = feedbackSuggestion(from: recipe)
                    vm.saveSuggestedRecipe(recipe, userId: userId)
                    removeSuggestionFromChefBuddyPicks(recipe)
                    Task {
                        await trackDiscoveryFeedback(suggestion, action: .saved)
                        await refreshDiscoverySnapshot()
                        await topUpChefBuddyPicksIfNeeded()
                    }
                    },
                onDislike: {
                    dislikeChefBuddyPick(recipe)
                },
                onRecipeUpdated: { updated in
                    let normalizedTitle = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if let idx = chefBuddyPickSuggestions.firstIndex(where: {
                        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
                    }) {
                        chefBuddyPickSuggestions[idx] = suggestionFromRecipe(updated, previous: chefBuddyPickSuggestions[idx])
                        selectedSuggestionRecipe = updated
                    }
                },
                onLiveHelp: {
                    selectedSuggestionRecipe = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        liveHelpRecipe = recipe
                    }
                }
            )
        }
        .sheet(item: $selectedPantrySuggestionRecipe) { recipe in
            SuggestedRecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                pantryIngredients: pantryIngredients,
                onSave: {
                    vm.saveSuggestedRecipe(recipe, userId: userId)
                    if let pantry = currentPantry {
                        removeAndReplacePantrySuggestion(recipe, pantry: pantry)
                    }
                    selectedPantrySuggestionRecipe = nil
                },
                onDislike: {
                    if let pantry = currentPantry {
                        removeAndReplacePantrySuggestion(recipe, pantry: pantry)
                    }
                    selectedPantrySuggestionRecipe = nil
                },
                onRecipeUpdated: { updated in
                    guard let pantry = currentPantry else { return }
                    var suggestions = pantrySuggestionsById[pantry.id] ?? []
                    let normalizedTitle = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if let idx = suggestions.firstIndex(where: {
                        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
                    }) {
                        suggestions[idx] = pantrySuggestion(from: updated, previous: suggestions[idx])
                        pantrySuggestionsById[pantry.id] = suggestions
                        persistSuggestionCache()
                        selectedPantrySuggestionRecipe = updated
                    }
                },
                onLiveHelp: {
                    selectedPantrySuggestionRecipe = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        liveHelpRecipe = recipe
                    }
                }
            )
        }
        .sheet(isPresented: $showAllRecipesScreen) {
            AllRecipesView(
                vm: vm,
                userId: userId,
                assistant: assistant,
                pantryIngredients: pantryIngredients,
                onAddMissingToGrocery: { recipe, missing in
                    addMissingIngredientsToGroceryList(recipe: recipe, missing: missing)
                },
                onOpenGroceryList: {
                    openGroceryListSheetSafely()
                }
            )
        }
        .sheet(isPresented: $showGroceryList) {
            NavigationStack {
                GroceryListView(
                    userId: userId,
                    assistant: assistant,
                    budgetPreference: budgetPreference
                )
            }
        }
        .sheet(item: $infoSheet) { item in
            InfoMessageSheet(title: item.title, message: item.message)
        }
        .fullScreenCover(isPresented: $showSwipeDiscovery) {
            SwipeDiscoveryScreen(
                suggestions: swipeDiscoveryDeck,
                behaviorSnapshot: discoverySnapshot,
                isLoadingInitial: isLoadingSwipeDiscoveryDeck && swipeDiscoveryDeck.isEmpty,
                isLoadingMore: isToppingUpSwipeDiscoveryDeck,
                errorMessage: swipeDiscoveryError,
                onDismiss: { showSwipeDiscovery = false },
                onRefresh: {
                    Task { await loadSwipeDiscoveryDeck(force: true) }
                },
                onSave: { suggestion in
                    saveSuggestionFromDiscovery(suggestion)
                },
                onSkip: { suggestion in
                    skipSuggestionFromDiscovery(suggestion)
                }
            )
        }
        .sheet(item: $recipeToReview) { recipe in
            RecipeReviewView(
                recipe: recipe,
                assistant: assistant,
                userId: userId,
                onComplete: { updatedRecipe, liked, likedNote, improvement in

                    var cooked = updatedRecipe
                    if cooked.cookedCount == updatedRecipe.cookedCount {

                        cooked.cookedCount = max(updatedRecipe.cookedCount, recipe.cookedCount + 1)
                    }
                    cooked.lastCookedAt = Date()
                    vm.updateRecipeAfterReview(cooked, userId: userId)
                    if let recipeId = cooked.id {
                        vm.saveReview(recipeId: recipeId, liked: Array(liked), likedNote: likedNote, improvement: improvement, userId: userId)
                        Task {
                            await GrowthEngine.shared.logActivity(
                                userId: userId,
                                type: .recipeCooked,
                                eventKey: "recipe_cooked_review_\(recipeId)_\(cooked.cookedCount)",
                                metadata: [
                                    "recipeId": recipeId,
                                    "title": cooked.title,
                                    "source": "review"
                                ]
                            )
                        }
                    }
                    recipeToReview = nil
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $liveHelpRecipe) { recipe in
            LiveCookingView(recipe: recipe, assistant: assistant, userId: userId)
        }
    }
    private func errorBanner(_ err: String) -> some View {
        VStack {
            Spacer()

            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.white)

                Text(err)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Spacer()

                Button(action: { vm.errorMessage = nil }) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.red.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .red.opacity(0.3), radius: 10, y: 4)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }
    private var contentView: some View {
        ZStack {
            ChefBuddyBackground()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    headerView
                    pantryDiscoverySection
                    suggestionsSection
                    spotlightSection
                    recipesGridSection
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 136)
            }

            if let err = vm.errorMessage {
                errorBanner(err)
            }
        }
    }
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(vm.filters, id: \.self) { filter in
                    Button {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                            vm.selectedFilter = filter
                        }
                    } label: {
                        Text(filter.replacingOccurrences(of: "❤️ ", with: "").replacingOccurrences(of: "✅ ", with: ""))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(vm.selectedFilter == filter ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                vm.selectedFilter == filter ? Color.orange : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(vm.filteredRecipes.count) recipe\(vm.filteredRecipes.count == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text(vm.selectedCuisineFilter == "All Cuisines" ? "Your cookbook" : vm.selectedCuisineFilter)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if recipeFilterCount > 0 {
                    Button("Reset") {
                        withAnimation {
                            vm.selectedFilter = "All"
                            vm.selectedCuisineFilter = "All Cuisines"
                        }
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                }

                Menu {
                    Section("Recipe quality") {
                        ForEach(["⚡ Quick", "💪 Protein", "🥗 Healthy"], id: \.self) { quality in
                            Button {
                                vm.selectedFilter = vm.selectedFilter == quality ? "All" : quality
                            } label: {
                                if vm.selectedFilter == quality {
                                    Label(quality, systemImage: "checkmark")
                                } else {
                                    Text(quality)
                                }
                            }
                        }
                    }

                    Section("Cuisine") {
                        ForEach(recipeLibraryCuisines, id: \.self) { cuisine in
                            Button {
                                vm.selectedCuisineFilter = cuisine
                            } label: {
                                if vm.selectedCuisineFilter == cuisine {
                                    Label(cuisine, systemImage: "checkmark")
                                } else {
                                    Text(cuisine)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text(recipeFilterCount == 0 ? "Filter" : "Filter \(recipeFilterCount)")
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.orange.opacity(0.10), in: Capsule())
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private var headerView: some View {
        let heroTitles = [
            "Discover it.\nCook it. Keep it.",
            "Your next favorite\nstarts here.",
            "A cookbook that\nlearns your taste."
        ]
        let heroEyebrows = ["YOUR RECIPE WORLD", "CURATED FOR YOU", "YOUR COOKING LIBRARY"]
        let heroIcons = ["book.pages.fill", "sparkles", "heart.text.square.fill"]
        let heroGradients: [[Color]] = [
            [.orange, .pink.opacity(0.74)],
            [.purple.opacity(0.94), .blue.opacity(0.76)],
            [.pink.opacity(0.92), .orange.opacity(0.76)]
        ]
        return VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(heroEyebrows[heroVariant])
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.72))
                    Text(heroTitles[heroVariant])
                        .font(.system(size: 31, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineSpacing(-3)
                }
                Spacer()
                Image(systemName: heroIcons[heroVariant])
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            }

            let metrics = [
                ("\(vm.recipes.count)", "recipes in your cookbook", "book.closed.fill"),
                ("\(vm.recipes.filter(\.isFavorite).count)", "favorites worth repeating", "heart.fill"),
                ("\(vm.recipes.filter(\.hasBeenCooked).count)", "recipes cooked", "flame.fill"),
                (discoverySnapshot.dominantCuisine ?? "Exploring", "current flavor lane", "globe.americas.fill")
            ]
            let metric = metrics[recipeHeroMetricIndex % metrics.count]
            HStack(spacing: 13) {
                Image(systemName: metric.2)
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.14), in: Circle())
                recipeHeaderMetric(value: metric.0, label: metric.1)
            }
            .id(recipeHeroMetricIndex)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        .padding(21)
        .background(
            LinearGradient(colors: heroGradients[heroVariant], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .shadow(color: .orange.opacity(0.20), radius: 18, y: 9)
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    private func recipeHeaderMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
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

    private var pantryDiscoverySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    Image(systemName: "basket.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.green)
                        .frame(width: 44, height: 44)
                        .background(Color.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("PANTRY-POWERED")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(.green)
                        Text("From Your Pantry")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    SectionInfoButton(tint: .green) {
                        infoSheet = RecipesInfoSheet(
                            title: "From Your Pantry",
                            message: "These ideas are generated from the ingredients in your currently active pantry, so they should feel more grounded in what you actually have on hand."
                        )
                    }
                }

                Text(
                    currentPantry == nil
                    ? "Pick a pantry in the Pantry tab to unlock ingredient-aware recipe ideas."
                    : "Ideas generated from what’s currently stocked in \(currentPantry?.name ?? "your pantry")."
                )
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if pantrySpaces.count > 1 {
                        Menu {
                            ForEach(pantrySpaces) { pantry in
                                Button {
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
                            HStack(spacing: 6) {
                                Text(currentPantry.map { "\($0.emoji) \($0.name)" } ?? "Select Pantry")
                                    .fixedSize(horizontal: true, vertical: false)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                    } else if let pantry = currentPantry {
                        Text("\(pantry.emoji) \(pantry.name)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }

                    Spacer()

                    if let pantry = currentPantry, pantry.ingredients.isEmpty == false {
                        Button {
                            refreshSelectedPantrySuggestions(pantry)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .background(Color.green.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isGeneratingFromPantry)
                    }
                }
            }
            .padding(.horizontal, 20)

            if pantrySpaces.isEmpty {
                DiscoveryMessageCard(
                    title: "No pantry linked yet",
                    subtitle: "Open Pantry to create a space and add ingredients before asking ChefBuddy for pantry-based recipe ideas.",
                    icon: "basket"
                )
                .padding(.horizontal, 16)
            } else if currentPantry?.ingredients.isEmpty ?? true {
                DiscoveryMessageCard(
                    title: "\(currentPantry?.name ?? "This pantry") is still empty",
                    subtitle: "Scan a shelf or add ingredients manually in Pantry, then come back here for smarter pantry-first ideas.",
                    icon: "camera.viewfinder"
                )
                .padding(.horizontal, 16)
            } else if isGeneratingFromPantry && currentPantrySuggestions.isEmpty {
                PantryRecipeLoadingView()
                    .padding(.horizontal, 16)
            } else if !currentPantrySuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(currentPantrySuggestions) { suggestion in
                            PantryRecipeCard(recipe: suggestion) {
                                selectedPantrySuggestionRecipe = recipeFromSuggestion(suggestion)
                            }
                        }

                        if isGeneratingFromPantry {
                            PantryCardLoadingView()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            } else if let pantry = currentPantry {
                Button(action: { generateFromSelectedPantry(pantry) }) {
                    Label("Generate ideas from \(pantry.name)", systemImage: "sparkles")
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
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [Color.green.opacity(0.11), Color.primary.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 27, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(Color.green.opacity(0.16), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(width: 44, height: 44)
                        .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("PERSONALIZED FOR YOU")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(.orange)
                        Text("ChefBuddy Picks")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    SectionInfoButton(tint: .orange) {
                        infoSheet = RecipesInfoSheet(
                            title: "ChefBuddy Picks",
                            message: "These are broader AI recipe ideas tuned to your preferences and cooking behavior, while Swipe Discovery gives you a dedicated place to train ChefBuddy more directly."
                        )
                    }
                }

                HStack {
                    Text("Broader ideas shaped by your preferences, saves, skips, and cooking history.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        Task { await loadChefBuddyPicks(force: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingChefBuddyPicks)
                }
            }
            .padding(.horizontal, 20)

            if isLoadingChefBuddyPicks && chefBuddyPicks.isEmpty {
                SuggestionsLoadingSection()
            } else if !chefBuddyPicks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(chefBuddyPicks) { suggestion in
                            let suggestionRecipe = recipeFromSuggestion(suggestion)

                            RecipeCard(
                                recipe: suggestionRecipe,
                                onTap: { selectedSuggestionRecipe = suggestionRecipe },
                                onFavorite: { },
                                showFavorite: false
                            )
                            .frame(width: 180)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                DiscoveryMessageCard(
                    title: "No fresh picks yet",
                    subtitle: "ChefBuddy is refreshing picks automatically in the background. Swipe Discovery is ready while it updates.",
                    icon: "sparkles"
                )
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [Color.orange.opacity(0.11), Color.primary.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 27, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(Color.orange.opacity(0.16), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private var spotlightSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create & Discover")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .padding(.horizontal, 4)

            VStack(spacing: 12) {
                FeaturedRecipeActionCard(
                    title: "Generate Any Recipe",
                    subtitle: "Describe a craving, dish, or cuisine and ChefBuddy will build a full recipe from scratch.",
                    icon: "wand.and.stars",
                    tint: [.orange, .green.opacity(0.85)],
                    statusText: vm.isGenerating ? "ChefBuddy is cooking" : "Main creation flow",
                    footnote: vm.isGenerating ? "Your recipe is building right now." : "Best for specific cravings, dishes, and weeknight what-ifs.",
                    actionLabel: vm.isGenerating ? "Generating..." : "Create Recipe",
                    isLoading: vm.isGenerating,
                    loadingStep: vm.elapsedSeconds
                ) {
                    showGenerateSheet = true
                }

                HStack(spacing: 12) {
                    SupportingRecipeActionCard(
                        title: "Swipe Discovery",
                        subtitle: "Teach ChefBuddy your taste fast.",
                        icon: "rectangle.stack.badge.person.crop",
                        tint: [.orange, .green.opacity(0.84)],
                        badgeText: isLoadingSwipeDiscoveryDeck && swipeDiscoveryDeck.isEmpty ? "Building deck" : "\(max(swipeDiscoveryDeck.count, 10)) ready",
                        helperText: discoverySnapshot.highlightPills.prefix(2).joined(separator: " • "),
                        isLoading: isLoadingSwipeDiscoveryDeck && swipeDiscoveryDeck.isEmpty,
                        loadingStep: swipeDiscoveryActionStep
                    ) {
                        openSwipeDiscovery()
                    }

                    SupportingRecipeActionCard(
                        title: "Create Custom Recipe",
                        subtitle: "Turn your own idea into a saved card.",
                        icon: "square.and.pencil",
                        tint: [Color(red: 0.39, green: 0.43, blue: 0.96), Color(red: 0.23, green: 0.68, blue: 0.90)],
                        badgeText: "Recipe Studio",
                        helperText: "Great for family recipes and meal-prep staples."
                    ) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showCustomRecipeSheet = true
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var recipesGridSection: some View {
        Group {
            if vm.filteredRecipes.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Your Recipes")
                            .font(.system(size: 20, weight: .bold, design: .rounded))

                        SectionInfoButton {
                            infoSheet = RecipesInfoSheet(
                                title: "Your Recipes",
                                message: "This is your saved recipe library. Filters here only affect recipes you have saved, not the discovery sections above."
                            )
                        }

                        Spacer()
                    }
                        .padding(.horizontal, 20)

                    filterBar

                    RecipesEmptyState(filter: vm.selectedFilter) {
                        showGenerateSheet = true
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {

                    HStack {
                        Text("Your Recipes")
                            .font(.system(size: 20, weight: .bold, design: .rounded))

                        SectionInfoButton {
                            infoSheet = RecipesInfoSheet(
                                title: "Your Recipes",
                                message: "This is your saved recipe library. Filters here only affect recipes you’ve saved, not the AI discovery sections above."
                            )
                        }

                        Spacer()

                        if vm.filteredRecipes.count > 4 {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showAllRecipesScreen = true
                            } label: {
                                Text("See More")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)

                    filterBar

                    VStack(alignment: .leading, spacing: 18) {
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 14
                        ) {
                            ForEach(vm.previewRecipes) { recipe in
                                RecipeCard(
                                    recipe: recipe,
                                    onTap: { selectedRecipe = recipe },
                                    onFavorite: { toggleFavoriteEverywhere(recipe) },
                                    isCooked: recipe.hasBeenCooked
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }
}


struct RecipeBouncingDotsView: View {
    let step: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index <= (step % 3) ? color : color.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .offset(y: index == (step % 3) ? -2 : 0)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }
}


struct RecipeCard: View {
    let recipe: Recipe
    let onTap: () -> Void
    let onFavorite: () -> Void
    var isCooked: Bool = false
    var showFavorite: Bool = true

    var difficultyColor: Color {
        switch recipe.difficulty.lowercased() {
        case "easy":
            return .green
        case "hard":
            return .red
        default:
            return .orange
        }
    }

    private var cookedHistoryText: String? {
        guard recipe.hasBeenCooked else { return nil }
        let dateText = recipe.lastCookedAt.map { Self.lastCookedFormatter.string(from: $0) } ?? "unknown"
        return "Cooked \(recipe.cookedCount)x • Last: \(dateText)"
    }

    private var addedHistoryText: String {
        "Added \(Self.createdAtFormatter.string(from: recipe.createdAt))"
    }

    private var cuisineTag: String {
        detectedCuisineTag(title: recipe.title, description: recipe.description, tags: recipe.tags)
    }

    private static let lastCookedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let createdAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTap()
        }) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(
                        colors: [Color.orange.opacity(0.12), Color.green.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    Text(recipe.emoji)
                        .font(.system(size: 52))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(y: -2)

                    if showFavorite {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onFavorite()
                        }) {
                            Image(systemName: recipe.isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(recipe.isFavorite ? .red : .secondary)
                                .padding(7)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if isCooked {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Previously Cooked")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.85))
                            .clipShape(Capsule())
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "circle")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Not Cooked")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(Color.primary.opacity(0.92))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.14))
                            .overlay(
                                Capsule()
                                    .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                            )
                            .clipShape(Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 16)

                    Text(recipe.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 54, alignment: .topLeading)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(recipe.cookTime)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(recipe.difficulty)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(difficultyColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(difficultyColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .foregroundStyle(.secondary)
                    .frame(height: 20)

                    Text(recipe.calories.isEmpty ? "— kcal per serving" : "\(recipe.calories) per serving")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .frame(height: 18, alignment: .leading)

                    HStack {
                        Text(cuisineTag)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 0)
                    }
                    .frame(height: 22)

                    Text(cookedHistoryText ?? addedHistoryText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 12, alignment: .topLeading)
                }
                .padding(12)
            }
            .frame(height: 288)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isCooked ? Color.green.opacity(0.28) : Color.primary.opacity(0.05), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(RecipeCardButtonStyle())
    }
}

struct RecipeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

private struct FeaturedRecipeActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: [Color]
    let statusText: String
    let footnote: String
    let actionLabel: String
    var isLoading: Bool = false
    var loadingStep: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [tint.first?.opacity(0.22) ?? .orange.opacity(0.22), tint.last?.opacity(0.18) ?? .green.opacity(0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 58, height: 58)

                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(tint.first ?? .orange)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Main Action")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(tint.first ?? .orange)
                        Text(title)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(tint.first ?? .orange)
                    }

                    Text(statusText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(tint.first ?? .orange)

                    if isLoading {
                        RecipeBouncingDotsView(step: loadingStep, color: tint.first ?? .orange)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.06), in: Capsule())

                Text(footnote)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text(actionLabel)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: tint,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.05), tint.last?.opacity(0.10) ?? Color.green.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading && title == "Generate Any Recipe")
    }
}

private struct SupportingRecipeActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: [Color]
    let badgeText: String
    let helperText: String
    var isLoading: Bool = false
    var loadingStep: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [tint.first?.opacity(0.22) ?? .orange.opacity(0.22), tint.last?.opacity(0.18) ?? .green.opacity(0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 46, height: 46)

                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(tint.first ?? .orange)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(tint.first ?? .orange)
                        }

                        Text(badgeText)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(tint.first ?? .orange)

                        if isLoading {
                            RecipeBouncingDotsView(step: loadingStep, color: tint.first ?? .orange)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Text(helperText.isEmpty ? "Open" : helperText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint.first ?? .orange)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 192, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.04), tint.last?.opacity(0.10) ?? Color.green.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct GenerateRecipeSpotlightCard: View {
    let onTap: () -> Void
    var isGenerating: Bool = false
    var step: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.orange.opacity(0.95), .green.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Generate Any Recipe")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Describe any dish, cuisine, or craving and ChefBuddy will build it.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            if isGenerating {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)

                    Text("ChefBuddy is cooking")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    RecipeBouncingDotsView(step: step, color: .white)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .padding(.horizontal, 14)
                .background(
                    LinearGradient(
                        colors: [.orange, .green.opacity(0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
            } else {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onTap()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 14, weight: .bold))
                        Text("Create Recipe")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        LinearGradient(
                            colors: [.orange, .green.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }
}

private struct RecipesInfoSheet: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct SectionInfoButton: View {
    var tint: Color = .orange
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 31, height: 31)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(tint.opacity(0.24), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("How this section works")
    }
}

struct InfoMessageSheet: View {
    let title: String
    let message: String
    @Environment(\.dismiss) private var dismiss

    private var tint: Color {
        title == "From Your Pantry" ? .green : .orange
    }

    private var icon: String {
        switch title {
        case "From Your Pantry": return "basket.fill"
        case "Your Recipes": return "book.closed.fill"
        default: return "sparkles"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 13) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("HOW IT WORKS")
                                        .font(.system(size: 10, weight: .black, design: .rounded))
                                        .tracking(1)
                                        .foregroundStyle(.white.opacity(0.72))
                                    Text(title)
                                        .font(.system(size: 29, weight: .heavy, design: .rounded))
                                        .foregroundStyle(.white)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer()

                                Image(systemName: icon)
                                    .font(.system(size: 25, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 50, height: 50)
                                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                            }

                            Text(message)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.84))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(17)
                        .background(
                            LinearGradient(
                                colors: [tint.opacity(0.94), tint.opacity(0.56), Color.black.opacity(0.26)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 27, style: .continuous)
                        )

                        VStack(spacing: 8) {
                            infoRow(
                                icon: title == "From Your Pantry" ? "basket.fill" : "person.crop.circle.badge.checkmark",
                                title: title == "From Your Pantry" ? "What it uses" : "What shapes your picks",
                                detail: title == "From Your Pantry"
                                    ? "The ingredients inside your currently selected pantry space."
                                    : "Preferences, saved recipes, cooking history, and discovery decisions."
                            )
                            infoRow(
                                icon: "wand.and.stars",
                                title: "What ChefBuddy does",
                                detail: title == "From Your Pantry"
                                    ? "Builds recipe concepts around stocked ingredients while respecting your profile."
                                    : "Creates a broader set of ideas that should evolve as your taste signals grow."
                            )
                            infoRow(
                                icon: "hand.raised.fill",
                                title: "You stay in control",
                                detail: title == "From Your Pantry"
                                    ? "Switch the active pantry or refresh whenever the ingredients change."
                                    : "Save what works, skip what does not, and refresh whenever you want a new direction."
                            )
                        }

                        Button {
                            dismiss()
                        } label: {
                            Label("Got It", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(tint, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.fraction(0.72)])
        .presentationDragIndicator(.visible)
    }

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        )
    }
}


private struct SuggestionsLoadingSection: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.8)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 2.2) % 9
            let phases = [
                ("heart.text.square.fill", "Learning your taste", "Reading saves, skips, cuisines, and cooking habits."),
                ("book.closed.fill", "Checking your cookbook", "Avoiding ideas that feel too similar to recent saves."),
                ("sparkles", "Curating your picks", "Mixing familiar favorites with a few useful surprises."),
                ("flame.fill", "Balancing cook time", "Keeping the picks realistic for everyday cooking."),
                ("leaf.fill", "Adding pantry awareness", "Looking for ideas that can connect back to what you stock."),
                ("globe.americas.fill", "Varying cuisines", "Making the rail feel fresher than the last one."),
                ("timer", "Checking pace", "Matching meals to quick wins and slower projects."),
                ("fork.knife.circle.fill", "Building complete cards", "Filling in calories, tags, and useful details."),
                ("checkmark.seal.fill", "Quality-checking ideas", "Avoiding repeats and finishing complete recipe cards.")
            ]

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.orange.opacity(0.22), .pink.opacity(0.13)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 58, height: 58)
                        Image(systemName: phases[phase].0)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.orange)
                            .contentTransition(.symbolEffect(.replace))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Personalizing ChefBuddy Picks")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                        Text(phases[phase].1)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    RecipeBouncingDotsView(step: phase, color: .orange)
                }

                Text(phases[phase].2)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Label("Fresh picks are almost ready", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(
                LinearGradient(
                    colors: [Color.primary.opacity(0.045), Color.orange.opacity(0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.orange.opacity(0.20), lineWidth: 1)
            )
            .padding(.horizontal, 16)
        }
    }
}

private struct DiscoveryMessageCard: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct SwipeDiscoveryEntryCard: View {
    let pills: [String]
    let readyCount: Int
    let isLoading: Bool
    let onTap: () -> Void

    private var statusLabel: String {
        if isLoading && readyCount == 0 {
            return "Building your swipe deck"
        }
        return "Open Swipe Discovery"
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Swipe Discovery")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Train ChefBuddy with quick save-or-skip decisions and keep the discovery feed learning from your cooking style.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineSpacing(3)
                    }

                    Spacer(minLength: 12)

                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 48, height: 48)

                        Image(systemName: "rectangle.stack.badge.person.crop")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                if !pills.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(pills.prefix(3)), id: \.self) { pill in
                            Text(pill)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.14), in: Capsule())
                        }
                    }
                }

                HStack {
                    HStack(spacing: 8) {
                        if isLoading && readyCount == 0 {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }

                        Text(statusLabel)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.96), in: Capsule())

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.94))
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
            }
            .padding(20)
            .background(
                LinearGradient(
                    colors: [Color.orange.opacity(0.96), Color.green.opacity(0.84)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .orange.opacity(0.18), radius: 14, y: 8)
        }
        .buttonStyle(.plain)
    }
}

private enum SwipeDeckFeedbackKind: Equatable {
    case saved
    case skipped

    var icon: String {
        switch self {
        case .saved:
            return "heart.fill"
        case .skipped:
            return "xmark"
        }
    }

    var title: String {
        switch self {
        case .saved:
            return "That’s a match"
        case .skipped:
            return "Passed for now"
        }
    }

    var subtitle: String {
        switch self {
        case .saved:
            return "Saved to your recipe list."
        case .skipped:
            return "ChefBuddy will steer away from this vibe."
        }
    }

    var accent: Color {
        switch self {
        case .saved:
            return .green
        case .skipped:
            return .red
        }
    }
}

private struct SwipeDiscoveryLoadingSection: View {
    var body: some View {
        VStack(spacing: 28) {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.orange.opacity(0.28), Color.purple.opacity(0.08), .clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 125
                            )
                        )
                        .frame(width: 250, height: 250)
                        .scaleEffect(1 + (sin(phase * 1.8) * 0.04))

                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [.orange, .yellow, .green, .purple, .orange],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [24, 12])
                        )
                        .frame(width: 158, height: 158)
                        .rotationEffect(.radians(phase * 0.7))

                    ForEach(Array(["leaf.fill", "flame.fill", "clock.fill"].enumerated()), id: \.offset) { index, icon in
                        let angle = phase * 0.72 + (Double(index) * (.pi * 2 / 3))
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(index == 0 ? .green : index == 1 ? .orange : .purple)
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                            .offset(x: cos(angle) * 96, y: sin(angle) * 96)
                    }

                    VStack(spacing: 8) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 35, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolEffect(.pulse)
                        Text("MADE FOR YOU")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(1.1)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .frame(width: 126, height: 126)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                }
                .frame(height: 264)
            }

            VStack(spacing: 9) {
                Text("Setting the table")
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                Text("Matching your tastes, pantry, and recent choices.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ProgressView()
                .tint(.orange)
                .controlSize(.regular)
        }
        .padding(.vertical, 30)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
    }

    private func loadingStatusPill(text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color.opacity(0.95))
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05), in: Capsule())
    }

    private func loadingPreviewCard(height: CGFloat, widthInset: CGFloat, tilt: Double, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .padding(.horizontal, widthInset)
            .rotationEffect(.degrees(tilt))
    }

    private func loadingPrimaryPreview(step: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 48, height: 48)

                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1.2)
                        .frame(width: 62, height: 62)
                        .scaleEffect(step.isMultiple(of: 2) ? 1.0 : 1.05)

                    Text("🍽️")
                        .font(.system(size: 26))
                        .scaleEffect(step.isMultiple(of: 2) ? 1.0 : 1.08)
                        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: step)
                }

                    VStack(alignment: .leading, spacing: 6) {
                    Text("Your next plate is almost ready")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("The deck stays loaded while you browse, so once this stack lands you can keep swiping without waiting.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                loadingMetric(title: "20 mins", accent: .orange)
                loadingMetric(title: "410 kcal", accent: .yellow)
                loadingMetric(title: "Easy", accent: .green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 138)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.11, green: 0.11, blue: 0.13))

                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.88), Color(red: 0.48, green: 0.76, blue: 0.36)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 34)
    }

    private func loadingMetric(title: String, accent: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accent.opacity(0.95))
                .frame(width: 8, height: 8)

            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.16), in: Capsule())
    }
}

private struct SwipeDiscoveryScreen: View {
    let suggestions: [RecipeSuggestion]
    let behaviorSnapshot: DiscoveryBehaviorSnapshot
    let isLoadingInitial: Bool
    let isLoadingMore: Bool
    let errorMessage: String?
    let onDismiss: () -> Void
    let onRefresh: () -> Void
    let onSave: (RecipeSuggestion) -> Void
    let onSkip: (RecipeSuggestion) -> Void

    @State private var showInfo = false
    @State private var animateHeader = false
    @State private var hasRequestedAutomaticRefill = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ChefBuddyBackground()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.primary)
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button(action: onRefresh) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.orange)
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)

                        Button(action: { showInfo = true }) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 23, weight: .bold))
                                .foregroundStyle(.orange)
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("FOR YOU")
                                .font(.system(size: 10, weight: .black, design: .rounded))
                                .tracking(1)
                                .foregroundStyle(.orange)
                            Text("Find your\nnext favorite.")
                                .font(.system(size: 29, weight: .heavy, design: .rounded))
                                .lineSpacing(-3)
                        }
                        Spacer()
                        VStack(spacing: 4) {
                            Image(systemName: "hand.draw.fill")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.orange)
                                .offset(y: animateHeader ? -2 : 2)
                            Text("SWIPE")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 54, height: 54)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    Text("One tailored plate at a time. Tap for details, swipe to shape what comes next.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)

                    if suggestions.isEmpty {
                        if let errorMessage {
                            discoveryStateCard(
                                icon: "sparkles.rectangle.stack.fill",
                                title: "Discovery needs another try",
                                subtitle: errorMessage,
                                actionTitle: "Try Again",
                                action: onRefresh
                            )
                        } else {
                            SwipeDiscoveryLoadingSection()
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                    } else {
                        if isLoadingMore {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.orange)

                                Text("ChefBuddy is already sliding the next plate into your stack.")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                        }

                        SwipeDiscoveryDeckView(
                            suggestions: suggestions,
                            behaviorSnapshot: behaviorSnapshot,
                            isLoadingMore: isLoadingMore,
                            cardHeight: min(max(geometry.size.height * 0.64, 470), 640),
                            onSave: onSave,
                            onSkip: onSkip
                        )
                        .frame(maxHeight: .infinity, alignment: .center)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 18)
            }
        }
        .sheet(isPresented: $showInfo) {
            InfoMessageSheet(
                title: "Swipe Discovery",
                message: "Swipe right to save, left to skip, and tap any card to flip it for the full recipe. ChefBuddy learns from what you save, cook, and skip, while still mixing in fresh cuisines so discovery stays interesting."
            )
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                animateHeader = true
            }
            requestAutomaticRefillIfNeeded()
        }
        .onChange(of: suggestions.count) { _, newCount in
            if newCount > 0 {
                hasRequestedAutomaticRefill = false
            } else {
                requestAutomaticRefillIfNeeded()
            }
        }
    }

    private func requestAutomaticRefillIfNeeded() {
        guard suggestions.isEmpty,
              !isLoadingInitial,
              !isLoadingMore,
              errorMessage == nil,
              hasRequestedAutomaticRefill == false else { return }
        hasRequestedAutomaticRefill = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onRefresh()
        }
    }

    private func discoveryStateCard(
        icon: String,
        title: String,
        subtitle: String,
        actionTitle: String,
        action: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: 76, height: 76)
                .background(Color.orange.opacity(0.12), in: Circle())

            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.top, 24)
    }
}

private struct SwipeDiscoveryDeckView: View {
    let suggestions: [RecipeSuggestion]
    let behaviorSnapshot: DiscoveryBehaviorSnapshot
    let isLoadingMore: Bool
    let cardHeight: CGFloat
    let onSave: (RecipeSuggestion) -> Void
    let onSkip: (RecipeSuggestion) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var exitOffset: CGSize = .zero
    @State private var flippedCardTitle: String? = nil
    @State private var feedbackKind: SwipeDeckFeedbackKind? = nil
    @State private var isCommittingSwipe = false

    private var topSuggestions: [RecipeSuggestion] {
        Array(suggestions.prefix(3))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .top) {
                ForEach(Array(topSuggestions.enumerated().reversed()), id: \.element.id) { index, suggestion in
                    let isTopCard = index == 0
                    let isFlipped = flippedCardTitle == normalizedTitle(for: suggestion)

                    DiscoverySwipeCard(
                        suggestion: suggestion,
                        behaviorSnapshot: behaviorSnapshot,
                        dragOffset: isTopCard ? activeOffset : .zero,
                        isTopCard: isTopCard,
                        isFlipped: isFlipped
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .onTapGesture {
                        guard isTopCard else { return }
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                            flippedCardTitle = isFlipped ? nil : normalizedTitle(for: suggestion)
                        }
                    }
                    .simultaneousGesture(
                        isTopCard && !isFlipped ? dragGesture(for: suggestion) : nil
                    )
                    .scaleEffect(1 - (CGFloat(index) * 0.05))
                    .offset(
                        x: isTopCard ? activeOffset.width : 0,
                        y: CGFloat(index) * 14 + (isTopCard ? max(-8, min(8, activeOffset.height * 0.04)) : 0)
                    )
                    .rotationEffect(isTopCard ? .degrees(Double(activeOffset.width / 32)) : .zero)
                    .shadow(color: Color.black.opacity(index == 0 ? 0.2 : 0.08), radius: 18, y: 12)
                }

                if let feedbackKind {
                    SwipeDeckFeedbackBanner(kind: feedbackKind)
                        .padding(.top, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            HStack(spacing: 14) {
                deckActionButton(label: "Pass", icon: "xmark", accent: .red.opacity(0.88)) {
                    if let top = suggestions.first {
                        completeSwipe(for: top, direction: .left)
                    }
                }

                deckActionButton(label: "Save", icon: "heart.fill", accent: .green.opacity(0.92)) {
                    if let top = suggestions.first {
                        completeSwipe(for: top, direction: .right)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .frame(height: cardHeight)
        .onChange(of: suggestions.first?.title) { _ in
            exitOffset = .zero
            dragOffset = .zero
            isCommittingSwipe = false
        }
    }

    private var activeOffset: CGSize {
        if exitOffset != .zero {
            return exitOffset
        }
        return dragOffset
    }

    private enum SwipeDirection {
        case left
        case right
    }

    private func normalizedTitle(for suggestion: RecipeSuggestion) -> String {
        suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func dragGesture(for suggestion: RecipeSuggestion) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard !isCommittingSwipe else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                let projectedWidth = value.predictedEndTranslation.width
                let finalWidth = (value.translation.width * 0.72) + (projectedWidth * 0.28)

                if finalWidth > 92 {
                    completeSwipe(for: suggestion, direction: .right)
                } else if finalWidth < -92 {
                    completeSwipe(for: suggestion, direction: .left)
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func completeSwipe(for suggestion: RecipeSuggestion, direction: SwipeDirection) {
        guard !isCommittingSwipe else { return }
        isCommittingSwipe = true
        let targetX = direction == .right ? UIScreen.main.bounds.width : -UIScreen.main.bounds.width

        withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.88, blendDuration: 0.10)) {
            exitOffset = CGSize(width: targetX, height: 8)
        }

        switch direction {
        case .left:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                feedbackKind = .skipped
            }
        case .right:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                feedbackKind = .saved
            }
        }

        flippedCardTitle = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            switch direction {
            case .left:
                onSkip(suggestion)
            case .right:
                onSave(suggestion)
            }

            exitOffset = .zero
            dragOffset = .zero
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.22)) {
                feedbackKind = nil
            }
        }
    }

    private func deckActionButton(label: String, icon: String, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .black))
                Text(label)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                LinearGradient(colors: [accent, accent.opacity(0.70)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: accent.opacity(0.24), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
    }
}

private struct DiscoverySwipeCard: View {
    let suggestion: RecipeSuggestion
    let behaviorSnapshot: DiscoveryBehaviorSnapshot
    let dragOffset: CGSize
    let isTopCard: Bool
    let isFlipped: Bool

    @State private var animateOrb = false

    private var cuisine: String {
        primaryCuisineTag(for: suggestion.tags, title: suggestion.title, description: suggestion.description)
    }

    private var discoveryModeLabel: String {
        if behaviorSnapshot.favoriteCuisines.contains(cuisine) {
            return "Comfort Pick"
        }
        if let dominant = behaviorSnapshot.dominantCuisine, dominant != cuisine {
            return "Fresh Lane"
        }
        return "ChefBuddy Pick"
    }

    private var shortHook: String {
        compactText(from: suggestion.description, maxLength: 62, fallback: "A quick plate tuned to your vibe.")
    }

    private var fullHook: String {
        compactText(from: suggestion.description, maxLength: 240, fallback: "ChefBuddy built this recipe to fit your current cooking style.")
    }

    private var visibleTags: [String] {
        Array(
            suggestion.tags
                .filter { $0.caseInsensitiveCompare(cuisine) != .orderedSame }
                .prefix(2)
        )
    }

    private var swipeLabel: String? {
        if dragOffset.width > 30 {
            return "SAVE"
        }
        if dragOffset.width < -30 {
            return "SKIP"
        }
        return nil
    }

    private var swipeColor: Color {
        dragOffset.width >= 0 ? .green : .red
    }

    private var compactServings: String {
        let raw = suggestion.servings.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "1 srv" }

        if let number = raw.split(separator: " ").first, Int(number) != nil {
            let numeric = String(number)
            let suffix = "srv"
            return "\(numeric) \(suffix)"
        }

        if raw.localizedCaseInsensitiveContains("person") {
            return raw.replacingOccurrences(of: "person", with: "serving", options: .caseInsensitive)
                .replacingOccurrences(of: "people", with: "servings", options: .caseInsensitive)
        }

        return raw
    }

    private var shareRecipe: Recipe {
        Recipe(
            title: suggestion.title,
            emoji: suggestion.emoji,
            description: suggestion.description,
            ingredients: suggestion.ingredients,
            steps: suggestion.steps,
            cookTime: suggestion.prepTime,
            servings: suggestion.servings,
            difficulty: suggestion.difficulty,
            tags: suggestion.tags,
            calories: suggestion.calories,
            nutrition: suggestion.nutrition
        )
    }

    private var flavorNotes: [(icon: String, label: String)] {
        let source = "\(suggestion.description) \(suggestion.matchReason) \(suggestion.tags.joined(separator: " "))".lowercased()
        var notes: [(String, String)] = []

        func append(_ icon: String, _ label: String, ifAny keywords: [String]) {
            guard notes.count < 3 else { return }
            guard keywords.contains(where: { source.contains($0) }) else { return }
            guard notes.contains(where: { $0.1 == label }) == false else { return }
            notes.append((icon, label))
        }

        append("sun.max.fill", "Bright", ifAny: ["lime", "lemon", "zesty", "fresh", "citrus", "herb"])
        append("flame.fill", "Spiced", ifAny: ["spicy", "heat", "chili", "curry", "pepper"])
        append("drop.fill", "Creamy", ifAny: ["creamy", "yogurt", "coconut", "buttery"])
        append("fork.knife", "Savory", ifAny: ["savory", "umami", "garlic", "toasted"])
        append("heart.fill", "Comforting", ifAny: ["comfort", "cozy", "hearty", "warm"])
        append("leaf.fill", "Fresh", ifAny: ["greens", "fresh", "crisp", "salad", "garden"])
        append("sparkles", "Balanced", ifAny: ["balanced", "high protein", "healthy", "light"])

        while notes.count < 3 {
            let fallbacks: [(String, String)] = [("fork.knife", "Savory"), ("sparkles", "Balanced"), ("heart.fill", "Comforting")]
            if let next = fallbacks.first(where: { fallback in notes.contains(where: { $0.1 == fallback.1 }) == false }) {
                notes.append(next)
            } else {
                break
            }
        }

        return Array(notes.prefix(3))
    }

    private var frontGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.15, green: 0.08, blue: 0.24),
                Color(red: 0.27, green: 0.13, blue: 0.38),
                Color(red: 0.08, green: 0.24, blue: 0.35)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            frontFace
                .opacity(isFlipped ? 0 : 1)
                .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))

            backFace
                .opacity(isFlipped ? 1 : 0)
                .rotation3DEffect(.degrees(isFlipped ? 0 : -180), axis: (x: 0, y: 1, z: 0))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.12))

                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(frontGradient)
                    .opacity(0.98)

                Circle()
                    .fill(Color.orange.opacity(0.20))
                    .frame(width: 220, height: 220)
                    .blur(radius: 55)
                    .offset(x: -92, y: -118)

                Circle()
                    .fill(Color.blue.opacity(0.24))
                    .frame(width: 240, height: 240)
                    .blur(radius: 60)
                    .offset(x: 118, y: 134)

                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.18), .clear, Color.black.opacity(0.24)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(Color.white.opacity(isTopCard ? 0.14 : 0.08), lineWidth: 1)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(Color.white.opacity(isTopCard ? 0.12 : 0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .animation(.spring(response: 0.46, dampingFraction: 0.84), value: isFlipped)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                animateOrb = true
            }
        }
    }

    private var frontFace: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(discoveryModeLabel)
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.12), in: Capsule())

                        if let swipeLabel {
                            Text(swipeLabel)
                                .font(.system(size: 12, weight: .black, design: .rounded))
                                .foregroundStyle(swipeColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.94), in: Capsule())
                        }
                    }

                    Text(suggestion.title)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.82)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(shortHook)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 96, height: 96)
                        .scaleEffect(animateOrb ? 1.04 : 0.96)

                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [.white.opacity(0.0), .white.opacity(0.55), .white.opacity(0.0)],
                                center: .center
                            ),
                            lineWidth: 2.2
                        )
                        .frame(width: 92, height: 92)
                        .rotationEffect(.degrees(animateOrb ? 360 : 0))

                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1.2)
                        .frame(width: 78, height: 78)

                    Text(suggestion.emoji)
                        .font(.system(size: 43))

                    Circle()
                        .fill(Color.orange.opacity(0.9))
                        .frame(width: 8, height: 8)
                        .offset(x: 34, y: -28)
                        .opacity(animateOrb ? 0.9 : 0.45)

                    Circle()
                        .fill(Color.blue.opacity(0.9))
                        .frame(width: 10, height: 10)
                        .offset(x: -32, y: 26)
                        .opacity(animateOrb ? 0.42 : 0.92)
                }
            }

            HStack(spacing: 9) {
                DiscoveryStatPill(icon: "globe.americas.fill", label: cuisine)
                DiscoveryStatPill(icon: "clock.fill", label: suggestion.prepTime)
                DiscoveryStatPill(icon: "sparkles", label: suggestion.difficulty)
            }

            if !suggestion.matchReason.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WHY THIS ONE")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.65))
                        Text(compactText(from: suggestion.matchReason, maxLength: 110, fallback: "A balanced match for your kitchen."))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineSpacing(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(15)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
            }

            Spacer(minLength: 0)

            HStack {
                Label("Tap for full recipe", systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Text("Swipe to choose")
            }
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.68))
        }
        .padding(22)
        .padding(.bottom, 76)
    }

    private var backFace: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("RECIPE DETAILS", systemImage: "book.pages.fill")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(0.8)
                    Spacer()
                    Label("Scroll to explore", systemImage: "arrow.down")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.64))

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(suggestion.title)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(fullHook)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 8) {
                            RecipeShareButton(recipe: shareRecipe)

                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.10))
                                    .frame(width: 58, height: 58)

                                Text(suggestion.emoji)
                                    .font(.system(size: 30))
                            }
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    DiscoveryNutritionTile(title: "Calories", value: suggestion.calories, accent: .orange)
                    DiscoveryNutritionTile(title: "Protein", value: suggestion.protein, accent: .green)
                    DiscoveryNutritionTile(title: "Carbs", value: suggestion.carbs, accent: .blue)
                    DiscoveryNutritionTile(title: "Fat", value: suggestion.fat, accent: .pink)
                }

                HStack(spacing: 8) {
                    DiscoveryStatPill(icon: "clock.fill", label: suggestion.prepTime)
                    DiscoveryStatPill(icon: "person.2.fill", label: compactServings)
                    DiscoveryStatPill(icon: "globe.americas.fill", label: cuisine)
                }

                DiscoveryBackSection(title: "Tastes like", icon: "sparkles") {
                    HStack(spacing: 10) {
                        ForEach(Array(flavorNotes.enumerated()), id: \.offset) { _, note in
                            HStack(spacing: 7) {
                                Image(systemName: note.icon)
                                    .font(.system(size: 11, weight: .bold))
                                Text(note.label)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                }

                if !suggestion.matchReason.isEmpty {
                    DiscoveryBackSection(title: "Why it fits", icon: "sparkles") {
                        Text(suggestion.matchReason)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                DiscoveryBackSection(title: "Ingredients", icon: "carrot.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(suggestion.ingredients.enumerated()), id: \.offset) { _, ingredient in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .padding(.top, 6)

                                Text(preferredIngredientText(ingredient))
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                DiscoveryBackSection(title: "Steps", icon: "list.number") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(suggestion.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .black, design: .rounded))
                                    .foregroundStyle(.indigo)
                                    .frame(width: 24, height: 24)
                                    .background(Color.white.opacity(0.95), in: Circle())

                                Text(step)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
            }
            .padding(24)
            .padding(.bottom, 74)
        }
    }

    private func compactText(from raw: String, maxLength: Int, fallback: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return fallback }
        guard cleaned.count > maxLength else { return cleaned }

        let prefix = String(cleaned.prefix(maxLength))
        if let split = prefix.lastIndex(of: " ") {
            return String(prefix[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func frontHintPill(icon: String, label: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.10), in: Capsule())
    }
}

private struct SwipeDeckFeedbackBanner: View {
    let kind: SwipeDeckFeedbackKind

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: kind.icon)
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.18), in: Circle())
                .symbolEffect(.bounce, value: kind)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                Text(kind.subtitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [kind.accent, kind.accent.opacity(0.62)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: kind.accent.opacity(0.35), radius: 22, y: 10)
        .padding(.horizontal, 20)
    }
}

private struct DiscoveryIconStatTile: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.black.opacity(0.18), in: Circle())

            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct DiscoveryMiniMetric: View {
    let icon: String
    let title: String
    let subtitle: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent.opacity(0.94))
                    .frame(width: 16, height: 16)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.white)
                    )

                Text(subtitle)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.74))
            }

            Text(title)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct DiscoveryBackSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                Text(title)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }

            content
        }
        .padding(16)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct DiscoveryNutritionTile: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent.opacity(0.9))
                    .frame(width: 10, height: 10)

                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }

            Text(value)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            Capsule()
                .fill(accent.opacity(0.9))
                .frame(width: 42, height: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct DiscoveryStatPill: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .allowsTightening(true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct DiscoveryTraitPill: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.16), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

private struct SuggestionCookingCard: View {
    @State private var scanAnimationStep: Int = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [Color.orange.opacity(0.18), Color.green.opacity(0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                Text("🍳")
                    .font(.system(size: 40))
                    .scaleEffect(scanAnimationStep % 2 == 0 ? 1.0 : 1.08)
                    .animation(.spring(response: 0.35, dampingFraction: 0.65), value: scanAnimationStep)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "circle")
                            .font(.system(size: 9, weight: .bold))
                        Text("AI Suggestion")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.14))
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                    )
                    .clipShape(Capsule())
                }
                .frame(height: 16)

                Text("ChefBuddy is cooking...")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(height: 54, alignment: .topLeading)

                Text("Making your next recipe idea")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(height: 20, alignment: .leading)

                Text("Detailed steps and nutrition are on the way.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(height: 18, alignment: .leading)

                HStack(spacing: 4) {
                    Text("Generating")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(Capsule())

                    Spacer(minLength: 0)

                    RecipeBouncingDotsView(step: scanAnimationStep, color: .orange)
                }
                .frame(height: 22)
            }
            .padding(12)
        }
        .frame(width: 180, height: 288)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.05), lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                scanAnimationStep += 1
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
}


private struct OrganizedRecipeGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let recipes: [Recipe]
}

struct AllRecipesView: View {
    @ObservedObject var vm: RecipesViewModel
    let userId: String
    let assistant: CookingAssistant
    let pantryIngredients: [String]
    var onAddMissingToGrocery: ((Recipe, [String]) -> Void)? = nil
    var onOpenGroceryList: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRecipe: Recipe? = nil
    @State private var recipeToReview: Recipe? = nil
    @State private var liveHelpRecipe: Recipe? = nil
    @State private var searchText = ""
    @State private var selectedCuisine = "All Cuisines"
    @State private var selectedFocusFilter = "All"
    @State private var selectedAttributes: Set<String> = []
    @State private var showFilterSheet = false
    @State private var hasAppeared = false
    private let focusFilters = ["All", "Favorites", "Cooked"]

    private var availableCuisines: [String] {
        let values = vm.recipes.map {
            detectedCuisineTag(title: $0.title, description: $0.description, tags: $0.tags)
        }
        return ["All Cuisines"] + Array(Set(values)).sorted()
    }

    private var displayedRecipes: [Recipe] {
        vm.recipes.filter { recipe in
            let matchesSearch: Bool = {
                let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if q.isEmpty { return true }
                let text = "\(recipe.title) \(recipe.description) \(recipe.tags.joined(separator: " "))".lowercased()
                return text.contains(q.lowercased())
            }()

            let matchesCuisine: Bool = {
                guard selectedCuisine != "All Cuisines" else { return true }
                return detectedCuisineTag(title: recipe.title, description: recipe.description, tags: recipe.tags) == selectedCuisine
            }()

            let matchesFocus: Bool = {
                switch selectedFocusFilter {
                case "Favorites":
                    return recipe.isFavorite
                case "Cooked":
                    return recipe.hasBeenCooked
                default:
                    return true
                }
            }()

            let matchesAttributes = selectedAttributes.allSatisfy { attribute in
                switch attribute {
                case "Quick":
                    return (prepMinutes(from: recipe.cookTime) ?? 999) <= 30
                case "High Protein":
                    return recipe.tags.contains { $0.localizedCaseInsensitiveContains("protein") }
                case "Healthy":
                    return recipe.tags.contains {
                        $0.localizedCaseInsensitiveContains("healthy") ||
                        $0.localizedCaseInsensitiveContains("low calorie")
                    }
                default:
                    return true
                }
            }

            return matchesSearch && matchesCuisine && matchesFocus && matchesAttributes
        }
    }

    private var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        selectedCuisine != "All Cuisines" ||
        selectedFocusFilter != "All" ||
        !selectedAttributes.isEmpty
    }

    private var advancedFilterCount: Int {
        (selectedCuisine == "All Cuisines" ? 0 : 1) + selectedAttributes.count
    }

    private var organizedGroups: [OrganizedRecipeGroup] {
        let grouped = Dictionary(grouping: displayedRecipes) { recipe in
            detectedCuisineTag(title: recipe.title, description: recipe.description, tags: recipe.tags)
        }

        var groups: [OrganizedRecipeGroup] = []
        let favorites = displayedRecipes.filter(\.isFavorite)
        if !favorites.isEmpty {
            groups.append(
                OrganizedRecipeGroup(
                    id: "favorites",
                    title: "Favorites",
                    subtitle: "The recipes you marked to keep close",
                    recipes: favorites
                )
            )
        }

        groups.append(contentsOf: grouped.keys.sorted().compactMap { cuisine in
            guard let recipes = grouped[cuisine], !recipes.isEmpty else { return nil }
            return OrganizedRecipeGroup(
                id: "cuisine-\(cuisine)",
                title: cuisine,
                subtitle: "\(recipes.count) recipe\(recipes.count == 1 ? "" : "s") in this collection",
                recipes: recipes
            )
        })
        return groups
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("All Recipes")
                                        .font(.system(size: 30, weight: .heavy, design: .rounded))

                                    Text("\(displayedRecipes.count) of \(vm.recipes.count) recipes")
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "square.grid.2x2.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.orange)
                                    .frame(width: 42, height: 42)
                                    .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }

                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                TextField("Search recipes, tags, cuisines...", text: $searchText)
                                    .font(.system(size: 15, design: .rounded))

                                if !searchText.isEmpty {
                                    Button(action: { searchText = "" }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                            )

                            HStack(spacing: 8) {
                                ForEach(focusFilters, id: \.self) { filter in
                                    Button {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                                            selectedFocusFilter = filter
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: filter == "Favorites" ? "heart.fill" : filter == "Cooked" ? "flame.fill" : "square.grid.2x2.fill")
                                            Text(filter)
                                        }
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(selectedFocusFilter == filter ? .white : .primary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                        .background(selectedFocusFilter == filter ? Color.orange : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(availableCuisines, id: \.self) { cuisine in
                                        Button {
                                            selectedCuisine = cuisine
                                        } label: {
                                            Text(cuisine)
                                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                                .foregroundStyle(selectedCuisine == cuisine ? .white : .primary)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 9)
                                                .background(selectedCuisine == cuisine ? Color.green : Color.primary.opacity(0.055), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    Button {
                                        showFilterSheet = true
                                    } label: {
                                        Label(advancedFilterCount == 0 ? "More filters" : "\(advancedFilterCount) filters", systemImage: "slider.horizontal.3")
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 9)
                                            .background(Color.orange.opacity(0.11), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if hasActiveFilters {
                                Button("Clear filters") {
                                    searchText = ""
                                    selectedCuisine = "All Cuisines"
                                    selectedFocusFilter = "All"
                                    selectedAttributes.removeAll()
                                }
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : -10)

                        if displayedRecipes.isEmpty {
                            VStack(spacing: 10) {
                                Text("No recipes match your filters")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                Text("Try clearing filters or searching with broader keywords.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                        } else if !hasActiveFilters {
                            VStack(alignment: .leading, spacing: 22) {
                                ForEach(organizedGroups) { group in
                                    VStack(alignment: .leading, spacing: 11) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(group.title)
                                                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                                                Text(group.subtitle)
                                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text("\(group.recipes.count)")
                                                .font(.system(size: 11, weight: .black, design: .rounded))
                                                .foregroundStyle(.orange)
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 6)
                                                .background(Color.orange.opacity(0.10), in: Capsule())
                                        }
                                        .padding(.horizontal, 16)

                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 13) {
                                                ForEach(group.recipes) { recipe in
                                                    RecipeCard(
                                                        recipe: recipe,
                                                        onTap: { selectedRecipe = recipe },
                                                        onFavorite: { vm.toggleFavorite(recipe, userId: userId) },
                                                        isCooked: recipe.hasBeenCooked
                                                    )
                                                    .frame(width: 174, height: 288)
                                                }
                                            }
                                            .padding(.horizontal, 16)
                                        }
                                    }
                                }
                            }
                        } else {
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 14),
                                    GridItem(.flexible(), spacing: 14)
                                ],
                                spacing: 14
                            ) {
                                ForEach(displayedRecipes) { recipe in
                                    RecipeCard(
                                        recipe: recipe,
                                        onTap: { selectedRecipe = recipe },
                                        onFavorite: { vm.toggleFavorite(recipe, userId: userId) },
                                        isCooked: recipe.hasBeenCooked
                                    )
                                    .frame(maxWidth: .infinity, minHeight: 288, maxHeight: 288)
                                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                                }
                            }
                            .padding(.horizontal, 16)
                            .animation(.spring(response: 0.34, dampingFraction: 0.84), value: displayedRecipes.map(\.id))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 30)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(0.04)) {
                    hasAppeared = true
                }
            }
            .sheet(isPresented: $showFilterSheet) {
                RecipeLibraryFilterSheet(
                    cuisines: availableCuisines,
                    selectedCuisine: $selectedCuisine,
                    selectedAttributes: $selectedAttributes
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedRecipe) { recipe in
                RecipeDetailView(
                    recipe: recipe,
                    assistant: assistant,
                    pantryIngredients: pantryIngredients,
                    onFavorite: { vm.toggleFavorite(recipe, userId: userId) },
                    onDelete: {
                        vm.deleteRecipe(recipe, userId: userId)
                        selectedRecipe = nil
                    },
                    userId: userId,
                    onRecipeUpdated: { updated in
                        vm.updateRecipeAfterReview(updated, userId: userId)
                        selectedRecipe = updated
                    },
                    onMarkCooked: {
                        selectedRecipe = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            recipeToReview = recipe
                        }
                    },
                    onLiveHelp: {
                        selectedRecipe = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            liveHelpRecipe = recipe
                        }
                    },
                    onAddMissingToGrocery: onAddMissingToGrocery,
                    onOpenGroceryList: onOpenGroceryList
                )
            }
            .sheet(item: $recipeToReview) { recipe in
                RecipeReviewView(
                    recipe: recipe,
                    assistant: assistant,
                    userId: userId,
                    onComplete: { updatedRecipe, liked, likedNote, improvement in
                        var cooked = updatedRecipe
                        cooked.cookedCount = max(updatedRecipe.cookedCount, recipe.cookedCount + 1)
                        cooked.lastCookedAt = Date()
                        vm.updateRecipeAfterReview(cooked, userId: userId)
                        if let recipeId = cooked.id {
                            vm.saveReview(recipeId: recipeId, liked: Array(liked), likedNote: likedNote, improvement: improvement, userId: userId)
                            Task {
                                await GrowthEngine.shared.logActivity(
                                    userId: userId,
                                    type: .recipeCooked,
                                    eventKey: "recipe_cooked_library_review_\(recipeId)_\(cooked.cookedCount)",
                                    metadata: [
                                        "recipeId": recipeId,
                                        "title": cooked.title,
                                        "source": "library_review"
                                    ]
                                )
                            }
                        }
                        recipeToReview = nil
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(item: $liveHelpRecipe) { recipe in
                LiveCookingView(recipe: recipe, assistant: assistant, userId: userId)
            }
        }
    }
}

private struct RecipeLibraryFilterSheet: View {
    let cuisines: [String]
    @Binding var selectedCuisine: String
    @Binding var selectedAttributes: Set<String>
    @Environment(\.dismiss) private var dismiss
    private let attributes = ["Quick", "High Protein", "Healthy"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Cuisine") {
                    Picker("Cuisine", selection: $selectedCuisine) {
                        ForEach(cuisines, id: \.self) { cuisine in
                            Text(cuisine).tag(cuisine)
                        }
                    }
                }

                Section("Recipe qualities") {
                    ForEach(attributes, id: \.self) { attribute in
                        Toggle(
                            attribute,
                            isOn: Binding(
                                get: { selectedAttributes.contains(attribute) },
                                set: { enabled in
                                    if enabled {
                                        selectedAttributes.insert(attribute)
                                    } else {
                                        selectedAttributes.remove(attribute)
                                    }
                                }
                            )
                        )
                    }
                }

                Button("Reset advanced filters", role: .destructive) {
                    selectedCuisine = "All Cuisines"
                    selectedAttributes.removeAll()
                }
            }
            .navigationTitle("Filter Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}


private struct LibraryCustomRecipeDraft {
    var title: String = ""
    var emoji: String = "🍽️"
    var description: String = ""
    var difficulty: String = "Easy"
    var tagsText: String = "Custom"
    var prepMinutes: Int = 25
    var servings: Int = 2
    var calories: Int = 420
    var carbs: Int = 40
    var protein: Int = 25
    var fat: Int = 15
    var sodium: Int = 520
    var ingredients: [String] = [""]
    var steps: [String] = [""]
    var autoPolishWithAI: Bool = true
}

private struct SimplifiedCustomRecipeSheet: View {
    @ObservedObject var assistant: CookingAssistant
    let onSave: (Recipe) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = LibraryCustomRecipeDraft()
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedPhotoImage: UIImage?
    @State private var isGenerating = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isReviewing = false

    private var canGenerate: Bool {
        (!draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedPhotoImage != nil) && !isGenerating
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        draft.ingredients.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
        draft.steps.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()
                ScrollView(showsIndicators: false) {
                    if isReviewing {
                        reviewStep
                    } else {
                        startingStep
                    }
                }
            }
            .navigationTitle(isReviewing ? "Review Recipe" : "New Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isReviewing ? "Back" : "Close") {
                        if isReviewing {
                            isReviewing = false
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .onChange(of: selectedPhotoItem) { _ in
                Task { await loadSelectedPhoto() }
            }
        }
    }

    private var startingStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Give ChefBuddy a starting point")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                Text("Add a title, description, or photo. ChefBuddy Fill will build a complete recipe with measured ingredients and cookable instructions.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Group {
                    if let selectedPhotoImage {
                        Image(uiImage: selectedPhotoImage)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 220)
                            .clipped()
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(.orange)
                            Text("Add an optional photo")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                            Text("A plated dish, ingredients, or a handwritten recipe all work.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                    }
                }
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text("Recipe title")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                TextField("Example: Spicy tofu rice bowl", text: $draft.title)
                    .textInputAutocapitalization(.words)
                    .padding(14)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                TextField("What should this dish feel or taste like?", text: $draft.description, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(14)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button(action: fillWithAI) {
                HStack(spacing: 10) {
                    if isGenerating {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(isGenerating ? "ChefBuddy is filling your recipe..." : "ChefBuddy Fill")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    canGenerate ? Color.orange : Color.secondary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canGenerate)
        }
        .padding(20)
        .padding(.bottom, 30)
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Make it yours")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                Text("ChefBuddy filled the structure. Review anything you want before saving.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            simpleTextField("Title", text: $draft.title)
            simpleTextField("Description", text: $draft.description, multiline: true)
            simpleTextField("Emoji", text: $draft.emoji)
            simpleTextField("Cuisine & tags", text: $draft.tagsText)

            HStack(spacing: 12) {
                compactStepper(title: "Minutes", value: $draft.prepMinutes, range: 5...240, step: 5)
                compactStepper(title: "Servings", value: $draft.servings, range: 1...12, step: 1)
            }

            Picker("Difficulty", selection: $draft.difficulty) {
                Text("Easy").tag("Easy")
                Text("Medium").tag("Medium")
                Text("Hard").tag("Hard")
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                Text("Nutrition per serving")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                HStack {
                    compactNumberField("kcal", value: $draft.calories)
                    compactNumberField("Carbs", value: $draft.carbs)
                    compactNumberField("Protein", value: $draft.protein)
                }
                HStack {
                    compactNumberField("Fat", value: $draft.fat)
                    compactNumberField("Sodium", value: $draft.sodium)
                }
            }
            .padding(15)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            editableList(title: "Ingredients", rows: $draft.ingredients, placeholder: "1 cup diced onions")
            editableList(title: "Steps", rows: $draft.steps, placeholder: "Cook over medium heat for 4 minutes.")

            Button(action: saveRecipe) {
                HStack {
                    if isSaving { ProgressView().tint(.white) }
                    Text(isSaving ? "Saving..." : "Save Recipe")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.green, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(!canSave || isSaving)
        }
        .padding(20)
        .padding(.bottom, 30)
    }

    private func simpleTextField(_ title: String, text: Binding<String>, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
            TextField(title, text: text, axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 2...5 : 1...1)
                .padding(13)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }

    private func compactStepper(title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        Stepper(value: value, in: range, step: step) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("\(value.wrappedValue)")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func compactNumberField(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad)
                .font(.system(size: 15, weight: .bold, design: .rounded))
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func editableList(title: String, rows: Binding<[String]>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Button {
                    rows.wrappedValue.append("")
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }

            ForEach(rows.wrappedValue.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    TextField(
                        placeholder,
                        text: Binding(
                            get: { rows.wrappedValue[index] },
                            set: { rows.wrappedValue[index] = $0 }
                        ),
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .padding(12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        guard rows.wrappedValue.count > 1 else { return }
                        rows.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                            .padding(.top, 10)
                    }
                    .disabled(rows.wrappedValue.count <= 1)
                }
            }
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func fillWithAI() {
        guard canGenerate else { return }
        errorMessage = nil
        isGenerating = true

        Task {
            do {
                let suggestion = try await generateSuggestion(attempt: 0)
                await MainActor.run {
                    apply(suggestion)
                    isGenerating = false
                    isReviewing = true
                }
            } catch {
                do {
                    let suggestion = try await generateSuggestion(attempt: 1)
                    await MainActor.run {
                        apply(suggestion)
                        isGenerating = false
                        isReviewing = true
                    }
                } catch {
                    await MainActor.run {
                        isGenerating = false
                        errorMessage = "ChefBuddy couldn’t build a complete draft. Check the title or photo and try again."
                    }
                }
            }
        }
    }

    private func generateSuggestion(attempt: Int) async throws -> RecipeSuggestion {
        let originalTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalDescription = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        Create one complete, realistic, home-cook-ready recipe from the user's title, description, and optional reference photo.
        Title: \(originalTitle.isEmpty ? "Infer a concise menu-style title from the photo." : originalTitle)
        Description: \(originalDescription.isEmpty ? "No description provided." : originalDescription)
        \(attempt == 0 ? "" : "REPAIR ATTEMPT: the previous output was incomplete. Return every field, at least 4 measured ingredients, and exactly 5 to 9 detailed steps.")

        Return ONLY a valid JSON object with:
        title, emoji, description, prepTime, servings, difficulty, calories, carbs,
        protein, fat, saturatedFat, sugar, fiber, sodium, tags, ingredients, steps, matchReason.

        Requirements:
        - If a photo is present, inspect visible ingredients, likely cuisine, cooking method, plating, and portion size.
        - Every ingredient must have a realistic quantity and unit wherever possible.
        - Return 5 to 9 chronological instructions.
        - Each instruction must be specific enough to cook from and include relevant heat level or temperature, timing, technique, and doneness cues.
        - Do not invent impossible techniques, missing ingredients, or conflicting cook times.
        - Use realistic servings, preparation time, and per-serving nutrition.
        - Keep the description to one appetizing sentence.
        """

        let raw: String
        if let selectedPhotoImage {
            raw = try await assistant.getLiveHelp(image: selectedPhotoImage, question: prompt)
        } else {
            raw = try await assistant.getHelp(question: prompt)
        }

        guard let json = CookingAssistant.extractJSONObject(from: raw),
              let data = json.data(using: .utf8) else {
            throw CookingAssistantError.invalidRecipeResponse
        }

        let suggestion = try JSONDecoder().decode(RecipeSuggestion.self, from: data)
        let validIngredients = suggestion.ingredients.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let validSteps = suggestion.steps.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard validIngredients.count >= 4,
              (5...9).contains(validSteps.count),
              validSteps.allSatisfy({ $0.count >= 24 }) else {
            throw CookingAssistantError.invalidRecipeResponse
        }
        return suggestion
    }

    private func apply(_ suggestion: RecipeSuggestion) {
        let originalTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalDescription = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.title = originalTitle.isEmpty ? suggestion.title : originalTitle
        draft.description = originalDescription.isEmpty ? suggestion.description : originalDescription
        draft.emoji = suggestion.emoji.isEmpty ? "🍽️" : suggestion.emoji
        draft.tagsText = suggestion.tags.joined(separator: ", ")
        draft.prepMinutes = prepMinutes(from: suggestion.prepTime) ?? 25
        draft.servings = max(1, suggestion.servings.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init).first ?? 2)
        draft.difficulty = ["Easy", "Medium", "Hard"].contains(suggestion.difficulty) ? suggestion.difficulty : "Easy"
        draft.calories = calorieNumber(from: suggestion.calories) ?? 0
        draft.carbs = calorieNumber(from: suggestion.carbs) ?? 0
        draft.protein = calorieNumber(from: suggestion.protein) ?? 0
        draft.fat = calorieNumber(from: suggestion.fat) ?? 0
        draft.sodium = calorieNumber(from: suggestion.sodium) ?? 0
        draft.ingredients = suggestion.ingredients
        draft.steps = suggestion.steps
    }

    private func saveRecipe() {
        guard canSave, !isSaving else { return }
        isSaving = true
        let tags = draft.tagsText.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        let recipe = Recipe(
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: draft.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "🍽️" : draft.emoji,
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            ingredients: draft.ingredients.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            steps: draft.steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            cookTime: "\(draft.prepMinutes) mins",
            servings: "\(draft.servings) people",
            difficulty: draft.difficulty,
            tags: tags.isEmpty ? ["Custom"] : tags,
            calories: "\(draft.calories) kcal",
            nutrition: NutritionInfo(
                calories: "\(draft.calories) kcal",
                carbs: "\(draft.carbs)g",
                protein: "\(draft.protein)g",
                fat: "\(draft.fat)g",
                saturatedFat: "",
                sugar: "",
                fiber: "",
                sodium: "\(draft.sodium)mg"
            )
        )
        onSave(recipe)
        dismiss()
    }

    private func loadSelectedPhoto() async {
        guard let selectedPhotoItem,
              let data = try? await selectedPhotoItem.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        await MainActor.run {
            selectedPhotoImage = image
        }
    }
}

struct RecipesCustomRecipeSheet: View {
    @ObservedObject var assistant: CookingAssistant
    let onSave: (Recipe) -> Void

    @State private var draft = LibraryCustomRecipeDraft()
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedPhotoImage: UIImage? = nil
    @State private var isGeneratingWithAI = false
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    private var nutritionColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    private var canSave: Bool {
        let titleOk = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ingredientsOk = draft.ingredients.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let stepsOk = draft.steps.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return titleOk && ingredientsOk && stepsOk
    }

    private var canAIFill: Bool {
        let titleOk = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isGeneratingWithAI && (titleOk || selectedPhotoImage != nil)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        customRecipeHeader

                        customRecipeSectionCard(
                            title: "Reference Photo",
                            subtitle: "Optional, but useful when you want ChefBuddy to infer the dish from plating, ingredients, and portion size."
                        ) {
                            VStack(alignment: .leading, spacing: 14) {
                                if let selectedPhotoImage {
                                    ZStack(alignment: .bottomLeading) {
                                        Image(uiImage: selectedPhotoImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(height: 188)
                                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                                        LinearGradient(
                                            colors: [.black.opacity(0.62), .clear],
                                            startPoint: .bottom,
                                            endPoint: .center
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Image attached")
                                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                                .foregroundStyle(.white.opacity(0.88))
                                            Text("AI can inspect the dish and fill likely ingredients, nutrition, and prep flow.")
                                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                                .foregroundStyle(.white)
                                        }
                                        .padding(14)
                                    }
                                } else {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                        .frame(height: 160)
                                        .overlay {
                                            VStack(spacing: 10) {
                                                Image(systemName: "photo.on.rectangle.angled")
                                                    .font(.system(size: 26, weight: .semibold))
                                                    .foregroundStyle(.secondary)
                                                Text("Add a photo to help ChefBuddy infer the dish")
                                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                Text("Upload plated food, ingredients, or handwritten notes and ChefBuddy will build the draft around it.")
                                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                                    .foregroundStyle(.secondary)
                                                    .multilineTextAlignment(.center)
                                                    .padding(.horizontal, 18)
                                            }
                                        }
                                }

                                HStack(spacing: 10) {
                                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                        Label(selectedPhotoImage == nil ? "Upload Reference" : "Change Photo", systemImage: "photo.badge.plus")
                                            .font(.system(size: 13, weight: .bold, design: .rounded))
                                            .foregroundStyle(.primary)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 11)
                                            .background(Color.primary.opacity(0.08), in: Capsule())
                                    }
                                    .buttonStyle(.plain)

                                    if selectedPhotoImage != nil {
                                        Button {
                                            selectedPhotoItem = nil
                                            selectedPhotoImage = nil
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .background(Color.primary.opacity(0.05), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    Spacer(minLength: 0)

                                    Button(action: aiFillFromTitleOrPhoto) {
                                        HStack(spacing: 8) {
                                            if isGeneratingWithAI {
                                                ProgressView()
                                                    .controlSize(.small)
                                                    .tint(.white)
                                            } else {
                                                Image(systemName: "sparkles.rectangle.stack.fill")
                                            }
                                            Text(isGeneratingWithAI ? "ChefBuddy is filling..." : "ChefBuddy Fill")
                                        }
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 15)
                                        .padding(.vertical, 11)
                                        .background(
                                            LinearGradient(colors: [.orange, .green.opacity(0.86)], startPoint: .leading, endPoint: .trailing),
                                            in: Capsule()
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!canAIFill)
                                    .opacity(canAIFill ? 1 : 0.62)
                                }

                                Text(canAIFill
                                     ? "ChefBuddy can infer the title, fill ingredients, tighten the cooking steps, and estimate nutrition from your current draft plus the image."
                                     : "Type a recipe title or upload a reference photo to unlock ChefBuddy Fill.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        customRecipeSectionCard(
                            title: "Recipe Basics",
                            subtitle: "Give the dish a clean title and a short card description. ChefBuddy will refine the rest."
                        ) {
                            VStack(alignment: .leading, spacing: 14) {
                                labeledInput(title: "Title", prompt: "Example: Lemon Garlic Salmon Bowl") {
                                    TextField("", text: $draft.title, prompt: Text("Example: Lemon Garlic Salmon Bowl").foregroundStyle(.secondary))
                                        .textInputAutocapitalization(.words)
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 14)
                                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }

                                labeledInput(title: "Description", prompt: "A one-line summary for the recipe card") {
                                    TextField(
                                        "",
                                        text: $draft.description,
                                        prompt: Text("A one-line summary for the recipe card").foregroundStyle(.secondary),
                                        axis: .vertical
                                    )
                                    .lineLimit(2...4)
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 14)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }

                                labeledInput(title: "Cuisine & Tags", prompt: "Indian, High Protein, Weeknight") {
                                    TextField("", text: $draft.tagsText, prompt: Text("Indian, High Protein, Weeknight").foregroundStyle(.secondary))
                                        .font(.system(size: 15, weight: .medium, design: .rounded))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 14)
                                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                        }

                        customRecipeSectionCard(
                            title: "Cooking Setup",
                            subtitle: "Control the runtime details that show up on the recipe card."
                        ) {
                            VStack(spacing: 12) {
                                HStack(spacing: 12) {
                                    metricStepperCard(
                                        title: "Prep Time",
                                        systemImage: "clock.fill",
                                        valueText: "\(draft.prepMinutes) mins",
                                        onDecrement: { draft.prepMinutes = max(5, draft.prepMinutes - 5) },
                                        onIncrement: { draft.prepMinutes = min(240, draft.prepMinutes + 5) }
                                    )

                                    metricStepperCard(
                                        title: "Servings",
                                        systemImage: "person.2.fill",
                                        valueText: "\(draft.servings) people",
                                        onDecrement: { draft.servings = max(1, draft.servings - 1) },
                                        onIncrement: { draft.servings = min(12, draft.servings + 1) }
                                    )
                                }

                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Difficulty")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: 10) {
                                        difficultyButton(title: "Easy", color: .green)
                                        difficultyButton(title: "Medium", color: .orange)
                                        difficultyButton(title: "Hard", color: .red)
                                    }
                                }
                            }
                        }

                        customRecipeSectionCard(
                            title: "Nutrition Per Serving",
                            subtitle: "Enter the numbers you want saved on the recipe card. ChefBuddy can overwrite these when ChefBuddy Fill is used."
                        ) {
                            VStack(spacing: 14) {
                                HStack(alignment: .top, spacing: 14) {
                                    recipeMacroBalanceCard

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Macro balance")
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                        macroProgressRow(title: "Protein", value: draft.protein, color: .green)
                                        macroProgressRow(title: "Carbs", value: draft.carbs, color: .blue)
                                        macroProgressRow(title: "Fat", value: draft.fat, color: .pink)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                LazyVGrid(columns: nutritionColumns, spacing: 12) {
                                    nutritionFieldCard(title: "Calories", unit: "kcal", value: $draft.calories, step: 10, maxValue: 3000, color: .orange)
                                    nutritionFieldCard(title: "Carbs", unit: "g", value: $draft.carbs, step: 1, maxValue: 600, color: .blue)
                                    nutritionFieldCard(title: "Protein", unit: "g", value: $draft.protein, step: 1, maxValue: 600, color: .green)
                                    nutritionFieldCard(title: "Fat", unit: "g", value: $draft.fat, step: 1, maxValue: 400, color: .pink)
                                    nutritionFieldCard(title: "Sodium", unit: "mg", value: $draft.sodium, step: 10, maxValue: 6000, color: .purple)
                                }
                            }
                        }

                        customRecipeSectionCard(
                            title: "Ingredients",
                            subtitle: "Add measured ingredients one by one so ChefBuddy can keep quantities clean."
                        ) {
                            editorRowsSection(
                                rows: $draft.ingredients,
                                placeholder: "1 cup diced onions",
                                multiline: false,
                                addLabel: "Add Ingredient"
                            )
                        }

                        customRecipeSectionCard(
                            title: "Method",
                            subtitle: "Write each step in order so live cooking can guide it clearly later."
                        ) {
                            editorRowsSection(
                                rows: $draft.steps,
                                placeholder: "Heat 1 tbsp oil over medium heat and sauté the onions until soft.",
                                multiline: true,
                                addLabel: "Add Step"
                            )
                        }

                        customRecipeSectionCard(
                            title: "Save Settings",
                            subtitle: "Before saving, ChefBuddy can normalize the language, add missing transitions, and clean up ingredient quantities."
                        ) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.orange.opacity(0.12))
                                        .frame(width: 48, height: 48)
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.orange)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("AI polish before save")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                    Text(draft.autoPolishWithAI
                                         ? "Enabled — ChefBuddy will tighten the writing before it becomes a saved recipe card."
                                         : "Disabled — your exact draft will be saved as-is.")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 12)

                                Toggle("", isOn: $draft.autoPolishWithAI)
                                    .labelsHidden()
                            }
                            .padding(14)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        Button(action: saveRecipe) {
                            HStack(spacing: 10) {
                                if isSaving {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "tray.and.arrow.down.fill")
                                }
                                Text(isSaving ? "Saving..." : "Save Custom Recipe")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                LinearGradient(colors: [.orange, .green.opacity(0.86)], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                            .shadow(color: .orange.opacity(0.18), radius: 18, y: 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSave || isSaving)
                        .opacity((canSave && !isSaving) ? 1 : 0.72)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 36)
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
        .onChange(of: selectedPhotoItem) { _ in
            Task { await loadSelectedPhoto() }
        }
    }

    private var customRecipeHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recipe Studio")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
            Text("Create a polished recipe card for your library. Use a title, a reference image, or both, and let ChefBuddy help shape the final version.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                headerPill(text: "Library-ready", systemImage: "square.stack.3d.up.fill")
                headerPill(text: "Image-aware AI", systemImage: "photo.badge.sparkles")
                headerPill(text: "Step-by-step", systemImage: "list.number")
            }
        }
        .padding(20)
        .background(.ultraThinMaterial.opacity(0.95), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func headerPill(text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func customRecipeSectionCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(18)
        .background(.ultraThinMaterial.opacity(0.95), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func labeledInput<Content: View>(
        title: String,
        prompt: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func metricStepperCard(
        title: String,
        systemImage: String,
        valueText: String,
        onDecrement: @escaping () -> Void,
        onIncrement: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            Text(valueText)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            HStack(spacing: 10) {
                stepperControl(systemImage: "minus", action: onDecrement)
                stepperControl(systemImage: "plus", action: onIncrement)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stepperControl(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func difficultyButton(title: String, color: Color) -> some View {
        let isSelected = draft.difficulty == title
        return Button {
            draft.difficulty = title
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                isSelected
                ? AnyShapeStyle(LinearGradient(colors: [.orange, .green.opacity(0.82)], startPoint: .leading, endPoint: .trailing))
                : AnyShapeStyle(Color.primary.opacity(0.06))
            , in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var recipeMacroBalanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Macro focus")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 16)

                Circle()
                    .trim(from: 0, to: CGFloat(Double(draft.protein) / max(1, Double(draft.protein + draft.carbs + draft.fat))))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Circle()
                    .trim(
                        from: CGFloat(Double(draft.protein) / max(1, Double(draft.protein + draft.carbs + draft.fat))),
                        to: CGFloat(Double(draft.protein + draft.carbs) / max(1, Double(draft.protein + draft.carbs + draft.fat)))
                    )
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Circle()
                    .trim(
                        from: CGFloat(Double(draft.protein + draft.carbs) / max(1, Double(draft.protein + draft.carbs + draft.fat))),
                        to: 1
                    )
                    .stroke(Color.pink, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 3) {
                    Text("\(draft.calories)")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                    Text("kcal")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 126, height: 126)
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func macroProgressRow(title: String, value: Int, color: Color) -> some View {
        let maxValue = max(1.0, Double(draft.protein + draft.carbs + draft.fat))
        let progress = min(1.0, Double(value) / maxValue)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(value)g")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 8)
        }
    }

    private func nutritionFieldCard(
        title: String,
        unit: String,
        value: Binding<Int>,
        step: Int,
        maxValue: Int,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Text(unit)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            TextField(
                "",
                value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = max(0, min($0, maxValue)) }
                ),
                format: .number
            )
            .keyboardType(.numberPad)
            .font(.system(size: 24, weight: .heavy, design: .rounded))
            .foregroundStyle(color)

            HStack(spacing: 10) {
                stepperControl(systemImage: "minus", action: {
                    value.wrappedValue = max(0, value.wrappedValue - step)
                })
                stepperControl(systemImage: "plus", action: {
                    value.wrappedValue = min(maxValue, value.wrappedValue + step)
                })
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func editorRowsSection(
        rows: Binding<[String]>,
        placeholder: String,
        multiline: Bool,
        addLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                rows.wrappedValue.append("")
            } label: {
                Label(addLabel, systemImage: "plus")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)

            ForEach(Array(rows.wrappedValue.enumerated()), id: \.offset) { index, _ in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.08), in: Circle())

                    Group {
                        if multiline {
                            TextField(
                                "",
                                text: Binding(
                                    get: { rows.wrappedValue[index] },
                                    set: { rows.wrappedValue[index] = $0 }
                                ),
                                prompt: Text(placeholder).foregroundStyle(.secondary),
                                axis: .vertical
                            )
                            .lineLimit(2...5)
                        } else {
                            TextField(
                                "",
                                text: Binding(
                                    get: { rows.wrappedValue[index] },
                                    set: { rows.wrappedValue[index] = $0 }
                                ),
                                prompt: Text(placeholder).foregroundStyle(.secondary)
                            )
                        }
                    }
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        guard rows.wrappedValue.count > 1 else { return }
                        rows.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(rows.wrappedValue.count > 1 ? Color.primary : Color.secondary.opacity(0.4))
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(rows.wrappedValue.count <= 1)
                }
            }
        }
    }

    private func aiFillFromTitleOrPhoto() {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPhoto = selectedPhotoImage != nil
        guard (!title.isEmpty || hasPhoto), !isGeneratingWithAI else { return }

        isGeneratingWithAI = true
        Task {
            do {
                let prompt = """
                Build a polished recipe draft from the user's title, existing notes, and optional image.
                If an image is provided, inspect it carefully and infer visible ingredients, likely cuisine, cooking method, plating style, and portion size.
                If no title is provided, infer a concise menu-style title from the image.
                Use realistic quantities, keep the description to one short sentence, and return 4 to 7 coherent cooking steps.
                Return ONLY valid JSON:
                {
                  "title": "recipe title",
                  "description": "short description",
                  "prepMinutes": 25,
                  "servings": 2,
                  "difficulty": "Easy|Medium|Hard",
                  "tags": ["Indian", "High Protein"],
                  "calories": 420,
                  "carbs": 40,
                  "protein": 26,
                  "fat": 14,
                  "sodium": 520,
                  "ingredients": ["1 cup ...", "..."],
                  "steps": ["Step 1...", "Step 2..."]
                }
                Existing title: \(title.isEmpty ? "none provided" : title)
                Existing description: \(draft.description)
                Existing tags: \(draft.tagsText)
                Existing ingredients: \(draft.ingredients.joined(separator: " | "))
                Existing steps: \(draft.steps.joined(separator: " | "))
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
                    await MainActor.run { isGeneratingWithAI = false }
                    return
                }

                await MainActor.run {
                    if let generatedTitle = object["title"] as? String,
                       !generatedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        draft.title = generatedTitle
                    }
                    draft.description = (object["description"] as? String) ?? draft.description
                    draft.prepMinutes = max(5, object["prepMinutes"] as? Int ?? draft.prepMinutes)
                    draft.servings = max(1, object["servings"] as? Int ?? draft.servings)
                    draft.difficulty = (object["difficulty"] as? String) ?? draft.difficulty
                    let filledTags = (object["tags"] as? [String]) ?? []
                    if !filledTags.isEmpty {
                        draft.tagsText = filledTags.joined(separator: ", ")
                    }
                    draft.calories = max(0, object["calories"] as? Int ?? draft.calories)
                    draft.carbs = max(0, object["carbs"] as? Int ?? draft.carbs)
                    draft.protein = max(0, object["protein"] as? Int ?? draft.protein)
                    draft.fat = max(0, object["fat"] as? Int ?? draft.fat)
                    draft.sodium = max(0, object["sodium"] as? Int ?? draft.sodium)
                    draft.emoji = defaultEmoji(from: filledTags, title: draft.title)
                    draft.ingredients = ((object["ingredients"] as? [String]) ?? draft.ingredients).isEmpty ? draft.ingredients : ((object["ingredients"] as? [String]) ?? draft.ingredients)
                    draft.steps = ((object["steps"] as? [String]) ?? draft.steps).isEmpty ? draft.steps : ((object["steps"] as? [String]) ?? draft.steps)
                    if draft.ingredients.isEmpty { draft.ingredients = [""] }
                    if draft.steps.isEmpty { draft.steps = [""] }
                    isGeneratingWithAI = false
                }
            } catch {
                await MainActor.run {
                    isGeneratingWithAI = false
                }
            }
        }
    }

    private func saveRecipe() {
        guard canSave, !isSaving else { return }
        isSaving = true
        Task {
            var polishedDraft = draft
            if draft.autoPolishWithAI {
                polishedDraft = await polishDraftWithAI(draft)
            }

            let tags = polishedDraft.tagsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let recipe = Recipe(
                title: polishedDraft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                emoji: polishedDraft.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || polishedDraft.emoji == "🍽️"
                    ? defaultEmoji(from: tags, title: polishedDraft.title)
                    : polishedDraft.emoji,
                description: polishedDraft.description.trimmingCharacters(in: .whitespacesAndNewlines),
                ingredients: polishedDraft.ingredients.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                steps: polishedDraft.steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                cookTime: "\(polishedDraft.prepMinutes) mins",
                servings: "\(polishedDraft.servings) people",
                difficulty: polishedDraft.difficulty,
                tags: tags.isEmpty ? ["Custom"] : tags,
                calories: "\(polishedDraft.calories) kcal",
                nutrition: NutritionInfo(
                    calories: "\(polishedDraft.calories) kcal",
                    carbs: "\(polishedDraft.carbs)g",
                    protein: "\(polishedDraft.protein)g",
                    fat: "\(polishedDraft.fat)g",
                    saturatedFat: "",
                    sugar: "",
                    fiber: "",
                    sodium: "\(polishedDraft.sodium)mg"
                ),
                createdAt: Date()
            )

            await MainActor.run {
                onSave(recipe)
                isSaving = false
                dismiss()
            }
        }
    }

    private func polishDraftWithAI(_ source: LibraryCustomRecipeDraft) async -> LibraryCustomRecipeDraft {
        do {
            let prompt = """
            Polish this recipe so it follows recipe standards.
            Ensure every ingredient has quantity + unit where possible.
            Ensure steps are complete and no major missing transitions.
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

    private func defaultEmoji(from tags: [String]?, title: String) -> String {
        let source = (tags ?? []).joined(separator: " ").lowercased() + " " + title.lowercased()
        if source.contains("pasta") { return "🍝" }
        if source.contains("salad") { return "🥗" }
        if source.contains("soup") { return "🍲" }
        if source.contains("bowl") { return "🥣" }
        if source.contains("rice") { return "🍚" }
        if source.contains("chicken") { return "🍗" }
        if source.contains("indian") { return "🍛" }
        if source.contains("mexican") { return "🌮" }
        if source.contains("dessert") || source.contains("sweet") { return "🍰" }
        return "🍽️"
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

struct GenerateRecipeSheet: View {
    @ObservedObject var vm: RecipesViewModel
    let assistant: CookingAssistant
    let userId: String
    var title: String = "Generate a Recipe"
    var subtitle: String = "Describe the meal in your head and ChefBuddy will turn it into a complete recipe."

    @State private var prompt = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    let quickPrompts = [
        "Quick & healthy",
        "High-protein dinner",
        "Chicken and rice",
        "Cozy vegetarian pasta",
        "30-minute meal prep",
        "Use what I have"
    ]

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var generationPhase: (icon: String, title: String, subtitle: String) {
        switch vm.elapsedSeconds {
        case 0...3:
            return ("lightbulb.fill", "Understanding your craving", "Reading the flavors, ingredients, and constraints you gave ChefBuddy.")
        case 4...8:
            return ("carrot.fill", "Building the ingredient list", "Choosing realistic quantities and a balanced combination of ingredients.")
        case 9...14:
            return ("list.number", "Writing clear cooking steps", "Adding temperatures, timing, technique, and doneness cues.")
        default:
            return ("checkmark.seal.fill", "Finishing your recipe card", "Checking nutrition, servings, and the final details before saving.")
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("CHEFBUDDY CREATOR")
                                        .font(.system(size: 10, weight: .black, design: .rounded))
                                        .tracking(1.1)
                                        .foregroundStyle(.white.opacity(0.72))
                                    Text("Begin with a feeling.")
                                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                                        .foregroundStyle(.white)
                                        .lineSpacing(-3)
                                }
                                Spacer()
                                Image(systemName: "sparkles")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 58, height: 58)
                                    .background(Color.white.opacity(0.16), in: Circle())
                            }

                            Text("A craving, a few ingredients, or a time limit is enough. Add only the details you care about.")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.86))
                                .lineSpacing(3)
                        }
                        .padding(20)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.36, green: 0.13, blue: 0.48), Color(red: 0.92, green: 0.35, blue: 0.14)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 32, style: .continuous)
                        )
                        .shadow(color: .orange.opacity(0.22), radius: 22, y: 10)

                        VStack(alignment: .leading, spacing: 13) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Tell me what sounds good")
                                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                                    Text("Talk naturally. ChefBuddy will organize the details.")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(prompt.count)/500")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }

                            ZStack(alignment: .topLeading) {
                                if prompt.isEmpty {
                                    Text("For example: I have chicken, rice, and broccoli. Make a high-protein dinner for two in under 35 minutes, with a little heat.")
                                        .font(.system(size: 16, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary.opacity(0.78))
                                        .padding(.horizontal, 17)
                                        .padding(.vertical, 18)
                                        .allowsHitTesting(false)
                                }

                                TextEditor(text: $prompt)
                                    .font(.system(size: 16, weight: .medium, design: .rounded))
                                    .scrollContentBackground(.hidden)
                                    .focused($focused)
                                    .frame(minHeight: 128)
                                    .padding(11)
                                    .disabled(vm.isGenerating)
                                    .onChange(of: prompt) { _, newValue in
                                        if newValue.count > 500 { prompt = String(newValue.prefix(500)) }
                                    }
                            }
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(focused ? Color.orange.opacity(0.75) : Color.primary.opacity(0.08), lineWidth: focused ? 2 : 1)
                            )
                        }
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )

                        HStack(spacing: 0) {
                            creatorCue(icon: "clock", title: "TIME", value: "Any pace")
                            creatorCue(icon: "person.2.fill", title: "SERVES", value: "Tell me")
                            creatorCue(icon: "basket.fill", title: "PANTRY", value: "Optional")
                        }
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Start with a direction")
                                .font(.system(size: 16, weight: .heavy, design: .rounded))

                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
                                ForEach(quickPrompts, id: \.self) { quick in
                                    Button {
                                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                        prompt = quick
                                        focused = false
                                    } label: {
                                        HStack(spacing: 7) {
                                            Image(systemName: prompt == quick ? "checkmark" : "sparkle")
                                            Text(quick)
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                        }
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(prompt == quick ? .white : .primary)
                                        .padding(.horizontal, 12)
                                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                        .background(prompt == quick ? Color.orange : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(vm.isGenerating)
                                }
                            }
                        }

                        if vm.isGenerating {
                            generationProgressCard
                        } else if case .failed(let message) = vm.generationState {
                            generationErrorCard(message)
                        }

                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .disabled(vm.isGenerating)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider().opacity(0.5)
                    Button(action: generate) {
                        HStack(spacing: 10) {
                            if vm.isGenerating {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(vm.isGenerating ? "Creating your recipe • \(vm.elapsedSeconds)s" : "Create My Recipe")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            trimmedPrompt.isEmpty ? Color.secondary.opacity(0.35) : Color.orange,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .shadow(color: trimmedPrompt.isEmpty ? .clear : .orange.opacity(0.24), radius: 12, y: 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedPrompt.isEmpty || vm.isGenerating)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .background(.regularMaterial)
            }
            .interactiveDismissDisabled(vm.isGenerating)
            .onAppear {
                if !vm.isGenerating { vm.resetGenerationPresentation() }
            }
            .onChange(of: vm.justGeneratedRecipe) { _, recipe in
                guard recipe != nil else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            }
        }
    }

    private func creatorCue(icon: String, title: String, value: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 8, weight: .black, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
    }

    private var generationProgressCard: some View {
        HStack(spacing: 15) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.14))
                    .frame(width: 58, height: 58)
                ProgressView()
                    .tint(.orange)
                    .scaleEffect(1.15)
            }
            VStack(alignment: .leading, spacing: 5) {
                Label(generationPhase.title, systemImage: generationPhase.icon)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(generationPhase.subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Text("\(vm.elapsedSeconds)s")
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .foregroundStyle(.orange)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.orange.opacity(0.20), lineWidth: 1)
        )
    }

    private func generationErrorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ChefBuddy couldn’t finish that recipe", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Button("Try Again", action: generate)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.red, in: Capsule())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func generate() {
        guard !trimmedPrompt.isEmpty, !vm.isGenerating else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        focused = false
        vm.generateAndSave(prompt: trimmedPrompt, assistant: assistant, userId: userId)
    }
}


struct RecipeDetailView: View {
    let recipe: Recipe
    @ObservedObject var assistant: CookingAssistant
    var pantryIngredients: [String] = []
    var pantrySpaces: [SimplePantrySpace] = []
    var selectedPantryId: String? = nil
    let onFavorite: () -> Void
    let onDelete: () -> Void
    let userId: String
    var onRecipeUpdated: ((Recipe) -> Void)? = nil
    var onMarkCooked: (() -> Void)? = nil
    var onLiveHelp: (() -> Void)? = nil
    var onAddMissingToGrocery: ((Recipe, [String]) -> Void)? = nil
    var onOpenGroceryList: (() -> Void)? = nil
    var onSelectPantry: ((String?) -> Void)? = nil


    @State private var activeTab = 0
    @State private var showDeleteConfirm = false
    @State private var showAssistantSheet = false
    @State private var usageSessionStartedAt: Date? = nil
    @State private var cookedDishPhotos: [CookedDishPhoto] = []
    @State private var galleryListener: ListenerRegistration? = nil
    @State private var showGalleryImagePicker = false
    @State private var selectedGalleryPhoto: CookedDishPhoto? = nil
    @State private var isUploadingGalleryPhoto = false
    @State private var galleryError: String? = nil
    @StateObject private var mealPlanVM = MealPlanViewModel()
    @Environment(\.dismiss) var dismiss

    var difficultyColor: Color {
        switch recipe.difficulty.lowercased() {
        case "easy":
            return .green
        case "hard":
            return .red
        default:
            return .orange
        }
    }

    private func saveToPlan(day: String, type: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        mealPlanVM.addToPlan(recipe: recipe, day: day, mealType: type, userId: userId)
    }

    private var cookedHistorySummary: String? {
        guard recipe.hasBeenCooked else { return nil }
        let dateText = recipe.lastCookedAt.map { Self.lastCookedFormatter.string(from: $0) } ?? "unknown"
        return "Cooked \(recipe.cookedCount)x • Last cooked \(dateText)"
    }

    private static let lastCookedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func dismissThenOpenGroceryListIfAvailable() {
        guard let onOpenGroceryList else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onOpenGroceryList()
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .top) {
                    LinearGradient(
                        colors: [Color.orange.opacity(0.18), Color.green.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(height: 220)

                    Text(recipe.emoji)
                        .font(.system(size: 100))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)

                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                                .background(Circle().fill(.ultraThinMaterial))
                        }

                        Spacer()

                        RecipeShareButton(recipe: recipe)

                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onFavorite()
                        }) {
                            Image(systemName: recipe.isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(recipe.isFavorite ? .red : .secondary)
                                .padding(10)
                                .background(Circle().fill(.ultraThinMaterial))
                        }

                        Button(action: { showDeleteConfirm = true }) {
                            Image(systemName: "trash")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.red)
                                .padding(10)
                                .background(Circle().fill(.ultraThinMaterial))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 56)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(recipe.title)
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Menu {
                            ForEach(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], id: \.self) { day in
                                Menu(day) {
                                    Button("Breakfast") { saveToPlan(day: day, type: "Breakfast") }
                                    Button("Lunch") { saveToPlan(day: day, type: "Lunch") }
                                    Button("Dinner") { saveToPlan(day: day, type: "Dinner") }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "calendar.badge.plus")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Plan")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                LinearGradient(
                                    colors: [.blue.opacity(0.92), .cyan.opacity(0.86)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            StatBadge(icon: "clock", label: recipe.cookTime, color: .orange)
                            StatBadge(icon: "person.2", label: recipe.servings, color: .blue)
                            StatBadge(icon: "flame", label: recipe.calories.isEmpty ? "—" : recipe.calories, color: .red)

                            Text(recipe.difficulty)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(difficultyColor)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(difficultyColor.opacity(0.12))
                                .clipShape(Capsule())
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    Text(recipe.description)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)

                    if let cookedHistorySummary {
                        Label(cookedHistorySummary, systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showAssistantSheet = true
                        }) {
                            Label("AI Assistant", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    LinearGradient(
                                        colors: [.orange, .green.opacity(0.85)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        if let onLiveHelp {
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    onLiveHelp()
                                }
                            }) {
                                Label("Live AI Help", systemImage: "video.fill")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        LinearGradient(
                                            colors: [.blue.opacity(0.9), .cyan.opacity(0.8)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let onMarkCooked {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                onMarkCooked()
                            }
                        }) {
                            Label("Mark as Cooked", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    LinearGradient(
                                        colors: [.green, .green.opacity(0.8)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }

                    if !recipe.tags.filter({ !$0.isEmpty }).isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recipe.tags.filter { !$0.isEmpty }, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.green.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                if recipe.id != nil {
                    cookedDishGallerySection
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }

                NutritionBreakdownCard(nutrition: recipe.nutrition, calories: recipe.calories)
                    .padding(.bottom, 8)


                HStack(spacing: 0) {
                    ForEach(["Ingredients", "Instructions"].indices, id: \.self) { i in
                        let label = ["Ingredients", "Instructions"][i]

                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.3)) {
                                activeTab = i
                            }
                        }) {
                            VStack(spacing: 6) {
                                Text(label)
                                    .font(.system(size: 15, weight: activeTab == i ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(activeTab == i ? .primary : .secondary)

                                Rectangle()
                                    .fill(activeTab == i ? Color.orange : Color.clear)
                                    .frame(height: 2)
                                    .clipShape(Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 4)

                Divider()
                    .padding(.horizontal, 24)

                if activeTab == 0 {
                    IngredientsTab(
                        ingredients: recipe.ingredients,
                        pantryIngredients: pantryIngredients,
                        pantrySpaces: pantrySpaces,
                        selectedPantryId: selectedPantryId,
                        onAddAllMissing: { missing in
                            onAddMissingToGrocery?(recipe, missing)
                            dismissThenOpenGroceryListIfAvailable()
                        },
                        onOpenGroceryList: {
                            dismissThenOpenGroceryListIfAvailable()
                        },
                        onSelectPantry: onSelectPantry
                    )
                } else {
                    InstructionsTab(steps: recipe.steps)
                }

                Spacer(minLength: 40)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onAppear {
            usageSessionStartedAt = Date()
            startGalleryListener()
        }
        .onDisappear {
            ChefBuddyUsageStats.recordSession(
                userId: userId,
                metric: .recipeViewingSeconds,
                startedAt: usageSessionStartedAt
            )
            usageSessionStartedAt = nil
            galleryListener?.remove()
            galleryListener = nil
        }
        .confirmationDialog("Delete this recipe?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) { }
        }

        .sheet(isPresented: $showAssistantSheet) {
            RecipeAssistantSheet(recipe: recipe, assistant: assistant, onApplyRecipe: onRecipeUpdated)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedGalleryPhoto) { photo in
            CookedDishPhotoViewer(photo: photo, recipeTitle: recipe.title)
        }
        .sheet(isPresented: $showGalleryImagePicker) {
            CookedDishImagePicker { image in
                Task { await uploadGalleryPhoto(image) }
            }
            .ignoresSafeArea()
        }
        .alert("Cooking Gallery", isPresented: Binding(
            get: { galleryError != nil },
            set: { if !$0 { galleryError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(galleryError ?? "")
        }
    }

    private var cookedDishGallerySection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Cooking Gallery")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                    Text(cookedDishPhotos.isEmpty ? "Add the first photo of your finished dish." : "\(cookedDishPhotos.count) kitchen memor\(cookedDishPhotos.count == 1 ? "y" : "ies") from this recipe.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showGalleryImagePicker = true
                } label: {
                    HStack(spacing: 6) {
                        if isUploadingGalleryPhoto {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.orange)
                        } else {
                            Image(systemName: "camera.fill")
                        }
                        Text(isUploadingGalleryPhoto ? "Adding" : "Add Photo")
                    }
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(Color.orange.opacity(0.11), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isUploadingGalleryPhoto)
            }

            if cookedDishPhotos.isEmpty {
                HStack(spacing: 13) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.pink)
                        .frame(width: 50, height: 50)
                        .background(Color.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remember how it turned out")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text("Photos are stored with this recipe so every repeat becomes part of its story.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(
                    LinearGradient(
                        colors: [Color.pink.opacity(0.09), Color.orange.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 11) {
                        ForEach(cookedDishPhotos) { photo in
                            Button {
                                selectedGalleryPhoto = photo
                            } label: {
                                AsyncImage(url: URL(string: photo.downloadURL)) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFill()
                                    case .failure:
                                        Image(systemName: "photo.badge.exclamationmark")
                                            .font(.system(size: 24, weight: .bold))
                                            .foregroundStyle(.secondary)
                                    default:
                                        ProgressView()
                                            .tint(.orange)
                                    }
                                }
                                .frame(width: 142, height: 156)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .stroke(Color.pink.opacity(0.13), lineWidth: 1)
        )
    }

    private func startGalleryListener() {
        guard let recipeId = recipe.id, !userId.isEmpty else { return }
        galleryListener?.remove()
        galleryListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("recipes")
            .document(recipeId)
            .collection("gallery")
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { snapshot, _ in
                let photos = snapshot?.documents.compactMap { document -> CookedDishPhoto? in
                    let data = document.data()
                    guard let downloadURL = data["downloadURL"] as? String else { return nil }
                    return CookedDishPhoto(
                        id: document.documentID,
                        downloadURL: downloadURL,
                        storagePath: data["storagePath"] as? String ?? "",
                        createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                    )
                } ?? []

                DispatchQueue.main.async {
                    cookedDishPhotos = photos
                }
            }
    }

    @MainActor
    private func uploadGalleryPhoto(_ image: UIImage) async {
        guard let recipeId = recipe.id else { return }
        isUploadingGalleryPhoto = true
        defer { isUploadingGalleryPhoto = false }

        do {
            try await CookedDishGalleryStore.upload(
                image: image,
                userId: userId,
                recipeId: recipeId,
                recipeTitle: recipe.title,
                recipeEmoji: recipe.emoji
            )
            ChefBuddyHaptics.success()
        } catch {
            galleryError = (error as? CookedDishGalleryError)?.errorDescription
                ?? "The photo could not be added to your Cooking Gallery. Please check your connection and try again."
            ChefBuddyHaptics.error()
        }
    }

}

private struct CookedDishPhotoViewer: View {
    let photo: CookedDishPhoto
    let recipeTitle: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AsyncImage(url: URL(string: photo.downloadURL)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    ContentUnavailableView("Photo Unavailable", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.white)
                default:
                    ProgressView()
                        .tint(.white)
                }
            }
            .padding(.horizontal, 12)

            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipeTitle)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(photo.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(20)

                Spacer()
            }
        }
    }
}

struct SuggestedRecipeDetailView: View {
    let recipe: Recipe
    @ObservedObject var assistant: CookingAssistant
    var pantryIngredients: [String] = []
    let onSave: () -> Void
    var onDislike: (() -> Void)? = nil
    var onRecipeUpdated: ((Recipe) -> Void)? = nil
    var onLiveHelp: (() -> Void)? = nil

    @State private var activeTab = 0
    @State private var showAssistantSheet = false
    @Environment(\.dismiss) var dismiss

    var difficultyColor: Color {
        switch recipe.difficulty.lowercased() {
        case "easy":
            return .green
        case "hard":
            return .red
        default:
            return .orange
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .top) {
                    LinearGradient(
                        colors: [Color.orange.opacity(0.18), Color.green.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(height: 220)

                    Text(recipe.emoji)
                        .font(.system(size: 100))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)

                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                                .background(Circle().fill(.ultraThinMaterial))
                        }

                        Spacer()

                        RecipeShareButton(recipe: recipe)

                        Button(action: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onSave()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                Text("Save")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(
                                    colors: [.orange, .green.opacity(0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 56)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(recipe.title)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            StatBadge(icon: "clock", label: recipe.cookTime, color: .orange)
                            StatBadge(icon: "person.2", label: recipe.servings, color: .blue)
                            StatBadge(icon: "flame", label: recipe.calories.isEmpty ? "—" : recipe.calories, color: .red)

                            Text(recipe.difficulty)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(difficultyColor)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(difficultyColor.opacity(0.12))
                                .clipShape(Capsule())
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    Text(recipe.description)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)

                    HStack(spacing: 10) {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showAssistantSheet = true
                        }) {
                            Label("AI Assistant", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    LinearGradient(
                                        colors: [.orange, .green.opacity(0.85)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        if let onLiveHelp {
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    onLiveHelp()
                                }
                            }) {
                                Label("Live AI Help", systemImage: "video.fill")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        LinearGradient(
                                            colors: [.blue.opacity(0.9), .cyan.opacity(0.8)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let onDislike {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onDislike()
                        }) {
                            Label("Not for me", systemImage: "hand.thumbsdown.fill")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    LinearGradient(
                                        colors: [.red.opacity(0.9), .pink.opacity(0.8)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }

                    if !recipe.tags.filter({ !$0.isEmpty }).isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recipe.tags.filter { !$0.isEmpty }, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.green.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                NutritionBreakdownCard(nutrition: recipe.nutrition, calories: recipe.calories)
                    .padding(.bottom, 8)

                HStack(spacing: 0) {
                    ForEach(["Ingredients", "Instructions"].indices, id: \.self) { i in
                        let label = ["Ingredients", "Instructions"][i]

                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.3)) {
                                activeTab = i
                            }
                        }) {
                            VStack(spacing: 6) {
                                Text(label)
                                    .font(.system(size: 15, weight: activeTab == i ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(activeTab == i ? .primary : .secondary)

                                Rectangle()
                                    .fill(activeTab == i ? Color.orange : Color.clear)
                                    .frame(height: 2)
                                    .clipShape(Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 4)

                Divider()
                    .padding(.horizontal, 24)

                if activeTab == 0 {
                    IngredientsTab(
                        ingredients: recipe.ingredients,
                        pantryIngredients: pantryIngredients,
                        showsGroceryActions: false
                    )
                } else {
                    InstructionsTab(steps: recipe.steps)
                }

                Spacer(minLength: 40)
            }
        }
        .ignoresSafeArea(edges: .top)
        .sheet(isPresented: $showAssistantSheet) {
            RecipeAssistantSheet(recipe: recipe, assistant: assistant, onApplyRecipe: onRecipeUpdated)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct RecipeAssistantMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String
}

private struct RecipeAssistantSheet: View {
    let recipe: Recipe
    @ObservedObject var assistant: CookingAssistant
    var onApplyRecipe: ((Recipe) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var isLoading = false
    @State private var workingRecipe: Recipe
    @State private var messages: [RecipeAssistantMessage] = [
        RecipeAssistantMessage(
            isUser: false,
            text: "Tell me what should change. I’ll revise the recipe and keep the card in sync."
        )
    ]

    private let quickRequests = [
        "Make it healthier",
        "Use fewer ingredients",
        "Make it vegetarian",
        "Improve the steps"
    ]

    init(recipe: Recipe, assistant: CookingAssistant, onApplyRecipe: ((Recipe) -> Void)? = nil) {
        self.recipe = recipe
        self.assistant = assistant
        self.onApplyRecipe = onApplyRecipe
        _workingRecipe = State(initialValue: recipe)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.09, green: 0.06, blue: 0.18), .black, Color(red: 0.03, green: 0.12, blue: 0.20)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                Circle().fill(Color.purple.opacity(0.18)).blur(radius: 80).offset(x: -160, y: -200).ignoresSafeArea()
                Circle().fill(Color.blue.opacity(0.12)).blur(radius: 80).offset(x: 160, y: 300).ignoresSafeArea()

                VStack(spacing: 16) {
                    HStack(alignment: .center, spacing: 15) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(colors: [.purple, .blue.opacity(0.88)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .frame(width: 58, height: 58)
                            Image(systemName: "sparkles")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("ChefBuddy Recipe Studio")
                                .font(.system(size: 20, weight: .heavy, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Editing \(workingRecipe.title)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(17)
                    .frame(minHeight: 92)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                    if isLoading {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(.purple)
                                .controlSize(.large)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Applying recipe changes...")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                Text("Updating ingredients and detailed instructions")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.16), Color.blue.opacity(0.10)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.purple.opacity(0.24), lineWidth: 1)
                        )
                        .padding(.horizontal, 16)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("QUICK CHANGES")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(0.52))

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                            ForEach(quickRequests, id: \.self) { request in
                                Button {
                                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                    input = request
                                } label: {
                                    Label(request, systemImage: "wand.and.stars")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 12)
                                        .frame(maxWidth: .infinity)
                                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoading)
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            ForEach(messages) { message in
                                HStack(alignment: .bottom, spacing: 8) {
                                    if message.isUser { Spacer(minLength: 44) }

                                    if !message.isUser {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 34, height: 34)
                                            .background(
                                                LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                                                in: Circle()
                                            )
                                    }

                                    Text(message.text)
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundStyle(message.isUser ? .white : .primary)
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 13)
                                        .background(
                                            message.isUser
                                                ? AnyShapeStyle(LinearGradient(colors: [.purple, .blue.opacity(0.88)], startPoint: .leading, endPoint: .trailing))
                                                : AnyShapeStyle(Color.white.opacity(0.08)),
                                            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        )
                                        .frame(maxWidth: 300, alignment: message.isUser ? .trailing : .leading)

                                    if !message.isUser { Spacer(minLength: 44) }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    HStack(spacing: 10) {
                        TextField("Ask for a recipe change…", text: $input, axis: .vertical)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .lineLimit(4)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .frame(minHeight: 56)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))

                        Button(action: sendMessage) {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: 54, height: 54)
                                    .background(
                                        LinearGradient(colors: [.purple, .blue.opacity(0.88)], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .clipShape(Circle())
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 54, height: 54)
                                    .background(
                                        LinearGradient(colors: [.purple, .blue.opacity(0.88)], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .clipShape(Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }
            }
            .navigationTitle("Recipe Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func sendMessage() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLoading else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        input = ""
        messages.append(.init(isUser: true, text: trimmed))
        isLoading = true

        Task {
            do {
                try await assistant.waitUntilReady()
                let ingredientList = workingRecipe.ingredients.map { "- \($0)" }.joined(separator: "\n")
                let stepList = workingRecipe.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                let prompt = """
                You are revising this recipe according to the user's request.
                Return ONLY in this exact format, no extra commentary:
                Title: [recipe name]
                Emoji: [single relevant emoji]
                Description: [one sentence about the dish]
                Cook Time: [e.g. 25 mins]
                Servings: [e.g. 2 people]
                Difficulty: [Easy / Medium / Hard]
                Calories: [e.g. 420 kcal]
                Carbs: [e.g. 42g]
                Protein: [e.g. 35g]
                Fat: [e.g. 12g]
                Saturated Fat: [e.g. 4g]
                Sugar: [e.g. 8g]
                Fiber: [e.g. 5g]
                Sodium: [e.g. 620mg]
                Tags: [comma-separated]

                Ingredients:
                \(ingredientList)
                Instructions:
                \(stepList)

                User request: \(trimmed)

                Rules for quality:
                - include precise ingredient amounts/units
                - include prep details where relevant (washing, dicing, preheating, marinating)
                - include timing and doneness cues in instructions
                - keep instructions detailed and easy to follow
                - include at least one cuisine tag
                """
                let raw = try await assistant.getHelp(question: prompt)
                var revised = RecipesViewModel.parseRecipe(from: raw)

                revised.id = workingRecipe.id
                revised.createdAt = workingRecipe.createdAt
                revised.isFavorite = workingRecipe.isFavorite
                revised.cookedCount = workingRecipe.cookedCount
                revised.lastCookedAt = workingRecipe.lastCookedAt

                if revised.tags.isEmpty { revised.tags = workingRecipe.tags }
                if revised.calories.isEmpty { revised.calories = workingRecipe.calories }
                if revised.nutrition.carbs.isEmpty { revised.nutrition.carbs = workingRecipe.nutrition.carbs }
                if revised.nutrition.protein.isEmpty { revised.nutrition.protein = workingRecipe.nutrition.protein }
                if revised.nutrition.fat.isEmpty { revised.nutrition.fat = workingRecipe.nutrition.fat }
                if revised.nutrition.saturatedFat.isEmpty { revised.nutrition.saturatedFat = workingRecipe.nutrition.saturatedFat }
                if revised.nutrition.sugar.isEmpty { revised.nutrition.sugar = workingRecipe.nutrition.sugar }
                if revised.nutrition.fiber.isEmpty { revised.nutrition.fiber = workingRecipe.nutrition.fiber }
                if revised.nutrition.sodium.isEmpty { revised.nutrition.sodium = workingRecipe.nutrition.sodium }

                await MainActor.run {
                    workingRecipe = revised
                    onApplyRecipe?(revised)
                    messages.append(.init(isUser: false, text: "Applied update. The recipe card and details are now updated."))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    messages.append(.init(isUser: false, text: "I hit an error while generating help. Please try again."))
                    isLoading = false
                }
            }
        }
    }
}

private struct StatBadge: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)

            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .clipShape(Capsule())
    }
}

private struct MissingIngredientPanel: View {
    let missingIngredients: [String]
    let totalIngredientCount: Int
    var pantrySpaces: [SimplePantrySpace] = []
    var selectedPantryId: String? = nil
    var onSelectPantry: ((String?) -> Void)? = nil
    var showsGroceryActions = true
    var onAddAll: (() -> Void)? = nil
    var onOpenList: (() -> Void)? = nil
    @State private var showsAllMissing = false
    @AppStorage(chefBuddyMeasurementSystemDefaultsKey) private var measurementSystem = "🇺🇸 US cups & ounces"

    private var availableCount: Int {
        max(totalIngredientCount - missingIngredients.count, 0)
    }

    var body: some View {
        let _ = measurementSystem
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill((missingIngredients.isEmpty ? Color.green : Color.orange).opacity(0.14))
                        .frame(width: 42, height: 42)
                    Image(systemName: missingIngredients.isEmpty ? "checkmark.seal.fill" : "basket.fill")
                        .foregroundStyle(missingIngredients.isEmpty ? .green : .orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(missingIngredients.isEmpty ? "Ready to cook" : "\(availableCount) of \(totalIngredientCount) ready")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(
                        missingIngredients.isEmpty
                        ? "Everything in this recipe is stocked."
                        : "\(missingIngredients.count) item\(missingIngredients.count == 1 ? "" : "s") still needed"
                    )
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ProgressView(value: Double(availableCount), total: Double(max(totalIngredientCount, 1)))
                .tint(missingIngredients.isEmpty ? .green : .orange)

            if let onSelectPantry,
               let selectedPantry = pantrySpaces.first(where: { $0.id == selectedPantryId }) {
                Menu {
                    ForEach(pantrySpaces) { pantry in
                        Button {
                            onSelectPantry(pantry.id)
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
                    HStack(spacing: 6) {
                        Text("Checking")
                            .foregroundStyle(.secondary)
                        Text("\(selectedPantry.emoji) \(selectedPantry.name)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            if !missingIngredients.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((showsAllMissing ? missingIngredients : Array(missingIngredients.prefix(3))).enumerated()), id: \.offset) { _, ingredient in
                        let parts = ingredientDisplayParts(from: ingredient)
                        HStack(spacing: 9) {
                            Text(ingredientEmoji(for: ingredient))
                                .frame(width: 26)
                            Text(parts.name)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            Spacer()
                            if !parts.quantity.isEmpty {
                                Text(parts.quantity)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if missingIngredients.count > 3 {
                        Button(showsAllMissing ? "Show less" : "Show all \(missingIngredients.count)") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showsAllMissing.toggle()
                            }
                        }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                    }
                }

                if showsGroceryActions {
                    VStack(spacing: 8) {
                        if let onAddAll {
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onAddAll()
                            }) {
                                Label("Add Missing to Grocery List", systemImage: "cart.badge.plus")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        LinearGradient(
                                            colors: [.orange, .green.opacity(0.85)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        if let onOpenList {
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                onOpenList()
                            }) {
                                Label("Open Grocery List", systemImage: "list.bullet.clipboard")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(Color.primary.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke((missingIngredients.isEmpty ? Color.green : Color.orange).opacity(0.22), lineWidth: 1)
        )
    }
}

private struct IngredientsTab: View {
    let ingredients: [String]
    var pantryIngredients: [String] = []
    var pantrySpaces: [SimplePantrySpace] = []
    var selectedPantryId: String? = nil
    var showsGroceryActions = true
    var onAddAllMissing: (([String]) -> Void)? = nil
    var onOpenGroceryList: (() -> Void)? = nil
    var onSelectPantry: ((String?) -> Void)? = nil
    @State private var pantryExpanded = true
    @State private var neededExpanded = true

    private var missingItems: [String] {
        missingIngredients(from: ingredients, pantryIngredients: pantryIngredients)
    }

    private var availableItems: [String] {
        ingredients.filter { pantryContainsIngredient($0, pantryIngredients: pantryIngredients) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !pantryIngredients.isEmpty {
                MissingIngredientPanel(
                    missingIngredients: missingItems,
                    totalIngredientCount: ingredients.count,
                    pantrySpaces: pantrySpaces,
                    selectedPantryId: selectedPantryId,
                    onSelectPantry: onSelectPantry,
                    showsGroceryActions: showsGroceryActions,
                    onAddAll: {
                        guard !missingItems.isEmpty else { return }
                        onAddAllMissing?(missingItems)
                    },
                    onOpenList: onOpenGroceryList
                )
            }

            if pantryIngredients.isEmpty {
                IngredientStatusSection(
                    title: "Ingredients",
                    subtitle: "\(ingredients.count) items",
                    items: ingredients,
                    status: nil,
                    tint: .orange,
                    isExpanded: .constant(true)
                )
            } else {
                IngredientStatusSection(
                    title: "In Your Pantry",
                    subtitle: "\(availableItems.count) ready",
                    items: availableItems,
                    status: "Stocked",
                    tint: .green,
                    isExpanded: $pantryExpanded
                )

                IngredientStatusSection(
                    title: "Still Needed",
                    subtitle: "\(missingItems.count) to get",
                    items: missingItems,
                    status: "Needed",
                    tint: .orange,
                    isExpanded: $neededExpanded
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }
}

private struct IngredientStatusSection: View {
    let title: String
    let subtitle: String
    let items: [String]
    let status: String?
    let tint: Color
    @Binding var isExpanded: Bool
    @AppStorage(chefBuddyMeasurementSystemDefaultsKey) private var measurementSystem = "🇺🇸 US cups & ounces"

    var body: some View {
        let _ = measurementSystem
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(15)
            }
            .buttonStyle(.plain)

            if isExpanded {
                if items.isEmpty {
                    Text(title == "Still Needed" ? "You have everything for this recipe." : "No matching pantry items yet.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 15)
                        .padding(.bottom, 15)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            let parts = ingredientDisplayParts(from: item)
                            HStack(spacing: 12) {
                                Text(ingredientEmoji(for: item))
                                    .font(.system(size: 23))
                                    .frame(width: 42, height: 42)
                                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(parts.name)
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.primary)
                                    if let status {
                                        Text(status)
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundStyle(tint)
                                    }
                                }
                                Spacer()
                                if !parts.quantity.isEmpty {
                                    Text(parts.quantity)
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct InstructionsTab: View {
    let steps: [String]
    @AppStorage("chefBuddy.chefLevel") private var chefLevel = "Beginner"
    @AppStorage("chefBuddy.hasMeasuringTools") private var hasMeasuringTools = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cooking roadmap")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                    Text("\(steps.count) clear step\(steps.count == 1 ? "" : "s") from prep to plate")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "list.number")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 40, height: 40)
                    .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .padding(.bottom, 4)

            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Text("\(index + 1)")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(
                                LinearGradient(
                                    colors: [.orange, .green.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: Circle()
                            )

                        if index < steps.count - 1 {
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [.orange.opacity(0.35), .green.opacity(0.20)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 2, height: 54)
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text(index == 0 ? "Start here" : index == steps.count - 1 ? "Finish & serve" : "Step \(index + 1)")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(index == steps.count - 1 ? .green : .orange)
                            .textCase(.uppercase)

                        Text(step)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let guidance = beginnerMeasurementGuidance(for: step) {
                            Label(guidance, systemImage: "hand.raised.fingers.spread.fill")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(15)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    private func beginnerMeasurementGuidance(for step: String) -> String? {
        guard chefLevel.localizedCaseInsensitiveContains("beginner"), !hasMeasuringTools else { return nil }
        let lower = step.lowercased()
        if lower.contains("teaspoon") || lower.contains("tsp") {
            return "No measuring spoon? One teaspoon is about one small eating spoon, leveled."
        }
        if lower.contains("tablespoon") || lower.contains("tbsp") {
            return "No measuring spoon? One tablespoon is about one large eating spoon, leveled."
        }
        if lower.contains("cup") {
            return "No measuring cup? Use the same small mug throughout so the ratio stays consistent."
        }
        return nil
    }
}

private struct RecipesEmptyState: View {
    let filter: String
    let onGenerate: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 116, height: 116)

                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 82, height: 82)

                Image(systemName: filter == "All" ? "book.closed.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.orange)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.orange.opacity(0.16), lineWidth: 1)
            }

            VStack(spacing: 7) {
                Text(filter == "All" ? "Start your personal cookbook" : "No recipes in this view")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))

                Text(
                    filter == "All"
                        ? "Save one recipe you genuinely want to cook. Your library, recommendations, and cooking journey will grow from there."
                        : "Try another filter or reset this view to see the rest of your cookbook."
                )
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
            }

            if filter == "All" {
                Button(action: onGenerate) {
                    HStack(spacing: 9) {
                        Image(systemName: "sparkles")
                        Text("Create My First Recipe")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: .orange.opacity(0.22), radius: 10, y: 5)
                }
            }
        }
        .padding(22)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}


// Reusable macro display card. Only renders if at least one macro field is
// populated, so it's safe to show on recipes that predate nutrition tracking.
struct NutritionBreakdownCard: View {
    let nutrition: NutritionInfo
    let calories: String

    private var hasAnyData: Bool {
        !nutrition.carbs.isEmpty || !nutrition.protein.isEmpty ||
        !nutrition.fat.isEmpty || !nutrition.sugar.isEmpty ||
        !nutrition.fiber.isEmpty || !nutrition.sodium.isEmpty ||
        !calories.isEmpty
    }

    var body: some View {
        if hasAnyData {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.orange)
                    Text("Nutrition Per Serving")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }


                if !calories.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(calories)
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundStyle(.orange)
                            Text("Total Calories")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 2)
                }


                let macros: [(String, String, Color)] = [
                    ("Carbs", nutrition.carbs, .blue),
                    ("Protein", nutrition.protein, .green),
                    ("Fat", nutrition.fat, .orange),
                    ("Sat. Fat", nutrition.saturatedFat, .red),
                    ("Sugar", nutrition.sugar, .pink),
                    ("Fiber", nutrition.fiber, .teal),
                    ("Sodium", nutrition.sodium, .purple),
                ]
                let filledMacros = macros.filter { !$0.1.isEmpty }

                if !filledMacros.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 10
                    ) {
                        ForEach(filledMacros, id: \.0) { name, value, color in
                            VStack(spacing: 4) {
                                Text(value)
                                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                                    .foregroundStyle(color)
                                Text(name)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(color.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            .padding(16)
            .background(
                LinearGradient(
                    colors: [Color.orange.opacity(0.05), Color.green.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.15), lineWidth: 1))
            .padding(.horizontal, 24)
        }
    }
}


private struct GroceryRecipeGroup: Identifiable {
    let id: String
    let recipeTitle: String
    let recipeEmoji: String
    let items: [GroceryListItem]

    var remainingCount: Int {
        items.filter { !$0.isPurchased }.count
    }

    var completionRatio: Double {
        guard !items.isEmpty else { return 0 }
        return Double(items.count - remainingCount) / Double(items.count)
    }
}

private enum InstacartShoppingLinkService {
    enum LinkError: LocalizedError {
        case notConfigured
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Add an Instacart Developer Platform key as INSTACART_API_KEY in the app configuration to enable one-tap shopping."
            case .invalidResponse:
                return "Instacart could not create this shopping list right now. Please try again."
            }
        }
    }

    static func createLink(items: [GroceryListItem]) async throws -> URL {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "INSTACART_API_KEY") as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LinkError.notConfigured
        }

        let uniqueNames = Array(Set(items.filter { !$0.isPurchased }.map {
            ($0.normalizedIngredient.isEmpty ? $0.ingredientDisplay : $0.normalizedIngredient)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        })).filter { !$0.isEmpty }.sorted()
        guard !uniqueNames.isEmpty else { throw LinkError.invalidResponse }

        let endpoint = Bundle.main.object(forInfoDictionaryKey: "INSTACART_API_BASE_URL") as? String
            ?? "https://connect.instacart.com"
        guard let url = URL(string: endpoint + "/idp/v1/products/products_link") else {
            throw LinkError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": "ChefBuddy Grocery List",
            "link_type": "shopping_list",
            "line_items": uniqueNames.map { ["name": $0] }
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let link = payload["products_link_url"] as? String,
              let result = URL(string: link) else {
            throw LinkError.invalidResponse
        }
        return result
    }
}

struct GroceryListView: View {
    let userId: String
    @ObservedObject var assistant: CookingAssistant
    let budgetPreference: String

    @EnvironmentObject var authVM: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var items: [GroceryListItem] = []
    @State private var selectedStore: GroceryStore = .safeway
    @State private var searchText = ""
    @State private var isMatchingStoreProducts = false
    @State private var matchAnimationStep = 0
    @State private var matchTimer: Timer?
    @State private var listener: ListenerRegistration?
    @State private var expandedRecipeId: String? = nil
    @State private var heroPulse = false
    @State private var pantrySpaces: [SimplePantrySpace] = []
    @State private var selectedPantryId: String? = nil
    @State private var pantryListener: ListenerRegistration? = nil
    @State private var isCreatingInstacartLink = false
    @State private var instacartError: String? = nil
    @State private var groceryHeroMetricIndex = 0
    private let groceryHeroTimer = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    private var itemsCollection: CollectionReference {
        Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("groceryList")
            .document("active")
            .collection("items")
    }

    private var filteredItems: [GroceryListItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visibleItems = items.filter { item in
            isAlwaysAvailableIngredient(item.normalizedIngredient.isEmpty ? item.ingredientDisplay : item.normalizedIngredient) == false
        }
        guard !query.isEmpty else { return visibleItems }

        return visibleItems.filter { item in
            let text = "\(item.recipeTitle) \(item.ingredientDisplay) \(item.normalizedIngredient)".lowercased()
            return text.contains(query)
        }
    }

    private var groupedItems: [GroceryRecipeGroup] {
        let grouped = Dictionary(grouping: filteredItems) { item in
            item.recipeId ?? item.recipeTitle.lowercased()
        }

        return grouped.compactMap { id, values in
            guard let first = values.first else { return nil }
            return GroceryRecipeGroup(
                id: id,
                recipeTitle: first.recipeTitle,
                recipeEmoji: first.recipeEmoji,
                items: values.sorted { $0.createdAt > $1.createdAt }
            )
        }
        .sorted { lhs, rhs in
            lhs.recipeTitle.localizedCaseInsensitiveCompare(rhs.recipeTitle) == .orderedAscending
        }
    }

    private var purchasedCount: Int {
        items.filter { $0.isPurchased }.count
    }

    private var totalCount: Int {
        items.count
    }

    private var recipeGroupCount: Int {
        groupedItems.count
    }

    private var completionRatio: Double {
        guard totalCount > 0 else { return 0 }
        return Double(purchasedCount) / Double(totalCount)
    }

    private var selectedPantry: SimplePantrySpace? {
        pantrySpaces.first(where: { $0.id == selectedPantryId })
    }

    private var itemStateSignature: String {
        items.map { item in
            let storeKey = selectedStore.rawValue
            let matchCount = item.matchesByStore[storeKey]?.count ?? 0
            let attempted = item.matchAttemptedStores?[storeKey] == nil ? "0" : "1"
            return [
                item.id ?? "",
                item.isPurchased ? "1" : "0",
                "\(matchCount)",
                attempted
            ].joined(separator: ":")
        }
        .joined(separator: "|")
    }

    var body: some View {
        ZStack {
            backgroundLayer
            scrollContent
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
        }
        .onAppear {
            startListening()
            startPantryListening()
            heroPulse = true
            Task { await matchStoreProducts(force: false) }
        }
        .onDisappear {
            listener?.remove()
            listener = nil
            pantryListener?.remove()
            pantryListener = nil
            stopMatchTimer()
        }
        .onChange(of: selectedStore) { _ in
            Task { await matchStoreProducts(force: false) }
        }
        .onChange(of: itemStateSignature) { _ in
            Task { await matchStoreProducts(force: false) }
        }
        .onChange(of: selectedPantryId) { pantryId in
            authVM.updateActivePantrySelection(pantryId)
        }
        .preferredColorScheme(.dark)
        .onReceive(groceryHeroTimer) { _ in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                groceryHeroMetricIndex = (groceryHeroMetricIndex + 1) % 4
            }
        }
        .alert("Shop with Instacart", isPresented: Binding(
            get: { instacartError != nil },
            set: { if !$0 { instacartError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(instacartError ?? "")
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            ChefBuddyBackground()
            Circle()
                .fill(Color.orange.opacity(heroPulse ? 0.12 : 0.07))
                .blur(radius: 90)
                .offset(x: -170, y: -260)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: heroPulse)
            Circle()
                .fill(Color.green.opacity(heroPulse ? 0.11 : 0.06))
                .blur(radius: 90)
                .offset(x: 170, y: 320)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: heroPulse)
        }
    }

    private var scrollContent: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 16) {
                headerMetricsCard
                compactShoppingControls
                    .zIndex(1)
                groupedListContent
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
    }

    private var headerMetricsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "cart.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(
                                LinearGradient(
                                    colors: [.orange, .green.opacity(0.86)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Shopping,\norganized.")
                                .font(.system(size: 27, weight: .heavy, design: .rounded))
                                .lineSpacing(-3)
                            Text("CHEFBUDDY GROCERY")
                                .font(.system(size: 10, weight: .black, design: .rounded))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }

                    Text(totalCount == 0 ? "Add missing ingredients from a recipe and ChefBuddy will keep your shop in one clear place." : "\(totalCount - purchasedCount) ingredients remain across \(recipeGroupCount) planned recipe\(recipeGroupCount == 1 ? "" : "s").")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 8)
                        .frame(width: 78, height: 78)

                    Circle()
                        .trim(from: 0, to: completionRatio)
                        .stroke(
                            LinearGradient(
                                colors: [.orange, .green.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 78, height: 78)

                    VStack(spacing: 2) {
                        Text("\(Int((completionRatio * 100).rounded()))%")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                        Text("complete")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }

            let metrics = [
                ("\(totalCount - purchasedCount)", "items left to buy", "cart.fill"),
                ("\(purchasedCount)", "items already found", "checkmark.seal.fill"),
                ("\(recipeGroupCount)", "recipes covered", "book.closed.fill"),
                (selectedStore.rawValue, "active store match", "storefront.fill")
            ]
            let metric = metrics[groceryHeroMetricIndex % metrics.count]
            HStack(spacing: 13) {
                Image(systemName: metric.2)
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.14), in: Circle())
                groceryHeroMetric(value: metric.0, label: metric.1)
            }
            .id(groceryHeroMetricIndex)
            .transition(.move(edge: .trailing).combined(with: .opacity))

            if let selectedPantry {
                Label("\(selectedPantry.emoji) Checking against \(selectedPantry.name)", systemImage: "basket.fill")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
            }
        }
        .padding(20)
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: [Color(red: 0.17, green: 0.17, blue: 0.19), Color(red: 0.08, green: 0.09, blue: 0.11)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 29, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 29, style: .continuous)
                .stroke(Color.orange.opacity(0.24), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }

    private func groceryHeroMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
            Text(label.uppercased())
                .font(.system(size: 9, weight: .black, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var compactShoppingControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.orange)
                TextField("Search ingredients or recipes", text: $searchText)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    Button("Match products") {
                        Task { await matchStoreProducts(force: true) }
                    }
                    .disabled(isMatchingStoreProducts || filteredItems.isEmpty)

                    Button("Remove purchased", role: .destructive) {
                        removePurchasedItems()
                    }
                    .disabled(purchasedCount == 0)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 54)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shopping at")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("Product choices update for the selected store.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await matchStoreProducts(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(width: 34, height: 34)
                        .background(Color.orange.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isMatchingStoreProducts || filteredItems.isEmpty)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(GroceryStore.allCases) { store in
                        Button {
                            guard selectedStore != store else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                selectedStore = store
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Text(store.emoji)
                                Text(store.rawValue)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                                if selectedStore == store {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .black))
                                }
                            }
                            .foregroundStyle(selectedStore == store ? .white : .primary)
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .background(
                                selectedStore == store
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [.orange, .purple.opacity(0.86)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                : AnyShapeStyle(Color.primary.opacity(0.055)),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isMatchingStoreProducts {
                matchingBanner
            }

            Button {
                createInstacartShoppingLink()
            } label: {
                HStack(spacing: 12) {
                    if isCreatingInstacartLink {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "cart.badge.plus")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shop this list with Instacart")
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                        Text("Match the remaining items, choose a store, and check out on Instacart.")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.76))
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .foregroundStyle(.white)
                .padding(15)
                .background(
                    LinearGradient(colors: [Color(red: 0.18, green: 0.62, blue: 0.31), Color(red: 0.08, green: 0.42, blue: 0.21)], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(isCreatingInstacartLink || filteredItems.filter { !$0.isPurchased }.isEmpty)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func createInstacartShoppingLink() {
        isCreatingInstacartLink = true
        Task {
            do {
                let link = try await InstacartShoppingLinkService.createLink(items: filteredItems)
                await MainActor.run {
                    isCreatingInstacartLink = false
                    openURL(link)
                }
            } catch {
                await MainActor.run {
                    isCreatingInstacartLink = false
                    instacartError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private var searchBarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search your list")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("Search recipe or ingredient", text: $searchText)
                    .font(.system(size: 14, design: .rounded))

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var storeControlsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Store matching")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(GroceryStore.allCases) { store in
                        let selected = selectedStore == store
                        Button(action: {
                            guard !selected else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                selectedStore = store
                            }
                        }) {
                            HStack(spacing: 6) {
                                Text(store.emoji)
                                Text(store.rawValue)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(selected ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                selected
                                ? AnyView(
                                    LinearGradient(
                                        colors: [.orange, .green.opacity(0.85)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                : AnyView(Color.primary.opacity(0.08))
                            )
                            .clipShape(Capsule())
                            .scaleEffect(selected ? 1.02 : 1.0)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("Pick where you are shopping and let ChefBuddy line up the closest product matches.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await matchStoreProducts(force: true) }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Match Products")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [.orange, .green.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isMatchingStoreProducts || filteredItems.isEmpty)

                Button(action: removePurchasedItems) {
                    Label("Remove Purchased", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(purchasedCount == 0)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var matchingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Matching products at \(selectedStore.rawValue)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text("ChefBuddy is checking the best fit for your remaining ingredients.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            RecipeBouncingDotsView(step: matchAnimationStep, color: .orange)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func startPantryListening() {
        pantryListener?.remove()
        pantryListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("pantrySpaces")
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }

                let spaces = documents.map { document -> SimplePantrySpace in
                    let data = document.data()
                    let name = data["name"] as? String ?? "Pantry"
                    let emoji = data["emoji"] as? String ?? "🥑"
                    let colorTheme = data["colorTheme"] as? String ?? "Orange"
                    let ingredients = (data["virtualPantry"] as? [String: [String]] ?? [:]).values.flatMap { $0 }
                    return SimplePantrySpace(
                        id: document.documentID,
                        name: name,
                        emoji: emoji,
                        ingredients: ingredients,
                        colorTheme: colorTheme
                    )
                }
                .sorted { $0.name < $1.name }

                DispatchQueue.main.async {
                    pantrySpaces = spaces

                    if let selectedPantryId,
                       spaces.contains(where: { $0.id == selectedPantryId }) == false {
                        self.selectedPantryId = nil
                    }

                    if self.selectedPantryId == nil,
                       let preferredPantryId = authVM.currentUserProfile?.activePantryId,
                       spaces.contains(where: { $0.id == preferredPantryId }) {
                        self.selectedPantryId = preferredPantryId
                    } else if self.selectedPantryId == nil {
                        self.selectedPantryId = spaces.first?.id
                    }
                }
            }
    }

    @ViewBuilder
    private var groupedListContent: some View {
        if groupedItems.isEmpty {
            VStack(spacing: 8) {
                Text("🧺")
                    .font(.system(size: 44))
                Text("No grocery items yet")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("Add missing ingredients from any recipe to build a list here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(spacing: 12) {
                ForEach(groupedItems) { group in
                    groupCard(group)
                }
            }
        }
    }

    private func toggleGroupExpansion(_ group: GroceryRecipeGroup) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if expandedRecipeId == group.id {
                expandedRecipeId = nil
            } else {
                expandedRecipeId = group.id
            }
        }
    }

    private func groupCard(_ group: GroceryRecipeGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.orange.opacity(0.22), .purple.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)

                    Text(group.recipeEmoji)
                        .font(.system(size: 24))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(group.recipeTitle)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(group.items.count) item\(group.items.count == 1 ? "" : "s") • \(group.remainingCount) still to grab")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 8) {
                    Text(group.remainingCount == 0 ? "Ready" : "\(group.remainingCount) left")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(group.remainingCount == 0 ? .green : .orange)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background((group.remainingCount == 0 ? Color.green : Color.orange).opacity(0.14), in: Capsule())

                    Menu {
                        Button(role: .destructive) {
                            removeRecipeGroup(group)
                        } label: {
                            Label("Remove recipe items", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
            }

            if expandedRecipeId == group.id {
                VStack(spacing: 8) {
                    ForEach(group.items) { item in
                        GroceryListItemRow(
                            item: item,
                            store: selectedStore,
                            isMatching: isMatchingStoreProducts,
                            onTogglePurchased: { togglePurchased(item) },
                            onFindMatch: {
                                Task {
                                    await matchStoreProducts(targetItems: [item], force: true)
                                }
                            }
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                toggleGroupExpansion(group)
            } label: {
                HStack(spacing: 10) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(
                                    LinearGradient(colors: [.orange, .purple], startPoint: .leading, endPoint: .trailing)
                                )
                                .frame(width: proxy.size.width * group.completionRatio)
                        }
                    }
                    .frame(height: 5)

                    Text(expandedRecipeId == group.id ? "Close" : "Review \(group.items.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize()
                    Image(systemName: expandedRecipeId == group.id ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.085), Color.white.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(
                    LinearGradient(colors: [Color.white.opacity(0.14), Color.orange.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.20), radius: 18, y: 10)
    }

    private func startListening() {
        guard !userId.isEmpty else { return }

        listener?.remove()
        listener = itemsCollection
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { snap, _ in
                guard let docs = snap?.documents else { return }
                let decoded = docs.compactMap { try? $0.data(as: GroceryListItem.self) }
                let visibleItems = decoded.filter {
                    isAlwaysAvailableIngredient($0.normalizedIngredient.isEmpty ? $0.ingredientDisplay : $0.normalizedIngredient) == false
                }
                let stapleItems = decoded.filter {
                    isAlwaysAvailableIngredient($0.normalizedIngredient.isEmpty ? $0.ingredientDisplay : $0.normalizedIngredient)
                }

                DispatchQueue.main.async {
                    items = visibleItems
                    removeAlwaysAvailableItems(stapleItems)
                }
            }
    }

    private func removeAlwaysAvailableItems(_ stapleItems: [GroceryListItem]) {
        let removableIds = stapleItems.compactMap(\.id)
        guard !removableIds.isEmpty else { return }
        let batch = Firestore.firestore().batch()
        for id in removableIds {
            batch.deleteDocument(itemsCollection.document(id))
        }
        batch.commit()
    }

    private func togglePurchased(_ item: GroceryListItem) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let willBePurchased = !item.isPurchased
        let key = item.normalizedIngredient.isEmpty
            ? normalizedIngredientKey(from: item.ingredientDisplay)
            : item.normalizedIngredient.lowercased()
        let linkedItems = items.filter { candidate in
            let candidateKey = candidate.normalizedIngredient.isEmpty
                ? normalizedIngredientKey(from: candidate.ingredientDisplay)
                : candidate.normalizedIngredient.lowercased()
            return candidateKey == key
        }
        let batch = Firestore.firestore().batch()
        for linked in linkedItems {
            guard let id = linked.id else { continue }
            batch.updateData(["isPurchased": willBePurchased], forDocument: itemsCollection.document(id))
        }
        batch.commit { error in
            guard error == nil, willBePurchased else { return }
            addPurchasedItemToActivePantry(item)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func addPurchasedItemToActivePantry(_ item: GroceryListItem) {
        guard let selectedPantryId else { return }
        let parsedName = ingredientDisplayParts(from: item.ingredientDisplay).name
        let ingredient = (parsedName.isEmpty ? item.normalizedIngredient : parsedName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ingredient.isEmpty else { return }

        let category = pantryCategory(for: ingredient)
        Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("pantrySpaces")
            .document(selectedPantryId)
            .updateData([
                "virtualPantry.\(category)": FieldValue.arrayUnion([ingredient])
            ])
    }

    private func pantryCategory(for ingredient: String) -> String {
        let value = ingredient.lowercased()

        if ["chicken", "beef", "pork", "turkey", "fish", "salmon", "shrimp", "tofu", "tempeh", "egg", "paneer"]
            .contains(where: value.contains) {
            return "Protein"
        }
        if ["milk", "cheese", "yogurt", "cream", "butter", "mozzarella"]
            .contains(where: value.contains) {
            return "Dairy"
        }
        if ["water", "juice", "coffee", "tea", "soda", "drink"]
            .contains(where: value.contains) {
            return "Beverages"
        }
        if ["sauce", "ketchup", "mustard", "mayo", "dressing", "vinegar", "paste"]
            .contains(where: value.contains) {
            return "Condiments"
        }
        if ["salt", "pepper", "paprika", "cumin", "turmeric", "oregano", "basil", "spice", "seasoning"]
            .contains(where: value.contains) {
            return "Spices"
        }
        if ["rice", "pasta", "flour", "sugar", "oat", "bread", "noodle", "bean", "lentil", "oil", "grain"]
            .contains(where: value.contains) {
            return "Pantry"
        }
        if ["chip", "cracker", "cookie", "snack", "bar", "popcorn"]
            .contains(where: value.contains) {
            return "Snacks"
        }
        return "Produce"
    }

    private func removePurchasedItems() {
        let purchased = items.filter { $0.isPurchased }
        guard !purchased.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let batch = Firestore.firestore().batch()
        for item in purchased {
            guard let id = item.id else { continue }
            batch.deleteDocument(itemsCollection.document(id))
        }

        batch.commit { error in
            if error == nil {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func removeRecipeGroup(_ group: GroceryRecipeGroup) {
        guard !group.items.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let batch = Firestore.firestore().batch()
        for item in group.items {
            guard let id = item.id else { continue }
            batch.deleteDocument(itemsCollection.document(id))
        }

        batch.commit { error in
            if error == nil {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func startMatchTimer() {
        stopMatchTimer()
        matchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            matchAnimationStep += 1
        }
    }

    private func stopMatchTimer() {
        matchTimer?.invalidate()
        matchTimer = nil
        matchAnimationStep = 0
    }

    private func matchStoreProducts(targetItems: [GroceryListItem]? = nil, force: Bool) async {
        guard !isMatchingStoreProducts else { return }
        let store = selectedStore
        let source = targetItems ?? filteredItems
        let unresolved = source.filter { item in
            guard !item.isPurchased else { return false }
            guard isAlwaysAvailableIngredient(item.normalizedIngredient.isEmpty ? item.ingredientDisplay : item.normalizedIngredient) == false else { return false }
            if force { return true }
            return item.hasStoreMatchAttempt(for: store) == false
        }
        guard !unresolved.isEmpty else { return }

        await MainActor.run {
            isMatchingStoreProducts = true
            startMatchTimer()
        }

        do {
            try await assistant.waitUntilReady()

            let ingredients = unresolved.map { item in
                item.normalizedIngredient.isEmpty
                ? normalizedIngredientKey(from: item.ingredientDisplay)
                : item.normalizedIngredient
            }

            let matches = try await assistant.fetchStoreMatches(
                ingredients: ingredients,
                store: store,
                budgetPreference: budgetPreference
            )

            for item in unresolved {
                guard let id = item.id else { continue }
                let key = item.normalizedIngredient.isEmpty
                    ? normalizedIngredientKey(from: item.ingredientDisplay)
                    : item.normalizedIngredient
                let products = matches[key] ?? []

                var updated = item
                var allMatches = updated.matchesByStore
                allMatches[store.rawValue] = products
                updated.matchesByStore = allMatches
                var attemptedStores = updated.matchAttemptedStores ?? [:]
                attemptedStores[store.rawValue] = Date()
                updated.matchAttemptedStores = attemptedStores
                updated.id = nil
                try itemsCollection.document(id).setData(from: updated, merge: true)
            }

            await MainActor.run {
                isMatchingStoreProducts = false
                stopMatchTimer()
            }
        } catch {
            await MainActor.run {
                isMatchingStoreProducts = false
                stopMatchTimer()
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func groceryHeroPill(title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct GroceryStatTile: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct GroceryListItemRow: View {
    let item: GroceryListItem
    let store: GroceryStore
    let isMatching: Bool
    let onTogglePurchased: () -> Void
    let onFindMatch: () -> Void
    @State private var showProductSheet = false
    @AppStorage(chefBuddyMeasurementSystemDefaultsKey) private var measurementSystem = "🇺🇸 US cups & ounces"

    private var selectedStoreMatches: [GroceryStoreProduct] {
        item.matchesByStore[store.rawValue] ?? []
    }

    private var hasCheckedSelectedStore: Bool {
        item.hasStoreMatchAttempt(for: store)
    }

    private var displayedIngredient: IngredientDisplayParts {
        _ = measurementSystem
        return ingredientDisplayParts(
            from: [item.quantityHint, item.ingredientDisplay]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: " ")
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Button(action: onTogglePurchased) {
                Image(systemName: item.isPurchased ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(item.isPurchased ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayedIngredient.name.isEmpty ? preferredIngredientText(item.ingredientDisplay) : displayedIngredient.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(item.isPurchased ? .secondary : .primary)
                    .strikethrough(item.isPurchased, color: .secondary)
                    .lineLimit(2)

            }

            Spacer(minLength: 6)
            matchControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(item.isPurchased ? Color.green.opacity(0.055) : Color.primary.opacity(0.035))
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: item.isPurchased)
        .sheet(isPresented: $showProductSheet) {
            GroceryProductMatchSheet(
                ingredient: displayedIngredient.name.isEmpty ? preferredIngredientText(item.ingredientDisplay) : displayedIngredient.name,
                store: store,
                products: selectedStoreMatches
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var matchControl: some View {
        if item.isPurchased {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.green)
        } else if let bestMatch = selectedStoreMatches.first {
            Button {
                ChefBuddyHaptics.selection()
                showProductSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bag.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(width: 28, height: 28)
                        .background(Color.orange.opacity(0.12), in: Circle())
                    VStack(alignment: .trailing, spacing: 2) {
                    Text(bestMatch.price)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary)
                        Text("\(selectedStoreMatches.count) choices")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.orange.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
        } else {
            Button(action: onFindMatch) {
                Label(
                    isMatching ? "Matching" : hasCheckedSelectedStore ? "Retry" : "Match",
                    systemImage: isMatching ? "ellipsis" : "sparkles"
                )
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(hasCheckedSelectedStore ? Color.secondary : Color.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.055), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isMatching)
        }
    }
}

private struct GroceryProductMatchSheet: View {
    let ingredient: String
    let store: GroceryStore
    let products: [GroceryStoreProduct]

    @Environment(\.dismiss) private var dismiss
    @State private var animateGlow = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.18, green: 0.09, blue: 0.04), .black, Color(red: 0.03, green: 0.15, blue: 0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Circle()
                    .fill(Color.orange.opacity(animateGlow ? 0.22 : 0.10))
                    .frame(width: 300, height: 300)
                    .blur(radius: 70)
                    .offset(x: 150, y: -260)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(spacing: 10) {
                            Image(systemName: "bag.badge.plus")
                                .font(.system(size: 27, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .shadow(color: .orange.opacity(0.30), radius: 20, y: 10)

                            Text("SMART PRODUCT MATCH")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .tracking(0.9)
                                .foregroundStyle(.orange)
                            Text(ingredient)
                                .font(.system(size: 29, weight: .heavy, design: .rounded))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(store.emoji) \(store.rawValue)  ·  \(products.count) choices")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)

                        ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                            VStack(alignment: .leading, spacing: 11) {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: index == 0 ? "crown.fill" : "shippingbox.fill")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(index == 0 ? .white : .orange)
                                        .frame(width: 44, height: 44)
                                        .background(index == 0 ? Color.orange : Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(index == 0 ? "BEST FIT" : "ALTERNATIVE \(index)")
                                        .font(.system(size: 9, weight: .black, design: .rounded))
                                        .foregroundStyle(index == 0 ? .orange : .secondary)
                                        Text(product.name)
                                            .font(.system(size: index == 0 ? 18 : 15, weight: .bold, design: .rounded))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text([product.brand, product.size, product.section].filter { !$0.isEmpty }.joined(separator: " • "))
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 4)

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(product.price)
                                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                                        Text(index == 0 ? "recommended" : "option")
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if !product.note.isEmpty {
                                    Label(product.note, systemImage: "info.circle")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }

                                if let url = store.searchURL(for: product) {
                                    Link(destination: url) {
                                        HStack {
                                            Text("View at \(store.rawValue)")
                                            Spacer()
                                            Image(systemName: "arrow.up.right")
                                        }
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(index == 0 ? .white : .orange)
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 11)
                                        .background(index == 0 ? Color.orange : Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                    }
                                }
                            }
                            .padding(index == 0 ? 19 : 15)
                            .background(
                                index == 0
                                    ? AnyShapeStyle(LinearGradient(colors: [Color.orange.opacity(0.20), Color.green.opacity(0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(.ultraThinMaterial),
                                in: RoundedRectangle(cornerRadius: index == 0 ? 26 : 20, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(index == 0 ? Color.orange.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 1)
                            )
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Product Choices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                animateGlow = true
            }
        }
    }
}


struct RecipeReviewView: View {
    let recipe: Recipe
    let assistant: CookingAssistant
    let userId: String
    let onComplete: (Recipe, Set<String>, String, String) -> Void

    @Environment(\.dismiss) var dismiss
    @State private var selectedLiked: Set<String> = []
    @State private var likedNote = ""
    @State private var improvementText = ""
    @State private var isRegenerating = false
    @State private var revisedRecipe: Recipe? = nil
    @State private var showConfirmation = false
    @State private var scanAnimationStep = 0
    @State private var timer: Timer?
    @State private var showFinishedDishPicker = false
    @State private var finishedDishImage: UIImage? = nil
    @State private var isCompletingCook = false
    @State private var cookedPhotoError: String? = nil
    @FocusState private var focusedField: Bool

    let likedOptions = [
        "🔥 Flavour", "⏱️ Cook Time", "🥗 Ingredients",
        "📋 Instructions", "🍽️ Portion Size", "💰 Budget-Friendly",
        "😊 Easy to Make", "🌶️ Spice Level"
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                Circle().fill(Color.orange.opacity(0.10)).blur(radius: 80).offset(x: -160, y: -200).ignoresSafeArea()
                Circle().fill(Color.green.opacity(0.08)).blur(radius: 80).offset(x: 160, y: 300).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {


                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 14) {
                                Text(recipe.emoji).font(.system(size: 52))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("How was it?")
                                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                                    Text(recipe.title)
                                        .font(.system(size: 15))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Text("Your feedback helps ChefBuddy improve this recipe just for you.")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .lineSpacing(4)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)


                        NutritionBreakdownCard(nutrition: recipe.nutrition, calories: recipe.calories)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Label("Add the finished dish", systemImage: "camera.fill")
                                        .font(.system(size: 17, weight: .bold, design: .rounded))
                                    Text("Optional • saved to this recipe’s Cooking Gallery")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    showFinishedDishPicker = true
                                } label: {
                                    Text(finishedDishImage == nil ? "Choose Photo" : "Change")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(.pink)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 8)
                                        .background(Color.pink.opacity(0.11), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }

                            if let finishedDishImage {
                                Image(uiImage: finishedDishImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 210)
                                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                                    )
                            } else {
                                HStack(spacing: 11) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(.pink)
                                    Text("Capture how this cook turned out and build a visual history over time.")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.pink.opacity(0.07), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                            }
                        }
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.pink.opacity(0.13), lineWidth: 1)
                        )
                        .padding(.horizontal, 24)


                        VStack(alignment: .leading, spacing: 14) {
                            Label("What did you love?", systemImage: "heart.fill")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 24)

                            LazyVGrid(
                                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                                spacing: 10
                            ) {
                                ForEach(likedOptions, id: \.self) { option in
                                    let selected = selectedLiked.contains(option)
                                    Button(action: {
                                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                        if selected { selectedLiked.remove(option) } else { selectedLiked.insert(option) }
                                    }) {
                                        Text(option)
                                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                                            .foregroundStyle(selected ? .white : .primary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 10)
                                            .frame(maxWidth: .infinity)
                                            .background(
                                                selected
                                                ? AnyView(LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                                                : AnyView(Color(.systemGray6))
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 24)

                            TextField("Anything else you loved? (optional)", text: $likedNote, axis: .vertical)
                                .font(.system(size: 15, design: .rounded))
                                .padding(14)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .lineLimit(3)
                                .padding(.horizontal, 24)
                                .focused($focusedField)
                        }


                        VStack(alignment: .leading, spacing: 12) {
                            Label("What would you improve?", systemImage: "wand.and.stars")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 24)

                            Text("Be specific — e.g. \"less salt\", \"add more garlic\", \"simpler steps\", \"bigger portions\"")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 24)

                            TextField("Describe what you'd change...", text: $improvementText, axis: .vertical)
                                .font(.system(size: 15, design: .rounded))
                                .padding(14)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .lineLimit(5)
                                .padding(.horizontal, 24)
                                .focused($focusedField)
                        }


                        if let revised = revisedRecipe {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.orange)
                                    Text("ChefBuddy revised your recipe!")
                                        .font(.system(size: 17, weight: .bold, design: .rounded))
                                }
                                .padding(.horizontal, 24)

                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 12) {
                                        Text(revised.emoji).font(.system(size: 40))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(revised.title)
                                                .font(.system(size: 18, weight: .heavy, design: .rounded))
                                            Text(revised.description)
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }

                                    HStack(spacing: 10) {
                                        Label(revised.cookTime, systemImage: "clock")
                                        Label(revised.servings, systemImage: "person.2")
                                        Label(revised.calories.isEmpty ? "—" : revised.calories, systemImage: "flame")
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)

                                    Divider()

                                    NutritionBreakdownCard(nutrition: revised.nutrition, calories: revised.calories)
                                        .padding(.horizontal, -16)

                                    Divider()

                                    Text("Tap **Save & Update Recipe** below to replace your current recipe with this improved version.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineSpacing(3)
                                }
                                .padding(16)
                                .background(
                                    LinearGradient(
                                        colors: [.orange.opacity(0.07), .green.opacity(0.06)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.2), lineWidth: 1))
                                .padding(.horizontal, 24)
                            }
                        }


                        VStack(spacing: 12) {
                            if revisedRecipe == nil {

                                Button(action: generateRevision) {
                                    HStack(spacing: 10) {
                                        if isRegenerating {
                                            Text("🍳")
                                                .scaleEffect(scanAnimationStep % 2 == 0 ? 0.9 : 1.1)
                                                .animation(.spring(response: 0.35, dampingFraction: 0.65), value: scanAnimationStep)

                                            Text("ChefBuddy is revising...")
                                                .font(.system(size: 17, weight: .bold, design: .rounded))

                                            RecipeBouncingDotsView(step: scanAnimationStep, color: .white)
                                        } else {
                                            Image(systemName: "sparkles")
                                            Text(
                                                improvementText.trimmingCharacters(in: .whitespaces).isEmpty
                                                ? "Save & Mark as Cooked"
                                                : "Revise Recipe with AI & Mark as Cooked"
                                            )
                                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                        }
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 56)
                                    .background(
                                        LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .clipShape(Capsule())
                                    .shadow(color: .orange.opacity(0.3), radius: 10, y: 4)
                                }
                                .disabled(isRegenerating)
                            } else {

                                Button(action: {
                                    if let revised = revisedRecipe {
                                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                                        completeCook(revised, improvement: improvementText)
                                    }
                                }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("Save & Update Recipe")
                                            .font(.system(size: 17, weight: .bold, design: .rounded))
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 56)
                                    .background(
                                        LinearGradient(colors: [.green, .green.opacity(0.75)], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .clipShape(Capsule())
                                    .shadow(color: .green.opacity(0.3), radius: 10, y: 4)
                                }


                                Button(action: {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    var cooked = recipe
                                    cooked.cookedCount = recipe.cookedCount + 1
                                    cooked.lastCookedAt = Date()
                                    completeCook(cooked, improvement: improvementText)
                                }) {
                                    Text("Keep Original & Mark Cooked")
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 48)
                                        .background(Color(.systemGray6))
                                        .clipShape(Capsule())
                                }
                            }


                            Button(action: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                dismiss()
                            }) {
                                Text("Skip for Now")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Mark as Cooked")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showFinishedDishPicker) {
            CookedDishImagePicker { image in
                finishedDishImage = image
            }
            .ignoresSafeArea()
        }
        .alert("Finished Dish Photo", isPresented: Binding(
            get: { cookedPhotoError != nil },
            set: { if !$0 { cookedPhotoError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cookedPhotoError ?? "")
        }
    }

    private func generateRevision() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let hasImprovements = !improvementText.trimmingCharacters(in: .whitespaces).isEmpty
        guard hasImprovements else {

            var cooked = recipe
            cooked.cookedCount = recipe.cookedCount + 1
            cooked.lastCookedAt = Date()
            completeCook(cooked, improvement: "")
            return
        }

        isRegenerating = true

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            scanAnimationStep += 1
        }

        Task {
            do {
                try await assistant.waitUntilReady()

                let likedList = selectedLiked.isEmpty ? "everything overall" : selectedLiked.joined(separator: ", ")
                let originalIngredients = recipe.ingredients.map { "- \($0)" }.joined(separator: "\n")
                let originalSteps = recipe.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

                let prompt = """
                I cooked "\(recipe.title)" and want you to improve it based on my feedback.

                What I liked: \(likedList)
                \(likedNote.isEmpty ? "" : "Additional notes on what I liked: \(likedNote)")
                What I want improved: \(improvementText)

                Current recipe:
                Ingredients:
                \(originalIngredients)

                Instructions:
                \(originalSteps)

                Please revise the recipe incorporating my feedback. Keep what I liked, and specifically address my improvements.

                Respond ONLY in this exact format, no extra text:
                Title: [recipe name]
                Emoji: [single relevant emoji]
                Description: [one sentence about the dish]
                Cook Time: [e.g. 25 mins]
                Servings: [e.g. 2 people]
                Difficulty: [Easy / Medium / Hard]
                Calories: [e.g. 420 kcal]
                Carbs: [e.g. 42g]
                Protein: [e.g. 35g]
                Fat: [e.g. 12g]
                Saturated Fat: [e.g. 4g]
                Sugar: [e.g. 8g]
                Fiber: [e.g. 5g]
                Sodium: [e.g. 620mg]
                Tags: [comma-separated]

                Ingredients:
                - [ingredient 1]
                - [ingredient 2]

                Instructions:
                1. [step one]
                2. [step two]

                Rules for quality:
                - include precise ingredient amounts/units
                - include prep details where relevant (washing, dicing, preheating, marinating)
                - include timing and doneness cues in instructions
                - keep instructions detailed and easy to follow
                - include at least one cuisine tag
                """

                let raw = try await assistant.getHelp(question: prompt)
                var revised = RecipesViewModel.parseRecipe(from: raw)
                revised.id = recipe.id
                revised.createdAt = recipe.createdAt
                revised.isFavorite = recipe.isFavorite
                revised.cookedCount = recipe.cookedCount + 1
                revised.lastCookedAt = Date()

                await MainActor.run {
                    self.timer?.invalidate()
                    self.revisedRecipe = revised
                    self.isRegenerating = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    self.timer?.invalidate()
                    self.isRegenerating = false
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func completeCook(_ cookedRecipe: Recipe, improvement: String) {
        guard !isCompletingCook else { return }
        isCompletingCook = true

        Task {
            do {
                if let image = finishedDishImage, let recipeId = recipe.id {
                    try await CookedDishGalleryStore.upload(
                        image: image,
                        userId: userId,
                        recipeId: recipeId,
                        recipeTitle: cookedRecipe.title,
                        recipeEmoji: cookedRecipe.emoji
                    )
                }
                await MainActor.run {
                    isCompletingCook = false
                    ChefBuddyHaptics.success()
                    onComplete(cookedRecipe, selectedLiked, likedNote, improvement)
                }
            } catch {
                await MainActor.run {
                    isCompletingCook = false
                    cookedPhotoError = "The dish is not marked cooked yet because the photo could not be saved. Please try again, or remove the photo to continue."
                    ChefBuddyHaptics.error()
                }
            }
        }
    }
}
