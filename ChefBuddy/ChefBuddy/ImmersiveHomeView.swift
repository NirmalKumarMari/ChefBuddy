import SwiftUI
import FirebaseAuth
import Combine
import UIKit

private struct ImmersiveHomeStory: Identifiable {
    let id: Int
    let eyebrow: String
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let secondaryAccent: Color
    let actionTitle: String
}

private struct KitchenInspirationEntry {
    let text: String
    let source: String
    let symbol: String
}

/// A full-screen, vertically paged Home experience.
/// The former dashboard remains in MainTabShellView.swift so this can be reverted independently.
struct ImmersiveHomeView: View {
    @EnvironmentObject private var authVM: AuthViewModel

    let assistant: CookingAssistant
    let savedRecipes: [Recipe]
    @Binding var selectedTab: AppTab
    let onOpenGrocery: () -> Void
    let onOpenQuickGenerate: () -> Void
    let onOpenLiveCookingPicker: () -> Void

    @State private var currentPage: Int? = 0
    @State private var inspiration: KitchenInspirationEntry = Self.inspirations[0]
    @State private var animateAtmosphere = false
    @State private var showSwipeCoach = false
    @State private var animateSwipeCoach = false
    @AppStorage("chefbuddy.homeSwipeCoachSeen.v3") private var hasSeenSwipeCoach = false
    private let inspirationTimer = Timer.publish(every: 7.0, on: .main, in: .common).autoconnect()

    private static let inspirations: [KitchenInspirationEntry] = [
        KitchenInspirationEntry(text: "Home cooking has to be easy. It’s got to be fast. It’s got to be delicious.", source: "Gordon Ramsay", symbol: "flame.fill"),
        KitchenInspirationEntry(text: "My approach has always been about simplifying cooking.", source: "Jamie Oliver", symbol: "wand.and.stars"),
        KitchenInspirationEntry(text: "Remember, if you are alone in the kitchen, who is going to see you?", source: "Julia Child", symbol: "face.smiling"),
        KitchenInspirationEntry(text: "Where our ingredients come from is the most important question we can ask.", source: "Thomas Keller", symbol: "leaf.fill"),
        KitchenInspirationEntry(text: "Anyone can cook, but only the fearless can be great.", source: "Chef Gusteau • Ratatouille", symbol: "sparkles"),
        KitchenInspirationEntry(text: "Good food is like music you can taste, color you can smell.", source: "Chef Gusteau • Ratatouille", symbol: "music.note"),
        KitchenInspirationEntry(text: "The only way to get what you want in this world is through hard work.", source: "Tiana • The Princess and the Frog", symbol: "star.fill"),
        KitchenInspirationEntry(text: "You control your destiny. You don’t need magic to do it.", source: "Merida • Brave", symbol: "arrow.up.forward"),
        KitchenInspirationEntry(text: "The past can hurt. You can either run from it or learn from it.", source: "Rafiki • The Lion King", symbol: "book.fill"),
        KitchenInspirationEntry(text: "Family means no one gets left behind or forgotten.", source: "Lilo & Stitch", symbol: "person.3.fill"),
        KitchenInspirationEntry(text: "Season in layers, then taste before the final pinch.", source: "ChefBuddy Kitchen Tip", symbol: "drop.fill"),
        KitchenInspirationEntry(text: "A crowded pan steams. Give ingredients room to brown.", source: "ChefBuddy Kitchen Tip", symbol: "square.grid.3x3.fill"),
        KitchenInspirationEntry(text: "A small splash of acid can wake up a finished dish.", source: "ChefBuddy Kitchen Tip", symbol: "sun.max.fill"),
        KitchenInspirationEntry(text: "Prep the next ingredient while the current one cooks.", source: "ChefBuddy Kitchen Tip", symbol: "timer"),
        KitchenInspirationEntry(text: "Rest cooked proteins before slicing so their juices stay where they belong.", source: "ChefBuddy Kitchen Tip", symbol: "pause.circle.fill"),
        KitchenInspirationEntry(text: "Save a cup of pasta water before draining—it can bring a sauce together.", source: "ChefBuddy Kitchen Tip", symbol: "drop.circle.fill"),
        KitchenInspirationEntry(text: "Write the date on leftovers before they disappear into the fridge.", source: "ChefBuddy Kitchen Tip", symbol: "calendar.badge.clock"),
        KitchenInspirationEntry(text: "Sharp knives are safer because they need less force and slip less.", source: "ChefBuddy Kitchen Tip", symbol: "scissors"),
        KitchenInspirationEntry(text: "Taste as you go. The final spoonful should not be the first test.", source: "ChefBuddy Kitchen Tip", symbol: "mouth.fill"),
        KitchenInspirationEntry(text: "Dry vegetables before roasting so the oven can brown instead of steam.", source: "ChefBuddy Kitchen Tip", symbol: "flame.fill"),
        KitchenInspirationEntry(text: "Toast whole spices briefly before grinding to deepen their aroma.", source: "ChefBuddy Kitchen Tip", symbol: "sparkles"),
        KitchenInspirationEntry(text: "Keep one clean bowl beside the board for scraps and faster cleanup.", source: "ChefBuddy Kitchen Tip", symbol: "trash.fill"),
        KitchenInspirationEntry(text: "Warm plates keep a finished meal tasting intentional for longer.", source: "ChefBuddy Kitchen Tip", symbol: "circle.grid.2x2.fill"),
        KitchenInspirationEntry(text: "Salt the water before the food goes in, then adjust at the end.", source: "ChefBuddy Kitchen Tip", symbol: "drop.triangle.fill"),
        KitchenInspirationEntry(text: "A recipe has no soul. You bring the soul to the recipe.", source: "Thomas Keller", symbol: "heart.fill"),
        KitchenInspirationEntry(text: "Great cooking favors curiosity over perfection.", source: "ChefBuddy Inspiration", symbol: "lightbulb.fill")
    ]

