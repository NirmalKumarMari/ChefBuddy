import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import UIKit
import Combine

struct SharedRecipeSnapshot: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var ownerId: String
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

    init(recipe: Recipe, ownerId: String, createdAt: Date = Date()) {
        self.ownerId = ownerId
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
        self.createdAt = createdAt
    }

    var recipe: Recipe {
        Recipe(
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
            createdAt: Date(),
            isFavorite: false,
            cookedCount: 0,
            lastCookedAt: nil
        )
    }
}

@MainActor
final class ChefBuddyDeepLinkRouter: ObservableObject {
    static let shared = ChefBuddyDeepLinkRouter()

    @Published var pendingShareID: String?

    private init() {}

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "chefbuddy" else { return false }

        let components = url.pathComponents.filter { $0 != "/" }
        let shareID: String?
        if url.host?.lowercased() == "recipe" {
            shareID = components.first
        } else if components.first?.lowercased() == "recipe" {
            shareID = components.dropFirst().first
        } else {
            shareID = nil
        }

        guard let shareID, !shareID.isEmpty else { return false }
        pendingShareID = shareID
        return true
    }

    func clear() {
        pendingShareID = nil
    }
}

final class RecipeShareService {
    static let shared = RecipeShareService()

    private let db = Firestore.firestore()

    private init() {}

    static func deepLink(for shareID: String) -> URL? {
        URL(string: "chefbuddy://recipe/\(shareID)")
    }

    static func normalizedRecipeSignature(_ recipe: Recipe) -> String {
        let ingredientSignature = recipe.ingredients
            .map { displayIngredientText(from: $0).lowercased() }
            .sorted()
            .joined(separator: "|")
        return "\(recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())::\(ingredientSignature)"
    }

    static func isEquivalent(_ lhs: Recipe, _ rhs: Recipe) -> Bool {
        normalizedRecipeSignature(lhs) == normalizedRecipeSignature(rhs)
    }

    func createSnapshot(for recipe: Recipe) async throws -> (SharedRecipeSnapshot, URL) {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw RecipeShareError.notSignedIn
        }

        let snapshot = SharedRecipeSnapshot(recipe: recipe, ownerId: userId)
        let reference = db.collection("sharedRecipes").document()
        try reference.setData(from: snapshot)

        guard let url = Self.deepLink(for: reference.documentID) else {
            throw RecipeShareError.invalidLink
        }

        var savedSnapshot = snapshot
        savedSnapshot.id = reference.documentID
        return (savedSnapshot, url)
    }

    func fetchSnapshot(id: String) async throws -> SharedRecipeSnapshot {
        let document = try await db.collection("sharedRecipes").document(id).getDocument()
        guard document.exists else { throw RecipeShareError.notFound }
        return try document.data(as: SharedRecipeSnapshot.self)
    }

    func importSnapshot(_ snapshot: SharedRecipeSnapshot, userId: String) async throws -> Recipe {
        var recipe = snapshot.recipe
        let reference = db.collection("users").document(userId).collection("recipes").document()
        try reference.setData(from: recipe)
        recipe.id = reference.documentID
        return recipe
    }

    func shareMessage(for recipe: Recipe, url: URL) -> String {
        var message = "Check out \(recipe.title) on ChefBuddy: \(url.absoluteString)"
        if let appStoreURL = Bundle.main.object(forInfoDictionaryKey: "CHEFBUDDY_APP_STORE_URL") as? String,
           !appStoreURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message += "\n\nDon’t have ChefBuddy? Download it here: \(appStoreURL)"
        }
        return message
    }
}

enum RecipeShareError: LocalizedError {
    case notSignedIn
    case invalidLink
    case notFound

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in before sharing a ChefBuddy recipe."
        case .invalidLink: return "ChefBuddy couldn’t create a share link."
        case .notFound: return "This shared recipe is no longer available."
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct RecipeShareButton: View {
    let recipe: Recipe
    var compact = true

    @State private var isPreparing = false
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var errorMessage: String?

    var body: some View {
        Button(action: prepareShare) {
            if compact {
                Group {
                    if isPreparing {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.ultraThinMaterial))
            } else {
                HStack(spacing: 8) {
                    if isPreparing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(isPreparing ? "Preparing..." : "Share Recipe")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .disabled(isPreparing)
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(activityItems: shareItems)
        }
        .alert("Couldn’t Share Recipe", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func prepareShare() {
        guard !isPreparing else { return }
        isPreparing = true
        Task {
            do {
                let (_, url) = try await RecipeShareService.shared.createSnapshot(for: recipe)
                let message = RecipeShareService.shared.shareMessage(for: recipe, url: url)
                await MainActor.run {
                    shareItems = [message, url]
                    isPreparing = false
                    showShareSheet = true
                }
            } catch {
                await MainActor.run {
                    isPreparing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct SharedRecipeImportView: View {
    let snapshot: SharedRecipeSnapshot
    let alreadySaved: Bool
    let onSave: () async -> Void
    let onDismiss: () -> Void

    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        Text(snapshot.emoji)
                            .font(.system(size: 82))
                            .frame(width: 140, height: 140)
                            .background(.ultraThinMaterial, in: Circle())

                        VStack(spacing: 8) {
                            Text("Shared with you")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                            Text(snapshot.title)
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .multilineTextAlignment(.center)
                            Text(snapshot.description)
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        HStack(spacing: 10) {
                            importMetric("clock", snapshot.cookTime, .orange)
                            importMetric("person.2", snapshot.servings, .blue)
                            importMetric("flame", snapshot.calories, .red)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Label("\(snapshot.ingredients.count) ingredients", systemImage: "carrot.fill")
                            Label("\(snapshot.steps.count) cooking steps", systemImage: "list.number")
                            Label(snapshot.difficulty, systemImage: "sparkles")
                        }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                        Button {
                            isSaving = true
                            Task {
                                await onSave()
                                await MainActor.run { isSaving = false }
                            }
                        } label: {
                            HStack {
                                if isSaving { ProgressView().tint(.white) }
                                Image(systemName: alreadySaved ? "checkmark.circle.fill" : "bookmark.fill")
                                Text(alreadySaved ? "Already in Your Recipes" : "Save to My Recipes")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(alreadySaved ? Color.green : Color.orange, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(alreadySaved || isSaving)
                    }
                    .padding(24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onDismiss)
                }
            }
        }
    }

    private func importMetric(_ icon: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
