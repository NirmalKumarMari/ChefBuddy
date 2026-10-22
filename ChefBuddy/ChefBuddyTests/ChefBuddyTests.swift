//
//  ChefBuddyTests.swift
//  ChefBuddyTests
//
//  Created by Hrudhai Umas on 3/3/26.
//

import Testing
import Foundation
@testable import ChefBuddy

struct ChefBuddyTests {

    @Test func retailerSearchURLsUseOfficialDomainsAndEncodeQueries() throws {
        let product = GroceryStoreProduct(
            name: "Organic Firm Tofu",
            brand: "Store Brand",
            size: "14 oz",
            price: "$3.49",
            section: "Produce",
            note: ""
        )

        let expectedHosts: [GroceryStore: String] = [
            .safeway: "www.safeway.com",
            .walmart: "www.walmart.com",
            .costco: "www.costco.com",
            .traderJoes: "www.traderjoes.com",
            .amazon: "www.amazon.com"
        ]

        for store in GroceryStore.allCases {
            let url = try #require(store.searchURL(for: product))
            #expect(url.host == expectedHosts[store])
            #expect(url.absoluteString.contains("Store"))
            #expect(url.absoluteString.contains("Tofu"))
            #expect(url.absoluteString.contains(" ") == false)
        }
    }

    @Test func currentWeekStartsOnMondayAndCrossesMonthBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 12)))
        let week = mealPlanWeekDates(containing: date, calendar: calendar)

        #expect(week.count == 7)
        #expect(week.first?.day == "Monday")
        #expect(calendar.component(.month, from: try #require(week.first?.date)) == 6)
        #expect(calendar.component(.day, from: try #require(week.first?.date)) == 29)
        #expect(week.last?.day == "Sunday")
    }

    @Test func sharedRecipeSnapshotResetsPersonalState() {
        var original = sampleRecipe()
        original.isFavorite = true
        original.cookedCount = 7
        original.lastCookedAt = Date()

        let snapshot = SharedRecipeSnapshot(recipe: original, ownerId: "owner")
        let imported = snapshot.recipe

        #expect(imported.isFavorite == false)
        #expect(imported.cookedCount == 0)
        #expect(imported.lastCookedAt == nil)
        #expect(imported.title == original.title)
        #expect(imported.ingredients == original.ingredients)
    }

    @Test func equivalentRecipesIgnorePersonalMetadata() {
        var lhs = sampleRecipe()
        var rhs = sampleRecipe()
        lhs.isFavorite = true
        lhs.cookedCount = 4
        rhs.createdAt = Date().addingTimeInterval(900)

        #expect(RecipeShareService.isEquivalent(lhs, rhs))
        rhs.ingredients.append("1 lime")
        #expect(RecipeShareService.isEquivalent(lhs, rhs) == false)
    }

    @MainActor
    @Test func deepLinkRouterRetainsRecipeID() throws {
        let router = ChefBuddyDeepLinkRouter.shared
        router.clear()
        let url = try #require(URL(string: "chefbuddy://recipe/share-123"))

        #expect(router.handle(url))
        #expect(router.pendingShareID == "share-123")
        router.clear()
    }

    @Test func nutritionTargetsClampUnsafeValues() {
        let targets = NutritionTargets.validated(
            calories: 300,
            carbs: 2,
            protein: 900,
            fat: 0,
            sodium: 9000,
            source: .manual
        )

        #expect(targets.calories == 800)
        #expect(targets.carbs == 25)
        #expect(targets.protein == 400)
        #expect(targets.fat == 15)
        #expect(targets.sodium == 6000)
    }

    @Test func streakDoesNotIncrementTwiceOnSameDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 16))!
        let earlier = calendar.date(byAdding: .hour, value: -2, to: now)
        let value = GrowthEngine.nextStreakValue(lastActivityDate: earlier, now: now, currentValue: 4)
        #expect(value == 4)
    }

    @Test func streakIncrementsOnConsecutiveDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let value = GrowthEngine.nextStreakValue(lastActivityDate: yesterday, now: now, currentValue: 4)
        #expect(value == 5)
    }

    @Test func streakResetsAfterMissedDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let threeDaysAgo = try #require(calendar.date(byAdding: .day, value: -3, to: now))

        #expect(GrowthEngine.nextStreakValue(lastActivityDate: threeDaysAgo, now: now, currentValue: 8) == 1)
        #expect(GrowthEngine.refreshedStreakValue(lastActivityDate: threeDaysAgo, now: now, currentValue: 8) == 0)
    }

    @MainActor
    @Test func aiMealSlotPrefersEmbeddedRecipeEvenWithStaleSavedID() {
        let recipe = sampleRecipe()
        let slot = MealPlanSlot(
            id: "Monday-Dinner",
            day: "Monday",
            mealType: "Dinner",
            recipeId: "old-saved-recipe",
            recipeTitle: recipe.title,
            plannedRecipe: PlannedMealRecipe(recipe: recipe),
            status: .planned,
            completedAt: nil,
            consumedNutritionSnapshot: nil,
            sourceType: .ai
        )

        #expect(
            mealPlanDetailResolution(
                for: slot,
                availableRecipeIDs: ["old-saved-recipe"]
            ) == .embeddedRecipe
        )
    }

    @MainActor
    @Test func savedMealSlotUsesLiveRecipeThenEmbeddedFallback() {
        let recipe = sampleRecipe()
        let slot = MealPlanSlot(
            id: "Tuesday-Lunch",
            day: "Tuesday",
            mealType: "Lunch",
            recipeId: "saved-recipe",
            recipeTitle: recipe.title,
            plannedRecipe: PlannedMealRecipe(recipe: recipe),
            status: .planned,
            completedAt: nil,
            consumedNutritionSnapshot: nil,
            sourceType: .saved
        )

        #expect(
            mealPlanDetailResolution(
                for: slot,
                availableRecipeIDs: ["saved-recipe"]
            ) == .savedRecipe("saved-recipe")
        )
        #expect(
            mealPlanDetailResolution(
                for: slot,
                availableRecipeIDs: []
            ) == .embeddedRecipe
        )
    }

    @Test func mealPlanSlotAdaptsLegacyAndMultiEntryPlans() {
        let first = sampleRecipe()
        var second = sampleRecipe()
        second.title = "Rasam"
        second.emoji = "🍲"

        let legacy = MealPlanSlot(
            id: "Monday-Lunch",
            day: "Monday",
            mealType: "Lunch",
            recipeId: "legacy",
            recipeTitle: first.title,
            plannedRecipe: PlannedMealRecipe(recipe: first),
            status: .planned,
            completedAt: nil,
            consumedNutritionSnapshot: nil,
            sourceType: .saved
        )

        #expect(legacy.plannedEntries.count == 1)
        #expect(legacy.displayTitle == first.title)

        let multi = MealPlanSlot(
            id: "Monday-Lunch",
            day: "Monday",
            mealType: "Lunch",
            recipeId: "first",
            recipeTitle: first.title,
            plannedRecipe: PlannedMealRecipe(recipe: first),
            status: .planned,
            completedAt: nil,
            consumedNutritionSnapshot: nil,
            sourceType: .saved,
            entries: [
                MealPlanEntry(recipe: first, sourceType: .saved),
                MealPlanEntry(recipe: second, sourceType: .custom)
            ]
        )

        #expect(multi.plannedEntries.count == 2)
        #expect(multi.displayTitle == "2 dishes planned")
        #expect(multi.isCompleted == false)
    }

    @Test func ingredientPresentationParsesQuantityAndChoosesSmartEmoji() {
        let parts = ingredientDisplayParts(from: "1 1/2 cups all-purpose flour")

        #expect(parts.quantity == "1 1/2 cups")
        #expect(parts.name == "all-purpose flour")
        #expect(ingredientEmoji(for: "all-purpose flour") == "🍞")
        #expect(ingredientEmoji(for: "2 tbsp olive oil") == "🫒")
        #expect(ingredientEmoji(for: "🥬 Baby spinach") == "🥬")
    }

    @Test func pantryGroupingFindsOnlyMissingIngredients() {
        let ingredients = ["2 cups baby spinach", "1 lb chicken breast", "1 lemon"]
        let pantry = ["🥬 Baby spinach", "🍋 Lemon"]

        #expect(missingIngredients(from: ingredients, pantryIngredients: pantry) == ["1 lb chicken breast"])
    }

    @Test func waterIsAlwaysTreatedAsAvailable() {
        let ingredients = ["250 ml water", "1 lb chicken breast", "water chestnuts"]

        #expect(isAlwaysAvailableIngredient("250 ml water"))
        #expect(isAlwaysAvailableIngredient("water chestnuts") == false)
        #expect(missingIngredients(from: ingredients, pantryIngredients: []) == ["1 lb chicken breast", "water chestnuts"])
    }

    @Test func groceryStoreMatchAttemptsAreCachedPerStore() {
        let product = GroceryStoreProduct(
            name: "Firm Tofu",
            brand: "House",
            size: "14 oz",
            price: "$3.99",
            section: "Refrigerated",
            note: ""
        )
        var item = GroceryListItem(
            id: "tofu",
            ingredientDisplay: "14 oz firm tofu",
            normalizedIngredient: "firm tofu",
            quantityHint: "14 oz",
            recipeId: "recipe",
            recipeTitle: "Tofu Bowl",
            recipeEmoji: "🥣",
            isPurchased: false,
            createdAt: Date(),
            matchesByStore: [:],
            matchAttemptedStores: nil
        )

        #expect(item.hasStoreMatchAttempt(for: .safeway) == false)
        item.matchAttemptedStores = [GroceryStore.safeway.rawValue: Date()]
        #expect(item.hasStoreMatchAttempt(for: .safeway))
        #expect(item.hasStoreMatchAttempt(for: .walmart) == false)
        item.matchesByStore[GroceryStore.walmart.rawValue] = [product]
        #expect(item.hasStoreMatchAttempt(for: .walmart))
    }

    @Test func aiErrorsNeverExposeSDKDetails() {
        let rawError = NSError(
            domain: "FirebaseAILogic.GenerateContentError",
            code: 0,
            userInfo: nil
        )
        let presentation = chefBuddyAIErrorPresentation(for: rawError)

        #expect(presentation.message.contains("Firebase") == false)
        #expect(presentation.message.contains("error 0") == false)
        #expect(presentation.retryGuidance.isEmpty == false)
    }

    @Test func transientAIRequestRetriesExactlyOnce() async throws {
        var attempts = 0
        let value: Int = try await retryingTransientChefBuddyAI(delayNanoseconds: 0) {
            attempts += 1
            if attempts == 1 {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            }
            return 42
        }

        #expect(value == 42)
        #expect(attempts == 2)
    }

    @MainActor
    @Test func streakSummaryReconstructsCurrentAndLongestRuns() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 12)))
        let offsets = [-8, -7, -6, -2, -1, 0]
        let dates = try offsets.map { offset in
            try #require(calendar.date(byAdding: .day, value: offset, to: now))
        }

        let summary = GrowthEngine.streakSummary(activityDates: dates, now: now, calendar: calendar)
        #expect(summary.current == 3)
        #expect(summary.longest == 3)
    }

    @MainActor
    @Test func liveCookingPromptCarriesRecipeAndStepContext() {
        let recipe = Recipe(
            title: "Crispy Tofu Bowl",
            emoji: "🥣",
            description: "A bright weeknight bowl.",
            ingredients: ["14 oz firm tofu", "1 cup cooked rice"],
            steps: [
                "Press and cube the tofu.",
                "Cook over medium-high heat for 8 minutes until crisp.",
                "Serve over rice."
            ],
            cookTime: "25 mins",
            servings: "2 people",
            difficulty: "Easy",
            tags: ["Asian"],
            calories: "430 kcal",
            nutrition: .empty
        )

        let prompt = liveCookingQuestionPrompt(
            question: "Is the tofu done?",
            recipe: recipe,
            stepIndex: 1,
            recentConversation: ["Cook: It is sticking.", "ChefBuddy: Add a teaspoon of oil."]
        )

        #expect(prompt.contains("14 oz firm tofu"))
        #expect(prompt.contains("CURRENT STEP 2"))
        #expect(prompt.contains("Serve over rice."))
        #expect(prompt.contains("observable cue"))
        #expect(prompt.contains("Do not say generic things"))
    }

    @Test func ingredientMeasurementsFollowSavedPreferenceAcrossDisplays() {
        let original = UserDefaults.standard.string(forKey: chefBuddyMeasurementSystemDefaultsKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: chefBuddyMeasurementSystemDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: chefBuddyMeasurementSystemDefaultsKey)
            }
        }

        persistChefBuddyMeasurementSystem("🌍 Metric grams & ml")
        #expect(preferredIngredientText("1 cup milk") == "240 ml milk")
        #expect(preferredIngredientText("8 oz paneer") == "227 g paneer")

        persistChefBuddyMeasurementSystem("🇺🇸 US cups & ounces")
        #expect(preferredIngredientText("240 ml milk") == "1 cup milk")
        #expect(preferredIngredientText("500 g paneer") == "17.6 oz paneer")
    }

    private func sampleRecipe() -> Recipe {
        Recipe(
            title: "Crispy Tofu Bowl",
            emoji: "🥣",
            description: "A bright weeknight bowl.",
            ingredients: ["14 oz firm tofu", "1 cup cooked rice"],
            steps: ["Press and cube the tofu.", "Cook until crisp."],
            cookTime: "25 mins",
            servings: "2 people",
            difficulty: "Easy",
            tags: ["Asian"],
            calories: "430 kcal",
            nutrition: .empty
        )
    }

}