    private var firstName: String {
        if let displayName = authVM.userSession?.displayName,
           let first = displayName.split(separator: " ").first {
            return String(first)
        }
        return "Chef"
    }

    private var stories: [ImmersiveHomeStory] {
        [
            ImmersiveHomeStory(
                id: 0,
                eyebrow: "KITCHEN INSPIRATION",
                title: inspiration.text,
                subtitle: inspiration.source,
                icon: inspiration.symbol,
                accent: Color(red: 0.96, green: 0.46, blue: 0.20),
                secondaryAccent: Color(red: 0.47, green: 0.19, blue: 0.11),
                actionTitle: "Fresh inspiration rotates automatically"
            ),
            ImmersiveHomeStory(
                id: 1,
                eyebrow: "CHEFBUDDY CREATOR",
                title: "What’s on your mind, \(firstName)?",
                subtitle: "Describe the craving, mood, time, or ingredients. ChefBuddy will shape it into a complete recipe.",
                icon: "wand.and.stars",
                accent: Color(red: 0.98, green: 0.50, blue: 0.24),
                secondaryAccent: Color(red: 0.46, green: 0.20, blue: 0.55),
                actionTitle: "Create My Recipe"
            ),
            ImmersiveHomeStory(
                id: 2,
                eyebrow: "LIVE COOKING",
                title: "Bring a sous-chef to the counter.",
                subtitle: "Start from a saved recipe—or simply show ChefBuddy what you have and talk through what to make.",
                icon: "waveform.and.mic",
                accent: Color(red: 0.45, green: 0.30, blue: 0.94),
                secondaryAccent: Color(red: 0.11, green: 0.34, blue: 0.56),
                actionTitle: "Enter Live Cooking"
            ),
            ImmersiveHomeStory(
                id: 3,
                eyebrow: "TODAY IN YOUR KITCHEN",
                title: savedRecipes.isEmpty ? "Your first favorite is waiting." : "\(savedRecipes.count) saved recipes. One delicious next move.",
                subtitle: savedRecipes.isEmpty
                    ? "Start a cookbook with one recipe you genuinely want to cook—not a pile of ideas you will never revisit."
                    : "Return to a favorite, finish today’s plan, or discover a new direction from your pantry.",
                icon: "fork.knife.circle.fill",
                accent: Color(red: 0.96, green: 0.28, blue: 0.42),
                secondaryAccent: Color(red: 0.45, green: 0.10, blue: 0.23),
                actionTitle: savedRecipes.isEmpty ? "Find My First Recipe" : "Open My Recipes"
            ),
            ImmersiveHomeStory(
                id: 4,
                eyebrow: "PANTRY INTELLIGENCE",
                title: "Cook from what is already yours.",
                subtitle: "Scan shelves, swipe between spaces, and turn stocked ingredients into practical recipe ideas.",
                icon: "basket.fill",
                accent: Color(red: 0.24, green: 0.68, blue: 0.42),
                secondaryAccent: Color(red: 0.07, green: 0.31, blue: 0.25),
                actionTitle: "Open My Pantry"
            ),
            ImmersiveHomeStory(
                id: 5,
                eyebrow: "PLAN • SHOP • COOK",
                title: "Let the week work as one system.",
                subtitle: "Shape your meal plan, collect only what is missing, and move purchased ingredients into the right pantry.",
                icon: "calendar.badge.checkmark",
                accent: Color(red: 0.19, green: 0.56, blue: 0.91),
                secondaryAccent: Color(red: 0.14, green: 0.24, blue: 0.53),
                actionTitle: "Open Meal Plan"
            ),
            ImmersiveHomeStory(
                id: 6,
                eyebrow: "GROCERY RUN",
                title: "A shorter path through the store.",
                subtitle: "Shop by recipe, see the best product match only when you need it, and keep purchased items organized.",
                icon: "cart.fill",
                accent: Color(red: 0.91, green: 0.55, blue: 0.17),
                secondaryAccent: Color(red: 0.42, green: 0.25, blue: 0.08),
                actionTitle: "Open Grocery List"
            )
        ]
    }

    var body: some View {
        let viewport = UIScreen.main.bounds.size

        GeometryReader { _ in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(stories) { story in
                        storyPage(story, size: viewport)
                            .frame(width: viewport.width, height: viewport.height)
                            .id(story.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
            .scrollPosition(id: $currentPage)
            .scrollClipDisabled(false)
            .clipped()
            .ignoresSafeArea()
            .sensoryFeedback(.selection, trigger: currentPage)
        }
        .frame(width: viewport.width, height: viewport.height)
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if showSwipeCoach {
                HStack(spacing: 9) {
                    VStack(spacing: 1) {
                        Image(systemName: "chevron.up")
                        Image(systemName: "chevron.up")
                    }
                    .font(.system(size: 10, weight: .black))
                    .offset(y: animateSwipeCoach ? -5 : 4)
                    Text("SWIPE UP TO EXPLORE")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.62), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                .padding(.top, 86)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            animateAtmosphere = true
            chooseFreshInspiration()
            guard !hasSeenSwipeCoach else { return }
            showSwipeCoach = true
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                animateSwipeCoach = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
                withAnimation(.easeOut(duration: 0.3)) { showSwipeCoach = false }
                hasSeenSwipeCoach = true
            }
        }
        .onChange(of: currentPage) { _, page in
            guard page != 0, showSwipeCoach else { return }
            withAnimation(.easeOut(duration: 0.25)) { showSwipeCoach = false }
            hasSeenSwipeCoach = true
        }
        .onReceive(inspirationTimer) { _ in
            guard currentPage == 0 else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                chooseFreshInspiration()
            }
        }
    }

    private func storyPage(_ story: ImmersiveHomeStory, size: CGSize) -> some View {
        ZStack {
            LinearGradient(
                colors: [story.secondaryAccent.opacity(0.98), Color.black, story.accent.opacity(0.44)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(story.accent.opacity(0.30))
                .frame(width: size.width * 0.88, height: size.width * 0.88)
                .blur(radius: 34)
                .offset(x: animateAtmosphere ? size.width * 0.28 : size.width * 0.12, y: -size.height * 0.22)
                .animation(.easeInOut(duration: 7).repeatForever(autoreverses: true), value: animateAtmosphere)

            Image(systemName: story.icon)
                .font(.system(size: min(size.width * 0.54, 220), weight: .ultraLight))
                .foregroundStyle(Color.white.opacity(0.09))
                .rotationEffect(.degrees(animateAtmosphere ? 8 : -5))
                .scaleEffect(animateAtmosphere ? 1.04 : 0.96)
                .animation(.easeInOut(duration: 5.5).repeatForever(autoreverses: true), value: animateAtmosphere)

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.16), Color.black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CHEFBUDDY")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .tracking(1.4)
                        Text("Swipe up to explore")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.66))
                    }
                    Spacer()
                    Text("\((story.id + 1).formatted(.number.precision(.integerLength(2))))")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .padding(.top, max(58, size.height * 0.07))

                Spacer(minLength: 12)

                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Color.black.opacity(0.22))

                    Image(systemName: story.icon)
                        .font(.system(size: 62, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 128, height: 128)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: story.accent.opacity(0.32), radius: 28, y: 14)
                .padding(.bottom, 34)

                Text(story.eyebrow)
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(story.accent)

                Text(story.title)
                    .font(.system(size: 37, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(-3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                Text(story.subtitle)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.80))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)

                if story.id == 0 {
                    Text(inspiration.source)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .padding(.top, 9)
                }

                if story.id == 0 {
                    Label("Fresh inspiration rotates automatically", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.top, 22)
                        .padding(.bottom, 8)
                } else {
                    Button {
                        perform(story)
                    } label: {
                        HStack(spacing: 10) {
                            Text(story.actionTitle)
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 54)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
                }

                Spacer(minLength: 104)
            }
            .padding(.horizontal, 26)
        }
        .clipped()
    }

    private func perform(_ story: ImmersiveHomeStory) {
        ChefBuddyHaptics.medium()
        switch story.id {
        case 0:
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                chooseFreshInspiration()
            }
        case 1:
            onOpenQuickGenerate()
        case 2:
            onOpenLiveCookingPicker()
        case 3:
            selectedTab = .recipes
        case 4:
            selectedTab = .pantry
        case 5:
            selectedTab = .plan
        default:
            onOpenGrocery()
        }
    }

    private func chooseFreshInspiration() {
        let candidates = Self.inspirations.filter {
            $0.text != inspiration.text
        }
        inspiration = candidates.randomElement() ?? Self.inspirations[0]
    }
}

enum KitchenJourneyStage: Int, CaseIterable {
    case recipes
    case pantry
    case plan
    case grocery

    var eyebrow: String {
        switch self {
        case .recipes: return "YOUR COOKBOOK"
        case .pantry: return "YOUR PANTRY"
        case .plan: return "YOUR MEAL PLAN"
        case .grocery: return "YOUR GROCERY LIST"
        }
    }

    var title: String {
        switch self {
        case .recipes: return "Save a recipe that feels like you."
        case .pantry: return "Create the space you actually cook from."
        case .plan: return "Put one meal on the calendar."
        case .grocery: return "See how missing ingredients become a shop."
        }
    }

    var detail: String {
        switch self {
        case .recipes: return "Browse pantry ideas or ChefBuddy Picks. Save one now, or continue when you are ready."
        case .pantry: return "Create your first pantry, then scan or add a few ingredients so recommendations have real context."
        case .plan: return "Open a day, add a meal, and see how nutrition targets stay connected to the week."
        case .grocery: return "Your list groups ingredients by recipe, matches products on demand, and adds purchased food back to Pantry."
        }
    }

    var icon: String {
        switch self {
        case .recipes: return "book.pages.fill"
        case .pantry: return "basket.fill"
        case .plan: return "calendar.badge.plus"
        case .grocery: return "cart.fill"
        }
    }

    var tint: Color {
        switch self {
        case .recipes: return .pink
        case .pantry: return .green
        case .plan: return .blue
        case .grocery: return .orange
        }
    }
}

struct PremiumGetStartedView: View {
    let onBegin: () -> Void
    let onSkip: () -> Void

    @State private var animate = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Circle()
                .fill(Color.orange.opacity(animate ? 0.30 : 0.16))
                .frame(width: 420, height: 420)
                .blur(radius: 78)
                .offset(x: 150, y: -340)

            Circle()
                .fill(Color.green.opacity(animate ? 0.20 : 0.09))
                .frame(width: 360, height: 360)
                .blur(radius: 86)
                .offset(x: -160, y: 370)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("CHEFBUDDY")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.74))
                    Spacer()
                    Button("Skip") {
                        ChefBuddyHaptics.light()
                        onSkip()
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                }

                Spacer()

                ZStack {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(.ultraThinMaterial)
                    Image("ChefBuddyLogo")
                        .resizable()
                        .scaledToFit()
                        .padding(17)
                        .offset(y: 4)
                }
                .frame(width: 146, height: 146)
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                )
                .shadow(color: .orange.opacity(0.30), radius: 30, y: 14)
                .scaleEffect(animate ? 1.04 : 0.96)

                Text("LET’S GET YOU STARTED")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .tracking(1.3)
                    .foregroundStyle(.orange)
                    .padding(.top, 34)

                Text("Your kitchen journey starts with one good next step.")
                    .font(.system(size: 39, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(-3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)

                Text("First, a short visual tour. Then ChefBuddy will take you into Recipes, Pantry, Meal Plan, and Grocery so you can learn by using the real app.")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.73))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 15)

                HStack(spacing: 7) {
                    ForEach(["book.pages.fill", "basket.fill", "calendar", "cart.fill"], id: \.self) { icon in
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                }
                .padding(.top, 22)

                Button {
                    ChefBuddyHaptics.success()
                    onBegin()
                } label: {
                    HStack {
                        Text("Begin My ChefBuddy Journey")
                        Spacer()
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 58)
                    .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .shadow(color: .orange.opacity(0.32), radius: 14, y: 7)
                }
                .buttonStyle(.plain)
                .padding(.top, 26)
                .padding(.bottom, 26)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

struct KitchenJourneyCoach: View {
    let stage: KitchenJourneyStage
    let savedRecipeCount: Int
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: stage.icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(stage.tint.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(stage.eyebrow)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(stage.tint)
                Text(stage == .recipes && savedRecipeCount > 0 ? "Great choice—your cookbook has started." : stage.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text(stage.detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 4)

            VStack(spacing: 8) {
                Button(action: onContinue) {
                    Image(systemName: stage == .grocery ? "checkmark" : "arrow.right")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(stage.tint, in: Circle())
                }
                .buttonStyle(.plain)

                Button("Skip", action: onSkip)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(stage.tint.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 18, y: 9)
        .padding(.horizontal, 18)
    }
}
