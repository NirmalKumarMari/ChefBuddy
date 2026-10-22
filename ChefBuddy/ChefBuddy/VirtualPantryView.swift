// VirtualPantryView.swift
// Lets users manage a persistent pantry of ingredients stored in Firestore.
// Supports manual entry and AI-powered fridge scanning (photo → ingredient list).
// The pantry feeds into recipe generation so ChefBuddy can suggest meals
// based on what the user actually has at home rather than generic suggestions.

import SwiftUI
import PhotosUI
import FirebaseFirestore
import FirebaseAuth
import Combine
import UniformTypeIdentifiers
import UIKit

struct PantrySpace: Identifiable, Hashable {
    let id: String
    var name: String
    var emoji: String
    var colorTheme: String
}

enum PantryScanMode {
    case add
    case replace
}

private enum PantryStorageArea: String, CaseIterable, Identifiable {
    case fridge = "Fridge"
    case pantry = "Pantry"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .fridge: return "snowflake"
        case .pantry: return "cabinet.fill"
        }
    }
}

private struct PantryScanNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let symbol: String
    let tint: Color
}

struct VirtualPantryView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var authVM: AuthViewModel
    @ObservedObject var assistant: CookingAssistant


    @State private var pantryCategories: [String: [String]] = [:]
    @State private var pantrySpaces: [PantrySpace] = []
    @State private var selectedPantryId: String? = nil
    @State private var selectedPantryName: String = ""


    @State private var showCreatePantrySheet = false
    @State private var editingPantryId: String? = nil
    @State private var newPantryName: String = ""
    @State private var newPantryEmoji: String = "🥑"
    @State private var newPantryColorTheme: String = "Orange"


    @State private var pantryToDelete: PantrySpace? = nil
    @State private var showDeletePantryAlert = false


    @State private var newIngredient: String = ""
    @State private var manualIngredientCategory: String = "Produce"
    @State private var manualIngredientEmoji: String = "🥬"
    @State private var isScanning = false
    @State private var isFetchingDB = true
    @State private var isSavingPantryLocally = false
    @State private var pantrySaveInFlightForId: String? = nil

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pendingSelectedPhotos: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var cameraImage: UIImage?
    @State private var pendingCameraImage: UIImage?
    @State private var showClearAllConfirmation = false
    @State private var showManualIngredientSheet = false
    @State private var showScanModeDialog = false


    @State private var lastScannedDate: Date? = nil


    @State private var editingOriginalItem: String? = nil
    @State private var editingOriginalCategory: String? = nil
    @State private var editedIngredientName: String = ""
    @State private var editedIngredientCategory: String = "Other"
    @State private var editedIngredientEmoji: String = "🥬"
    @State private var showEditIngredientSheet = false


    @State private var draggedItem: String? = nil
    @State private var draggedFromCategory: String? = nil
    @State private var ingredientSearch = ""
    @State private var selectedStorageArea: PantryStorageArea = .fridge
    @State private var isReorganizing = false
    @State private var expandedCategories: Set<String> = []
    @State private var showPantryInfo = false
    @Namespace private var storageSwitchNamespace


    let relativeTimeTimer = Timer.publish(every: 30.0, on: .main, in: .common).autoconnect()
    @State private var relativeTimeRefresh = Date()


    @State private var scanProgressTimer: Timer? = nil
    @State private var scanStatusText: String = "Waking up ChefBuddy..."
    @State private var scanAnimationStep: Int = 0
    @State private var scanNotice: PantryScanNotice? = nil
    let scanStatusMessages = [
        "Waking up ChefBuddy...",
        "Looking through your ingredients...",
        "Trying not to call ketchup a smoothie...",
        "Sorting everything into sections...",
        "Checking what belongs in the fridge...",
        "Finishing the pantry magic..."
    ]


    let fridgeCategories = ["Produce", "Protein", "Dairy", "Condiments", "Beverages"]
    let pantryCategoriesList = ["Pantry", "Spices", "Snacks", "Other"]

    var hasIngredients: Bool {
        !pantryCategories.values.flatMap { $0 }.isEmpty
    }

    var totalIngredientCount: Int {
        pantryCategories.values.reduce(0) { $0 + $1.count }
    }

    var allCategories: [String] {
        fridgeCategories + pantryCategoriesList
    }

    var currentSpace: PantrySpace? {
        pantrySpaces.first(where: { $0.id == selectedPantryId })
    }

    var activeColor: Color {
        colorForTheme(currentSpace?.colorTheme ?? "Orange")
    }

    var lastScannedRelativeText: String? {
        guard let lastScannedDate else { return nil }
        let seconds = Int(Date().timeIntervalSince(lastScannedDate))

        if seconds < 10 { return "Scanned just now" }
        else if seconds < 60 { return "Scanned \(seconds) sec ago" }
        else if seconds < 3600 { return "Scanned \(seconds / 60) min ago" }
        else if seconds < 86400 { let h = seconds / 3600; return "Scanned \(h) hr\(h == 1 ? "" : "s") ago" }
        else { let d = seconds / 86400; return "Scanned \(d) day\(d == 1 ? "" : "s") ago" }
    }

    private var activeCategoryCount: Int {
        pantryCategories.values.filter { !$0.isEmpty }.count
    }

    private var pantryFreshness: (title: String, detail: String, symbol: String, tint: Color) {
        guard let lastScannedDate else {
            return ("Needs a first scan", "Give ChefBuddy a current inventory snapshot.", "viewfinder", .orange)
        }
        let days = max(0, Calendar.current.dateComponents([.day], from: lastScannedDate, to: Date()).day ?? 0)
        switch days {
        case 0...3:
            return ("Inventory looks fresh", "Recipe matches are using a recent pantry scan.", "checkmark.seal.fill", .green)
        case 4...13:
            return ("Inventory may have changed", "A quick scan will improve pantry-based ideas.", "clock.fill", .orange)
        default:
            return ("Pantry check recommended", "Your last scan is \(days) days old.", "exclamationmark.triangle.fill", .red)
        }
    }

    var body: some View {
        ZStack {
            ChefBuddyBackground()

            Circle()
                .fill(activeColor.opacity(0.10))
                .frame(width: 330, height: 330)
                .blur(radius: 90)
                .offset(x: 170, y: -320)
                .ignoresSafeArea()

            if isFetchingDB {
                ProgressView("Opening Pantry...")
                    .scaleEffect(1.2)
            } else if pantrySpaces.isEmpty {

                PantryCardCreatorView(
                    name: $newPantryName,
                    emoji: $newPantryEmoji,
                    colorTheme: $newPantryColorTheme,
                    isFirstPantry: true,
                    isEditing: false,
                    onSave: {
                        savePantrySpace()
                    },
                    onCancel: nil
                )
                .transition(.opacity.combined(with: .scale))
            } else {

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        compactPantryHeader

                        pantryQuickActions

                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search ingredients", text: $ingredientSearch)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if !ingredientSearch.isEmpty {
                                Button {
                                    ChefBuddyHaptics.light()
                                    ingredientSearch = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                        storageAreaSwitch

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedStorageArea == .fridge ? "Cold storage" : "Shelf storage")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                Text(isReorganizing ? "Drag items between categories." : "Tap a category to expand it.")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                ChefBuddyHaptics.medium()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isReorganizing.toggle()
                                }
                            } label: {
                                Label(isReorganizing ? "Done" : "Reorganize", systemImage: isReorganizing ? "checkmark" : "arrow.up.arrow.down")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(isReorganizing ? .white : activeColor)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(isReorganizing ? activeColor : activeColor.opacity(0.11), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        if isScanning {
                            ScanStatusCard(
                                pantryName: selectedPantryName,
                                statusText: scanStatusText,
                                animationStep: scanAnimationStep,
                                funEmoji: currentSpace?.emoji ?? "✨",
                                accentColor: activeColor
                            )
                            .padding(.top, 2)
                        }

                        if let scanNotice, !isScanning {
                            HStack(spacing: 12) {
                                Image(systemName: scanNotice.symbol)
                                    .foregroundStyle(scanNotice.tint)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(scanNotice.title)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    Text(scanNotice.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(scanNotice.tint.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(scanNotice.tint.opacity(0.20), lineWidth: 1)
                            )
                        }

                        PantryStorageBrowser(
                            categories: selectedStorageArea == .fridge ? fridgeCategories : pantryCategoriesList,
                            data: $pantryCategories,
                            searchText: ingredientSearch,
                            accentColor: selectedStorageArea == .fridge ? .cyan : activeColor,
                            storageName: selectedStorageArea.rawValue,
                            isReorganizing: isReorganizing,
                            expandedCategories: $expandedCategories,
                            onDelete: { savePantry(isScan: false) },
                            onEdit: openEditSheet,
                            onMove: moveIngredient,
                            draggedItem: $draggedItem,
                            draggedFromCategory: $draggedFromCategory
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 130)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCamera) {
            CameraPicker(image: $cameraImage)
        }
        .sheet(isPresented: $showPantryInfo) {
            PantryHowItWorksSheet(accentColor: activeColor)
                .presentationDetents([.fraction(0.62)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showManualIngredientSheet) {
            IngredientEditorSheet(
                title: "Add Ingredient",
                subtitle: "Choose exactly where this item belongs before it hits your shelves.",
                ingredientName: $newIngredient,
                selectedEmoji: $manualIngredientEmoji,
                selectedCategory: $manualIngredientCategory,
                categories: allCategories,
                accentColor: activeColor,
                actionTitle: "Add to Pantry",
                showsDeleteAction: false,
                onDelete: nil,
                onSave: addManualIngredient,
                onCancel: {
                    showManualIngredientSheet = false
                    newIngredient = ""
                    manualIngredientEmoji = "🥬"
                }
            )
        }
        .sheet(isPresented: $showEditIngredientSheet) {
            IngredientEditorSheet(
                title: "Edit Ingredient",
                subtitle: "Rename it, move it, or clean up where it lives in your pantry.",
                ingredientName: $editedIngredientName,
                selectedEmoji: $editedIngredientEmoji,
                selectedCategory: $editedIngredientCategory,
                categories: allCategories,
                accentColor: activeColor,
                actionTitle: "Save Changes",
                showsDeleteAction: false,
                onDelete: nil,
                onSave: saveEditedIngredient,
                onCancel: {
                    showEditIngredientSheet = false
                }
            )
        }
        .fullScreenCover(isPresented: $showCreatePantrySheet) {
            PantryCardCreatorView(
                name: $newPantryName,
                emoji: $newPantryEmoji,
                colorTheme: $newPantryColorTheme,
                isFirstPantry: false,
                isEditing: editingPantryId != nil,
                onSave: {
                    savePantrySpace()
                },
                onCancel: {
                    showCreatePantrySheet = false
                    resetNewPantryForm()
                }
            )
        }
        .alert("Delete Pantry?", isPresented: $showDeletePantryAlert) {
            Button("Delete", role: .destructive) {
                if let space = pantryToDelete {
                    deletePantrySpace(space)
                }
            }
            Button("Cancel", role: .cancel) {
                pantryToDelete = nil
            }
        } message: {
            Text("Are you sure you want to delete '\(pantryToDelete?.name ?? "")'? This cannot be undone.")
        }
        .confirmationDialog(
            "Remove all ingredients?",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                clearAllIngredients()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will clear everything from \(selectedPantryName).")
        }
        .confirmationDialog(
            "How should ChefBuddy handle this scan?",
            isPresented: $showScanModeDialog,
            titleVisibility: .visible
        ) {
            Button("Add to Pantry") {
                startPendingScan(mode: .add)
            }
            Button("Replace Pantry", role: .destructive) {
                startPendingScan(mode: .replace)
            }
            Button("Cancel", role: .cancel) {
                pendingSelectedPhotos.removeAll()
                pendingCameraImage = nil
                selectedPhotos.removeAll()
                cameraImage = nil
            }
        } message: {
            Text("Choose whether this scan should add new ingredients or fully replace what’s already in \(selectedPantryName).")
        }
        .onChange(of: cameraImage) { image in
            if let img = image {
                prepareCameraScan(img)
            }
        }
        .onChange(of: assistant.pantryScanSession) { session in
            handleAssistantScanSession(session)
        }
        .onReceive(relativeTimeTimer) { value in
            relativeTimeRefresh = value
        }
        .onAppear {
            loadPantrySpaces()
            handleAssistantScanSession(assistant.pantryScanSession)
        }
    }

    private var compactPantryHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                Text("Swipe here to switch pantry")
                Image(systemName: "chevron.right")
                Spacer()
                if pantrySpaces.last?.id == selectedPantryId {
                    Label("Swipe again for new pantry", systemImage: "plus.circle.fill")
                        .foregroundStyle(activeColor)
                } else {
                    Text("\(max(pantrySpaces.firstIndex(where: { $0.id == selectedPantryId }).map { $0 + 1 } ?? 1, 1))/\(max(pantrySpaces.count, 1))")
                        .foregroundStyle(activeColor)
                }
            }
            .font(.system(size: 10, weight: .black, design: .rounded))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("VIRTUAL PANTRY")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(activeColor)
                        .tracking(0.9)
                    Text("Your kitchen inventory")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                }
                Spacer()

                Button {
                    ChefBuddyHaptics.selection()
                    showPantryInfo = true
                } label: {
                    Image(systemName: "questionmark")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(activeColor)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(activeColor.opacity(0.22), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How Pantry works")

                Menu {
                    Button {
                        ChefBuddyHaptics.medium()
                        resetNewPantryForm()
                        showCreatePantrySheet = true
                    } label: {
                        Label("Create New Pantry", systemImage: "plus.circle.fill")
                    }

                    if let currentSpace {
                        Button {
                            ChefBuddyHaptics.light()
                            newPantryName = currentSpace.name
                            newPantryEmoji = currentSpace.emoji
                            newPantryColorTheme = currentSpace.colorTheme
                            editingPantryId = currentSpace.id
                            showCreatePantrySheet = true
                        } label: {
                            Label("Rename & Style", systemImage: "pencil")
                        }

                        if hasIngredients {
                            Button(role: .destructive) {
                                ChefBuddyHaptics.warning()
                                showClearAllConfirmation = true
                            } label: {
                                Label("Clear Pantry", systemImage: "trash")
                            }
                        }

                        Button(role: .destructive) {
                            ChefBuddyHaptics.warning()
                            pantryToDelete = currentSpace
                            showDeletePantryAlert = true
                        } label: {
                            Label("Delete Pantry", systemImage: "trash.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
            }

            HStack(spacing: 13) {
                Text(currentSpace?.emoji ?? "🥑")
                    .font(.system(size: 36))
                    .frame(width: 64, height: 64)
                    .background(
                        LinearGradient(
                            colors: [activeColor.opacity(0.22), activeColor.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedPantryName)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                    Label(pantryFreshness.title, systemImage: pantryFreshness.symbol)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(pantryFreshness.tint)
                    Text(pantryFreshness.detail)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            HStack(spacing: 9) {
                pantryMetric(title: "Ingredients", value: "\(totalIngredientCount)", icon: "leaf.fill")
                pantryMetric(title: "Categories", value: "\(activeCategoryCount)", icon: "square.grid.2x2.fill")
                pantryMetric(
                    title: "Last scan",
                    value: lastScannedDate == nil ? "Never" : (lastScannedRelativeText?.replacingOccurrences(of: "Scanned ", with: "") ?? "Recent"),
                    icon: "viewfinder"
                )
            }
        }
        .padding(17)
        .background(
            LinearGradient(
                colors: [Color.primary.opacity(0.075), activeColor.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(activeColor.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: activeColor.opacity(0.08), radius: 18, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height),
                          abs(value.translation.width) > 48 else { return }
                    switchPantryBySwipe(forward: value.translation.width < 0)
                }
        )
    }

    private func switchPantryBySwipe(forward: Bool) {
        guard !pantrySpaces.isEmpty,
              let selectedPantryId,
              let currentIndex = pantrySpaces.firstIndex(where: { $0.id == selectedPantryId }) else { return }

        let isPastLastPantry = forward && currentIndex == pantrySpaces.count - 1
        let isBeforeFirstPantry = !forward && currentIndex == 0
        if isPastLastPantry || isBeforeFirstPantry {
            ChefBuddyHaptics.medium()
            resetNewPantryForm()
            showCreatePantrySheet = true
            return
        }

        let delta = forward ? 1 : -1
        let nextIndex = currentIndex + delta
        ChefBuddyHaptics.medium()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            switchToPantry(pantrySpaces[nextIndex])
        }
    }

    private var pantryCarouselSelection: Binding<String> {
        Binding(
            get: { selectedPantryId ?? "__none" },
            set: { newValue in
                if newValue == "__new" {
                    ChefBuddyHaptics.light()
                    resetNewPantryForm()
                    showCreatePantrySheet = true
                    if let selectedPantryId {
                        DispatchQueue.main.async {
                            self.selectedPantryId = selectedPantryId
                        }
                    }
                } else if let space = pantrySpaces.first(where: { $0.id == newValue }) {
                    ChefBuddyHaptics.selection()
                    switchToPantry(space)
                }
            }
        )
    }

    private var pantrySpaceCarousel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Swipe pantry spaces")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(max(pantrySpaces.firstIndex(where: { $0.id == selectedPantryId }).map { $0 + 1 } ?? 1, 1))/\(max(pantrySpaces.count, 1))")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(activeColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(activeColor.opacity(0.11), in: Capsule())
            }
            .padding(.horizontal, 4)

            TabView(selection: pantryCarouselSelection) {
                ForEach(pantrySpaces) { space in
                    pantryCarouselTile(space)
                        .tag(space.id)
                }

                addPantryTile
                    .tag("__new")
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 108)
        }
    }

    private func pantryCarouselTile(_ space: PantrySpace) -> some View {
        let isSelected = selectedPantryId == space.id
        let tint = colorForTheme(space.colorTheme)

        return Button {
            ChefBuddyHaptics.selection()
            switchToPantry(space)
        } label: {
            HStack(spacing: 14) {
                Text(space.emoji)
                    .font(.system(size: 34))
                    .frame(width: 58, height: 58)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(space.name)
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(isSelected ? "Active pantry" : "Swipe or tap to switch")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? tint : .secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(isSelected ? tint : .secondary)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.36) : Color.primary.opacity(0.06), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
    }

    private var addPantryTile: some View {
        Button {
            ChefBuddyHaptics.light()
            resetNewPantryForm()
            showCreatePantrySheet = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [activeColor.opacity(0.24), .green.opacity(0.16)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 58, height: 58)
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(activeColor)
                        .symbolEffect(.pulse)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Add New Pantry")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                    Text("Create a new kitchen space")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(16)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(activeColor.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [7, 6]))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
    }

    private var storageAreaSwitch: some View {
        HStack(spacing: 6) {
            ForEach(PantryStorageArea.allCases) { area in
                Button {
                    ChefBuddyHaptics.selection()
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        selectedStorageArea = area
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: area.icon)
                            .font(.system(size: 13, weight: .bold))
                        Text(area.rawValue)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(selectedStorageArea == area ? .white : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background {
                        if selectedStorageArea == area {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(activeColor.gradient)
                                .matchedGeometryEffect(id: "storage-switch", in: storageSwitchNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func pantryMetric(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(activeColor)
            Text(value)
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var pantryQuickActions: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 5, matching: .images) {
                Label("Scan Pantry", systemImage: "viewfinder")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(activeColor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .simultaneousGesture(TapGesture().onEnded {
                ChefBuddyHaptics.medium()
            })
            .disabled(isScanning || selectedPantryId == nil)
            .onChange(of: selectedPhotos) { newItems in
                preparePhotoScan(newItems)
            }

            Button {
                ChefBuddyHaptics.light()
                newIngredient = ""
                manualIngredientCategory = selectedStorageArea == .fridge ? "Produce" : "Pantry"
                manualIngredientEmoji = "🥬"
                showManualIngredientSheet = true
            } label: {
                Label("Add Item", systemImage: "plus")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(activeColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(activeColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isScanning || selectedPantryId == nil)

            Button {
                ChefBuddyHaptics.medium()
                showCamera = true
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(width: 48, height: 48)
                    .background(Color.green.opacity(0.11), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isScanning || selectedPantryId == nil)
        }
    }


    private var pantrySwitcher: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Pantry Spaces")
                    .font(.headline)
                Spacer()
                Button(action: {
                    resetNewPantryForm()
                    showCreatePantrySheet = true
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("New")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(activeColor.opacity(0.12))
                    .foregroundStyle(activeColor)
                    .clipShape(Capsule())
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(pantrySpaces) { space in
                        let isSelected = selectedPantryId == space.id
                        let spaceColor = colorForTheme(space.colorTheme)

                        Button(action: {
                            switchToPantry(space)
                        }) {
                            HStack(spacing: 6) {
                                Text(space.emoji)
                                Text(space.name)
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                isSelected
                                ? spaceColor
                                : Color(.secondarySystemGroupedBackground)
                            )
                            .foregroundStyle(
                                isSelected ? Color.white : Color.primary
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(
                                        isSelected
                                        ? spaceColor
                                        : Color.primary.opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                newPantryName = space.name
                                newPantryEmoji = space.emoji
                                newPantryColorTheme = space.colorTheme
                                editingPantryId = space.id
                                showCreatePantrySheet = true
                            } label: {
                                Label("Edit Space", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                pantryToDelete = space
                                showDeletePantryAlert = true
                            } label: {
                                Label("Delete Space", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Text("Tip: Press and hold a space to edit or delete it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, -4)
        }
    }

    private var actionBar: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Stock it your way")
                        .font(.system(size: 18, weight: .bold, design: .rounded))

                    Text("Add ingredients manually, or scan and choose whether to merge or replace.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: {
                    newIngredient = ""
                    manualIngredientCategory = allCategories.first ?? "Other"
                    showManualIngredientSheet = true
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Manually")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(activeColor)
                    .clipShape(Capsule())
                    .shadow(color: activeColor.opacity(0.24), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(isScanning || selectedPantryId == nil)
            }
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )

            HStack(spacing: 12) {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 5, matching: .images) {
                    ActionButton(icon: "photo.on.rectangle.angled", title: "Scan Gallery", color: .blue, isDisabled: isScanning || selectedPantryId == nil)
                }
                .disabled(isScanning || selectedPantryId == nil)
                .onChange(of: selectedPhotos) { newItems in
                    preparePhotoScan(newItems)
                }

                Button(action: { showCamera = true }) {
                    ActionButton(icon: "camera.viewfinder", title: "Use Camera", color: .green, isDisabled: isScanning || selectedPantryId == nil)
                }
                .disabled(isScanning || selectedPantryId == nil)
            }

            if hasIngredients {
                Button(role: .destructive) {
                    showClearAllConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                        Text("Remove All Ingredients")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.red.opacity(0.08))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.red.opacity(0.18), lineWidth: 1)
                    )
                }
                .disabled(isScanning || selectedPantryId == nil)
            }
        }
    }


    private func resetNewPantryForm() {
        newPantryName = ""
        newPantryEmoji = "🥑"
        newPantryColorTheme = "Orange"
        editingPantryId = nil
    }

    private func colorForTheme(_ theme: String) -> Color {
        switch theme {
        case "Blue": return .blue
        case "Green": return .green
        case "Pink": return .pink
        case "Purple": return .purple
        case "Red": return .red
        case "Cyan": return .cyan
        case "Yellow": return .yellow
        case "Mint": return .mint
        default: return .orange
        }
    }

    private func pantrySpacesCollection() -> CollectionReference? {
        guard let uid = authVM.userSession?.uid else { return nil }
        return Firestore.firestore()
            .collection("users")
            .document(uid)
            .collection("pantrySpaces")
    }

    private func loadPantrySpaces() {
        guard let collection = pantrySpacesCollection() else { return }

        isFetchingDB = true

        collection.getDocuments { snapshot, error in
            guard let docs = snapshot?.documents else {
                self.isFetchingDB = false
                return
            }

            if docs.isEmpty {
                withAnimation {
                    self.pantrySpaces = []
                    self.isFetchingDB = false
                }
                return
            }

            let spaces = docs.map { doc in
                PantrySpace(
                    id: doc.documentID,
                    name: (doc.data()["name"] as? String) ?? "Untitled Pantry",
                    emoji: (doc.data()["emoji"] as? String) ?? "🥑",
                    colorTheme: (doc.data()["colorTheme"] as? String) ?? "Orange"
                )
            }
            .sorted { $0.name < $1.name }

            withAnimation {
                self.pantrySpaces = spaces
            }

            if let currentSelected = self.selectedPantryId,
               let existing = spaces.first(where: { $0.id == currentSelected }) {
                self.selectedPantryName = existing.name
                loadPantry(spaceId: existing.id, spaceName: existing.name)
            } else if let first = spaces.first {
                self.selectedPantryId = first.id
                self.selectedPantryName = first.name
                loadPantry(spaceId: first.id, spaceName: first.name)
            } else {
                self.isFetchingDB = false
            }
        }
    }

    private func savePantrySpace() {
        let cleanName = newPantryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, let collection = pantrySpacesCollection() else { return }

        if let editId = editingPantryId {

            collection.document(editId).updateData([
                "name": cleanName,
                "emoji": newPantryEmoji,
                "colorTheme": newPantryColorTheme,
                "updatedAt": FieldValue.serverTimestamp()
            ]) { error in
                guard error == nil else { return }
                if let idx = self.pantrySpaces.firstIndex(where: { $0.id == editId }) {
                    withAnimation(.spring()) {
                        self.pantrySpaces[idx].name = cleanName
                        self.pantrySpaces[idx].emoji = newPantryEmoji
                        self.pantrySpaces[idx].colorTheme = newPantryColorTheme
                        self.pantrySpaces.sort { $0.name < $1.name }

                        if self.selectedPantryId == editId {
                            self.selectedPantryName = cleanName
                        }
                    }
                }
                self.showCreatePantrySheet = false
                self.resetNewPantryForm()
            }
        } else {

            let doc = collection.document()
            let payload: [String: Any] = [
                "name": cleanName,
                "emoji": newPantryEmoji,
                "colorTheme": newPantryColorTheme,
                "virtualPantry": [:],
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ]

            doc.setData(payload) { error in
                guard error == nil else { return }
                let newSpace = PantrySpace(id: doc.documentID, name: cleanName, emoji: newPantryEmoji, colorTheme: newPantryColorTheme)
                withAnimation(.spring()) {
                    self.pantrySpaces.append(newSpace)
                    self.pantrySpaces.sort { $0.name < $1.name }
                    self.selectedPantryId = newSpace.id
                    self.selectedPantryName = newSpace.name
                    self.pantryCategories = [:]
                    self.showCreatePantrySheet = false
                    self.lastScannedDate = nil
                }
                self.resetNewPantryForm()
                self.loadPantry(spaceId: newSpace.id, spaceName: newSpace.name)
            }
        }
    }

    private func deletePantrySpace(_ space: PantrySpace) {
        guard let collection = pantrySpacesCollection() else { return }

        collection.document(space.id).delete() { _ in
            withAnimation(.spring()) {
                self.pantrySpaces.removeAll(where: { $0.id == space.id })

                if self.selectedPantryId == space.id {
                    if let first = self.pantrySpaces.first {
                        self.switchToPantry(first)
                    } else {
                        self.selectedPantryId = nil
                        self.selectedPantryName = ""
                        self.pantryCategories = [:]
                    }
                }
            }
        }
    }

    private func switchToPantry(_ space: PantrySpace) {
        guard selectedPantryId != space.id else { return }
        withAnimation {
            selectedPantryId = space.id
            selectedPantryName = space.name
        }
        loadPantry(spaceId: space.id, spaceName: space.name)
    }

    private func loadPantry(spaceId: String, spaceName: String) {
        guard let collection = pantrySpacesCollection() else { return }

        collection.document(spaceId).getDocument { snapshot, error in
            guard self.selectedPantryId == spaceId else { return }

            if self.pantrySaveInFlightForId == spaceId || self.isSavingPantryLocally {
                self.isFetchingDB = false
                return
            }

            var newCategories: [String: [String]] = [:]
            var newLastScannedDate: Date? = nil

            if let data = snapshot?.data() {
                if let savedPantry = data["virtualPantry"] as? [String: [String]] {
                    newCategories = savedPantry
                }
                if let timestamp = data["lastScannedAt"] as? Timestamp {
                    newLastScannedDate = timestamp.dateValue()
                }
            }

            withAnimation(.easeIn(duration: 0.25)) {
                self.pantryCategories = newCategories
                self.lastScannedDate = newLastScannedDate
                self.selectedPantryId = spaceId
                self.selectedPantryName = spaceName
                self.isFetchingDB = false
            }
        }
    }

    private func savePantry(isScan: Bool = false) {
        guard let collection = pantrySpacesCollection(),
              let selectedPantryId else { return }

        var cleanedPantry = pantryCategories
        for (key, value) in cleanedPantry {
            if value.isEmpty {
                cleanedPantry.removeValue(forKey: key)
            }
        }

        var payload: [String: Any] = [
            "virtualPantry": cleanedPantry,
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if isScan {
            payload["lastScannedAt"] = FieldValue.serverTimestamp()
        }

        isSavingPantryLocally = true
        pantrySaveInFlightForId = selectedPantryId

        collection.document(selectedPantryId).setData(payload, merge: true) { _ in
            self.isSavingPantryLocally = false
            if self.pantrySaveInFlightForId == selectedPantryId {
                self.pantrySaveInFlightForId = nil
            }
        }
    }

    private func clearAllIngredients() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            pantryCategories.removeAll()
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        savePantry(isScan: false)
    }

    private func addManualIngredient() {
        let clean = newIngredient.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return }

        let itemToAdd = normalizeIngredientItem(clean, preferredEmoji: manualIngredientEmoji)

        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            var items = pantryCategories[manualIngredientCategory] ?? []
            if !items.contains(itemToAdd) {
                items.insert(itemToAdd, at: 0)
                pantryCategories[manualIngredientCategory] = items
            }
        }

        newIngredient = ""
        manualIngredientEmoji = "🥬"
        manualIngredientCategory = allCategories.first ?? "Other"
        showManualIngredientSheet = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        savePantry(isScan: false)
    }

    private func preparePhotoScan(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }

        if hasIngredients {
            pendingSelectedPhotos = items
            pendingCameraImage = nil
            showScanModeDialog = true
        } else {
            Task { await processSelectedPhotos(items, mode: .add) }
        }
    }

    private func prepareCameraScan(_ image: UIImage) {
        if hasIngredients {
            pendingCameraImage = image
            pendingSelectedPhotos.removeAll()
            showScanModeDialog = true
        } else {
            Task { await processCameraImage(image, mode: .add) }
        }
    }

    private func startPendingScan(mode: PantryScanMode) {
        if !pendingSelectedPhotos.isEmpty {
            let items = pendingSelectedPhotos
            pendingSelectedPhotos.removeAll()
            Task { await processSelectedPhotos(items, mode: mode) }
        } else if let image = pendingCameraImage {
            pendingCameraImage = nil
            Task { await processCameraImage(image, mode: mode) }
        }
    }

    private func processSelectedPhotos(_ items: [PhotosPickerItem], mode: PantryScanMode) async {
        guard !items.isEmpty else { return }

        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }

        await MainActor.run {
            guard let selectedPantryId else { return }
            scanNotice = nil
            startScanAnimation()
            assistant.startPantryScan(
                images: images,
                pantryId: selectedPantryId,
                pantryName: selectedPantryName,
                mode: mode
            )
        }

        await MainActor.run {
            selectedPhotos.removeAll()
        }
    }

    private func processCameraImage(_ image: UIImage, mode: PantryScanMode) async {
        await MainActor.run {
            scanNotice = nil
            startScanAnimation()
            guard let selectedPantryId else { return }
            assistant.startPantryScan(
                images: [image],
                pantryId: selectedPantryId,
                pantryName: selectedPantryName,
                mode: mode
            )
        }

        await MainActor.run {
            cameraImage = nil
        }
    }

    private func handleAssistantScanSession(_ session: PantryScanSession?) {
        guard let session else {
            if isScanning {
                stopScanAnimation(resetProgress: true)
            }
            return
        }

        guard session.pantryId == selectedPantryId else {
            if isScanning {
                stopScanAnimation(resetProgress: true)
            }
            return
        }

        switch session.state {
        case .running:
            if !isScanning {
                startScanAnimation()
            }
            selectedPantryName = session.pantryName
            scanNotice = nil
        case .completed:
            if !session.didApplyResult {
                applyScannedIngredients(session.scannedCategories, mode: session.mode)
                assistant.markPantryScanApplied(session.id)
            }
            scanNotice = nil
            finishScanAnimation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                assistant.clearPantryScanIfFinished(for: session.pantryId)
            }
        case .emptyResult:
            stopScanAnimation(resetProgress: true)
            scanNotice = PantryScanNotice(
                title: "ChefBuddy couldn’t detect ingredients",
                message: "Try a brighter photo, get closer to the shelves, or make sure items aren’t blocked.",
                symbol: "camera.metering.unknown",
                tint: .orange
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                assistant.clearPantryScanIfFinished(for: session.pantryId)
            }
        case .failed(let message):
            stopScanAnimation(resetProgress: true)
            scanNotice = PantryScanNotice(
                title: "Pantry scan didn’t finish",
                message: message,
                symbol: "exclamationmark.triangle.fill",
                tint: .red
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                assistant.clearPantryScanIfFinished(for: session.pantryId)
            }
        }
    }

    private func applyScannedIngredients(_ newCategories: [String: [String]], mode: PantryScanMode) {
        if mode == .replace {
            pantryCategories.removeAll()
        }
        mergeIngredients(newCategories)
    }

    private func mergeIngredients(_ newCategories: [String: [String]]) {
        withAnimation(.spring()) {
            for (category, items) in newCategories {
                var currentItems = pantryCategories[category] ?? []

                for item in items {
                    let cleanedItem = normalizeIngredientItem(item)
                    if !currentItems.contains(cleanedItem) {
                        currentItems.append(cleanedItem)
                    }
                }

                if !currentItems.isEmpty {
                    pantryCategories[category] = currentItems
                }
            }
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        savePantry(isScan: true)
        lastScannedDate = Date()
    }

    private func openEditSheet(item: String, category: String) {
        editingOriginalItem = item
        editingOriginalCategory = category

        let parts = item.split(separator: " ", maxSplits: 1)
        if parts.count == 2 {
            editedIngredientEmoji = String(parts[0])
            editedIngredientName = String(parts[1])
        } else {
            editedIngredientEmoji = "🥬"
            editedIngredientName = item
        }

        editedIngredientCategory = category
        showEditIngredientSheet = true
    }

    private func saveEditedIngredient() {
        guard let originalItem = editingOriginalItem,
              let originalCategory = editingOriginalCategory else {
            return
        }

        let cleanedName = editedIngredientName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !cleanedName.isEmpty else { return }


        let updatedItem: String
        updatedItem = normalizeIngredientItem(cleanedName, preferredEmoji: editedIngredientEmoji)

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            removeItem(originalItem, from: originalCategory)

            var targetItems = pantryCategories[editedIngredientCategory] ?? []
            if !targetItems.contains(updatedItem) {
                targetItems.insert(updatedItem, at: 0)
                pantryCategories[editedIngredientCategory] = targetItems
            }
        }

        savePantry(isScan: false)

        showEditIngredientSheet = false
        editingOriginalItem = nil
        editingOriginalCategory = nil
        editedIngredientName = ""
        editedIngredientEmoji = "🥬"
        editedIngredientCategory = allCategories.first ?? "Other"
    }

    private func removeItem(_ item: String, from category: String) {
        pantryCategories[category]?.removeAll(where: { $0 == item })
        if pantryCategories[category]?.isEmpty == true {
            pantryCategories.removeValue(forKey: category)
        }
    }

    private func moveIngredient(_ item: String, from sourceCategory: String, to destinationCategory: String) {
        guard sourceCategory != destinationCategory else { return }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            pantryCategories[sourceCategory]?.removeAll(where: { $0 == item })

            if pantryCategories[sourceCategory]?.isEmpty == true {
                pantryCategories.removeValue(forKey: sourceCategory)
            }

            var destinationItems = pantryCategories[destinationCategory] ?? []
            if !destinationItems.contains(item) {
                destinationItems.insert(item, at: 0)
                pantryCategories[destinationCategory] = destinationItems
            }
        }

        draggedItem = nil
        draggedFromCategory = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        savePantry(isScan: false)
    }

    private func normalizeIngredientItem(_ item: String, preferredEmoji: String? = nil) -> String {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = trimmed.split(separator: " ", maxSplits: 1)

        if parts.count == 2 {
            return "\(parts[0]) \(parts[1])"
        } else {
            let defaultEmojis = ["🥫", "🍱", "🍲", "🥗", "🍛", "🥘", "🌮", "🍝", "🥩", "🍗", "🥦", "🍋", "🌶️", "🍄", "🥕"]
            let randomEmoji = preferredEmoji ?? defaultEmojis.randomElement() ?? "🥘"
            return "\(randomEmoji) \(trimmed)"
        }
    }

    private func startScanAnimation() {
        stopScanAnimation(resetProgress: true)

        isScanning = true
        scanAnimationStep = 0
        scanStatusText = scanStatusMessages[0]


        scanProgressTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            let nextStep = (scanAnimationStep + 1) % scanStatusMessages.count
            withAnimation(.easeInOut(duration: 0.5)) {
                scanAnimationStep = nextStep
                scanStatusText = scanStatusMessages[nextStep]
            }
        }
    }

    private func finishScanAnimation() {
        scanProgressTimer?.invalidate()
        scanProgressTimer = nil

        withAnimation(.easeInOut(duration: 0.25)) {
            scanStatusText = "Done stocking \(selectedPantryName)."
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            stopScanAnimation(resetProgress: true)
        }
    }

    private func stopScanAnimation(resetProgress: Bool) {
        scanProgressTimer?.invalidate()
        scanProgressTimer = nil
        isScanning = false

        if resetProgress {
            scanStatusText = "Waking up ChefBuddy..."
            scanAnimationStep = 0
        }
    }
}

private struct PantryHowItWorksSheet: View {
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [accentColor.opacity(0.26), Color.black, Color(.systemBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Image(systemName: "basket.fill")
                    .font(.system(size: 240, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.035))
                    .rotationEffect(.degrees(-10))
                    .offset(x: 145, y: 290)

                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "basket.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                            .background(accentColor.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your Pantry, explained")
                                .font(.system(size: 23, weight: .heavy, design: .rounded))
                            Text("Keep ChefBuddy’s ingredient context accurate without turning inventory into a chore.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    pantryInfoRow(
                        icon: "hand.draw.fill",
                        title: "Swipe between spaces",
                        detail: "Use the very top of Pantry to move between spaces. Swipe past the last one to create another."
                    )
                    pantryInfoRow(
                        icon: "snowflake",
                        title: "Fridge and shelf storage",
                        detail: "Cold items and pantry staples stay separated so scanning and recipe matching remain useful."
                    )
                    pantryInfoRow(
                        icon: "camera.viewfinder",
                        title: "Scan, then review",
                        detail: "A scan can add to the current space or replace it. You can always edit the result manually."
                    )

                    Button {
                        dismiss()
                    } label: {
                        Text("Got It")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .navigationTitle("Pantry Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func pantryInfoRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(accentColor)
                .frame(width: 40, height: 40)
                .background(accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

private struct IngredientEditorSheet: View {
    let title: String
    let subtitle: String
    @Binding var ingredientName: String
    @Binding var selectedEmoji: String
    @Binding var selectedCategory: String
    let categories: [String]
    let accentColor: Color
    let actionTitle: String
    let showsDeleteAction: Bool
    let onDelete: (() -> Void)?
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool
    @State private var showEmojiPicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [accentColor.opacity(0.26), Color.black, Color(.systemBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Image(systemName: "basket.fill")
                    .font(.system(size: 240, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.035))
                    .rotationEffect(.degrees(-10))
                    .offset(x: 145, y: 290)

                Circle()
                    .fill(accentColor.opacity(0.14))
                    .blur(radius: 80)
                    .offset(x: -130, y: -220)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title)
                                .font(.system(size: 30, weight: .heavy, design: .rounded))

                            Text(subtitle)
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 20)

                        VStack(alignment: .leading, spacing: 16) {
                            Text("Ingredient Name")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)

                            TextField("Example: baby spinach", text: $ingredientName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($isFocused)
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                        VStack(alignment: .leading, spacing: 16) {
                            Text("Pick an emoji")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)

                            IngredientEmojiButton(
                                selectedEmoji: $selectedEmoji,
                                accentColor: accentColor,
                                onTap: {
                                    showEmojiPicker = true
                                }
                            )
                        }
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                        VStack(alignment: .leading, spacing: 16) {
                            Text("Where should it live?")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)

                            FlexibleCategoryGrid(categories: categories, selectedCategory: $selectedCategory, accentColor: accentColor)
                        }
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                        if showsDeleteAction, let onDelete {
                            Button(role: .destructive, action: onDelete) {
                                Label("Delete Ingredient", systemImage: "trash.fill")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            }
                        }

                        Button(action: onSave) {
                            HStack(spacing: 10) {
                                Image(systemName: actionTitle == "Save Changes" ? "checkmark.circle.fill" : "plus.circle.fill")
                                Text(actionTitle)
                            }
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(
                                    LinearGradient(colors: [accentColor, .green.opacity(0.88)], startPoint: .leading, endPoint: .trailing),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                                .shadow(color: accentColor.opacity(0.24), radius: 10, y: 5)
                        }
                        .buttonStyle(.plain)
                        .disabled(ingredientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(ingredientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.6 : 1)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
            .onAppear {
                if selectedCategory.isEmpty {
                    selectedCategory = categories.first ?? "Other"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    isFocused = true
                }
            }
            .sheet(isPresented: $showEmojiPicker) {
                IngredientEmojiKeyboardSheet(selectedEmoji: $selectedEmoji, accentColor: accentColor)
                    .presentationDetents([.fraction(0.32)])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct IngredientEmojiButton: View {
    @Binding var selectedEmoji: String
    let accentColor: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Text(selectedEmoji)
                    .font(.system(size: 32))
                    .frame(width: 60, height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(accentColor.opacity(0.16))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose from keyboard")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Tap to open the emoji keyboard and pick any emoji.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Text("...")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(accentColor)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(accentColor.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct IngredientEmojiKeyboardSheet: View {
    @Binding var selectedEmoji: String
    let accentColor: Color

    @Environment(\.dismiss) private var dismiss
    @State private var draftEmoji = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Pick any emoji")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))

                Text("ChefBuddy will use the first emoji you enter here.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    Text(draftEmoji.isEmpty ? selectedEmoji : draftEmoji)
                        .font(.system(size: 42))
                        .frame(width: 78, height: 78)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(accentColor.opacity(0.16))
                        )

                    EmojiKeyboardTextField(text: $draftEmoji)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                Text("If you want a different one later, tap the ... button again.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Button {
                    if draftEmoji.isEmpty == false {
                        selectedEmoji = draftEmoji
                    }
                    dismiss()
                } label: {
                    Text("Use Emoji")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accentColor, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(22)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        if draftEmoji.isEmpty == false {
                            selectedEmoji = draftEmoji
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                draftEmoji = selectedEmoji
            }
        }
    }
}

private struct EmojiKeyboardTextField: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> EmojiOnlyTextField {
        let textField = EmojiOnlyTextField()
        textField.delegate = context.coordinator
        textField.textAlignment = .center
        textField.font = .systemFont(ofSize: 34)
        textField.tintColor = .clear
        textField.backgroundColor = .clear
        textField.placeholder = "😀"
        return textField
    }

    func updateUIView(_ uiView: EmojiOnlyTextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if uiView.window != nil, uiView.isFirstResponder == false {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            let firstEmoji = textField.text?.first.map(String.init) ?? ""
            if text != firstEmoji {
                text = firstEmoji
            }
            if textField.text != firstEmoji {
                textField.text = firstEmoji
            }
        }
    }
}

private final class EmojiOnlyTextField: UITextField {
    override var textInputContextIdentifier: String? {
        ""
    }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first(where: { $0.primaryLanguage == "emoji" }) ?? super.textInputMode
    }
}

private struct FlexibleCategoryGrid: View {
    let categories: [String]
    @Binding var selectedCategory: String
    let accentColor: Color

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(categories, id: \.self) { category in
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedCategory = category
                }) {
                    Text(category)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(selectedCategory == category ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            Group {
                                if selectedCategory == category {
                                    accentColor
                                } else {
                                    Color.primary.opacity(0.08)
                                }
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}


struct PantryCardCreatorView: View {
    @Binding var name: String
    @Binding var emoji: String
    @Binding var colorTheme: String

    let isFirstPantry: Bool
    let isEditing: Bool
    let onSave: () -> Void
    let onCancel: (() -> Void)?

    let colorThemes = ["Orange", "Blue", "Green", "Pink", "Purple", "Red", "Cyan", "Yellow", "Mint"]
    let emojis = ["🥑", "🥩", "🧀", "🥦", "🥛", "🥕", "🍗", "🍅", "🍞", "🌶️", "🥐", "🧊", "🍔", "🍕", "🧁"]

    var activeColor: Color {
        switch colorTheme {
        case "Blue": return .blue
        case "Green": return .green
        case "Pink": return .pink
        case "Purple": return .purple
        case "Red": return .red
        case "Cyan": return .cyan
        case "Yellow": return .yellow
        case "Mint": return .mint
        default: return .orange
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [activeColor.opacity(0.26), Color.black, Color(.systemBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Image(systemName: "basket.fill")
                    .font(.system(size: 240, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.035))
                    .rotationEffect(.degrees(-10))
                    .offset(x: 145, y: 290)

                ScrollView {
                    VStack(spacing: 32) {

                        if isFirstPantry {
                            VStack(spacing: 8) {
                                Text("Welcome to ChefBuddy")
                                    .font(.system(size: 11, weight: .black, design: .rounded))
                                    .tracking(1)
                                    .foregroundStyle(.secondary)
                                Text("Create your first kitchen space.")
                                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.top, 20)
                        }


                        ZStack {
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [activeColor.opacity(0.6), activeColor],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: activeColor.opacity(0.3), radius: 15, y: 8)

                            VStack(spacing: 20) {
                                Text(emoji)
                                    .font(.system(size: 80))
                                    .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                                    .scaleEffect(1.05)
                                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: emoji)

                                TextField("Pantry Name", text: $name)
                                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .tint(.white)
                                    .submitLabel(.done)
                                    .padding(.horizontal)
                            }
                            .padding()
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 240)
                        .padding(.horizontal, 24)
                        .padding(.top, isFirstPantry ? 10 : 30)


                        VStack(spacing: 28) {


                            VStack(alignment: .leading, spacing: 12) {
                                Text("Background Theme")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 24)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                        ForEach(colorThemes, id: \.self) { theme in
                                            Circle()
                                                .fill(themeColor(for: theme))
                                                .frame(width: 44, height: 44)
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color.white, lineWidth: colorTheme == theme ? 3 : 0)
                                                )
                                                .shadow(color: colorTheme == theme ? themeColor(for: theme).opacity(0.5) : .clear, radius: 5, y: 2)
                                                .scaleEffect(colorTheme == theme ? 1.15 : 1.0)
                                                .onTapGesture {
                                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                                        colorTheme = theme
                                                    }
                                                }
                                        }
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 8)
                                }
                            }


                            VStack(alignment: .leading, spacing: 12) {
                                Text("Pantry Icon")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 24)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                        ForEach(emojis, id: \.self) { e in
                                            Text(e)
                                                .font(.system(size: 32))
                                                .frame(width: 50, height: 50)
                                                .background(
                                                    Circle()
                                                        .fill(emoji == e ? activeColor.opacity(0.2) : Color(.secondarySystemGroupedBackground))
                                                )
                                                .scaleEffect(emoji == e ? 1.15 : 1.0)
                                                .onTapGesture {
                                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                                                        emoji = e
                                                    }
                                                }
                                        }
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 8)
                                }
                            }
                        }
                        .padding(.vertical, 20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.10), lineWidth: 1))
                        .padding(.horizontal, 20)

                        Spacer(minLength: isFirstPantry ? 176 : 72)
                    }
                }


            }
            .navigationTitle(isFirstPantry ? "" : (isEditing ? "Edit Pantry" : "New Pantry"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onCancel = onCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                pantrySaveButton
                    .padding(.bottom, isFirstPantry ? 104 : 8)
            }
        }
    }

    private var pantrySaveButton: some View {
        Button {
            ChefBuddyHaptics.success()
            onSave()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isEditing ? "checkmark.circle.fill" : "plus.circle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(isFirstPantry ? "Create My First Pantry" : (isEditing ? "Save Changes" : "Create Pantry"))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(isFirstPantry ? "Start stocking ingredients next" : "Keep this kitchen space organized")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.76))
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 17)
            .padding(.vertical, 13)
            .background(
                name.trimmingCharacters(in: .whitespaces).isEmpty
                    ? AnyShapeStyle(Color.gray)
                    : AnyShapeStyle(activeColor.gradient),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .shadow(
                color: name.trimmingCharacters(in: .whitespaces).isEmpty ? .clear : activeColor.opacity(0.30),
                radius: 12,
                y: 6
            )
        }
        .buttonStyle(.plain)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func themeColor(for name: String) -> Color {
        switch name {
        case "Blue": return .blue
        case "Green": return .green
        case "Pink": return .pink
        case "Purple": return .purple
        case "Red": return .red
        case "Cyan": return .cyan
        case "Yellow": return .yellow
        case "Mint": return .mint
        default: return .orange
        }
    }
}


private struct PantryStorageBrowser: View {
    let categories: [String]
    @Binding var data: [String: [String]]
    let searchText: String
    let accentColor: Color
    let storageName: String
    let isReorganizing: Bool
    @Binding var expandedCategories: Set<String>
    let onDelete: () -> Void
    let onEdit: (String, String) -> Void
    let onMove: (String, String, String) -> Void
    @Binding var draggedItem: String?
    @Binding var draggedFromCategory: String?

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func items(in category: String) -> [String] {
        let items = data[category] ?? []
        guard !normalizedSearch.isEmpty else { return items }
        return items.filter {
            displayIngredientText(from: $0).lowercased().contains(normalizedSearch)
        }
    }

    private var visibleCategories: [String] {
        if isReorganizing {
            return categories
        }
        return categories.filter { !items(in: $0).isEmpty }
    }

    private var resultCount: Int {
        categories.reduce(0) { $0 + items(in: $1).count }
    }

    var body: some View {
        VStack(spacing: 12) {
            if visibleCategories.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: normalizedSearch.isEmpty ? "basket" : "magnifyingglass")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 58, height: 58)
                        .background(accentColor.opacity(0.11), in: Circle())
                    Text(normalizedSearch.isEmpty ? "Nothing in \(storageName) yet" : "No matching ingredients")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(normalizedSearch.isEmpty ? "Scan groceries or add an ingredient to start stocking this space." : "Try a shorter name or check the other storage tab.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .padding(.horizontal, 20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                if !normalizedSearch.isEmpty {
                    Text("\(resultCount) result\(resultCount == 1 ? "" : "s") in \(storageName)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(visibleCategories, id: \.self) { category in
                    if isReorganizing {
                        CategoryDropSection(
                            categoryName: category,
                            items: data[category] ?? [],
                            isValidDropTarget: draggedItem != nil && draggedFromCategory != category,
                            accentColor: accentColor,
                            onEdit: { onEdit($0, category) },
                            onDelete: { item in
                                data[category]?.removeAll(where: { $0 == item })
                                if data[category]?.isEmpty == true {
                                    data.removeValue(forKey: category)
                                }
                                onDelete()
                            },
                            onDragStart: { item in
                                draggedItem = item
                                draggedFromCategory = category
                            },
                            onDropItem: {
                                guard let item = draggedItem,
                                      let source = draggedFromCategory else { return }
                                onMove(item, source, category)
                            }
                        )
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        pantryCategoryCard(category)
                    }
                }
            }
        }
    }

    private func pantryCategoryCard(_ category: String) -> some View {
        let categoryItems = items(in: category)
        let isExpanded = expandedCategories.contains(category) || !normalizedSearch.isEmpty

        return VStack(spacing: 0) {
            Button {
                ChefBuddyHaptics.selection()
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedCategories.contains(category) {
                        expandedCategories.remove(category)
                    } else {
                        expandedCategories.insert(category)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: categorySymbol(category))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(accentColor)
                        .frame(width: 34, height: 34)
                        .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text(category)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(categoryItems.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                LazyVStack(spacing: 8) {
                    ForEach(categoryItems, id: \.self) { item in
                        Button {
                            ChefBuddyHaptics.light()
                            onEdit(item, category)
                        } label: {
                            HStack(spacing: 12) {
                                Text(ingredientEmoji(for: item))
                                    .font(.system(size: 22))
                                    .frame(width: 40, height: 40)
                                    .background(accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(ingredientDisplayParts(from: item).name)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(9)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(accentColor.opacity(0.10), lineWidth: 1)
        )
    }

    private func categorySymbol(_ category: String) -> String {
        switch category {
        case "Produce": return "leaf.fill"
        case "Protein": return "fork.knife"
        case "Dairy": return "waterbottle.fill"
        case "Condiments": return "takeoutbag.and.cup.and.straw.fill"
        case "Beverages": return "cup.and.saucer.fill"
        case "Spices": return "sparkles"
        case "Snacks": return "birthday.cake.fill"
        default: return "shippingbox.fill"
        }
    }
}

struct StorageUnitView: View {
    let title: String
    let icon: String
    let color: Color
    let categories: [String]
    @Binding var data: [String: [String]]
    let emptyTitle: String
    let emptySubtitle: String
    let onDelete: () -> Void
    let onEdit: (String, String) -> Void
    let onMove: (String, String, String) -> Void
    @Binding var draggedItem: String?
    @Binding var draggedFromCategory: String?

    private var totalCount: Int {
        categories.reduce(0) { result, category in
            result + (data[category]?.count ?? 0)
        }
    }

    private var hasItems: Bool {
        totalCount > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .font(.title2)

                    Text(title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                }

                Spacer()

                Text("\(totalCount)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            VStack(spacing: 24) {

                if hasItems || draggedItem != nil {
                    ForEach(categories, id: \.self) { category in
                        let validDropTarget = draggedItem != nil && draggedFromCategory != category

                        CategoryDropSection(
                            categoryName: category,
                            items: data[category] ?? [],
                            isValidDropTarget: validDropTarget,
                            accentColor: color,
                            onEdit: { itemToEdit in
                                onEdit(itemToEdit, category)
                            },
                            onDelete: { itemToDelete in
                                withAnimation(.spring()) {
                                    data[category]?.removeAll(where: { $0 == itemToDelete })
                                    if data[category]?.isEmpty == true {
                                        data.removeValue(forKey: category)
                                    }
                                    onDelete()
                                }
                            },
                            onDragStart: { item in
                                draggedItem = item
                                draggedFromCategory = category
                            },
                            onDropItem: {
                                guard let item = draggedItem,
                                      let sourceCategory = draggedFromCategory else { return }
                                onMove(item, sourceCategory, category)
                            }
                        )
                    }
                } else {
                    EmptyStorageView(
                        icon: icon,
                        color: color,
                        title: emptyTitle,
                        subtitle: emptySubtitle
                    )
                }
            }
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.03), radius: 10, y: 5)
            )
            .padding(.horizontal, 16)
        }
    }
}

struct CategoryDropSection: View {
    let categoryName: String
    let items: [String]
    let isValidDropTarget: Bool
    let accentColor: Color
    let onEdit: (String) -> Void
    let onDelete: (String) -> Void
    let onDragStart: (String) -> Void
    let onDropItem: () -> Void


    @State private var isTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(categoryName)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            if items.isEmpty {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isTargeted ? accentColor.opacity(0.14) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                isTargeted ? accentColor.opacity(0.65) : Color.gray.opacity(0.2),
                                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [6])
                            )
                    )
                    .frame(height: 64)
                    .overlay(
                        Text(isTargeted ? "Drop ingredient here" : "Drag ingredients here")
                            .font(.footnote.weight(isTargeted ? .semibold : .regular))
                            .foregroundStyle(isTargeted ? accentColor : .secondary)
                    )
                    .padding(.horizontal, 20)
            } else {
                if #available(iOS 16.0, *) {
                    FlowLayout(spacing: 10) {
                        ForEach(items, id: \.self) { item in
                            IngredientCard(
                                fullText: item,
                                onTap: {
                                    onEdit(item)
                                },
                                onDelete: {
                                    onDelete(item)
                                },
                                onDragStart: {
                                    onDragStart(item)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 2)
                }
            }


            Rectangle()
                .fill(
                    isTargeted
                    ? LinearGradient(
                        colors: [accentColor.opacity(0.65), accentColor.opacity(0.3)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    : LinearGradient(
                        colors: [Color.gray.opacity(0.1), Color.gray.opacity(0.3)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: isTargeted ? 10 : 6)
                .cornerRadius(5)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(isTargeted ? accentColor.opacity(0.10) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(
                            isTargeted ? accentColor.opacity(0.40) : Color.clear,
                            lineWidth: isTargeted ? 1.5 : 0
                        )
                )
                .shadow(
                    color: isTargeted ? accentColor.opacity(0.22) : .clear,
                    radius: isTargeted ? 12 : 0,
                    y: 0
                )
        )
        .scaleEffect(isTargeted ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: isTargeted)
        .padding(.horizontal, 12)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onDrop(of: [UTType.text], isTargeted: $isTargeted) { _ in
            onDropItem()
            return true
        }
    }
}

struct EmptyStorageView: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(color.opacity(0.8))
                .padding(14)
                .background(color.opacity(0.12))
                .clipShape(Circle())

            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
    }
}

struct IngredientCard: View {
    let fullText: String
    let onTap: () -> Void
    let onDelete: () -> Void
    let onDragStart: () -> Void

    var parsedEmoji: String {
        let parts = fullText.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? String(parts[0]) : "🥘"
    }

    var parsedTitle: String {
        let parts = fullText.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : fullText
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Text(parsedEmoji)
                        .font(.system(size: 16))

                    Text(parsedTitle)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.4))
                }
            }
            .buttonStyle(.plain)

            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onDelete()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .onDrag {
            onDragStart()
            return NSItemProvider(object: fullText as NSString)
        }
    }
}

struct ActionButton: View {
    let icon: String
    let title: String
    let color: Color
    var isDisabled: Bool = false

    var body: some View {
        HStack {
            Image(systemName: icon)
            Text(title)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .foregroundStyle(isDisabled ? .secondary : color)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke((isDisabled ? Color.gray.opacity(0.2) : color.opacity(0.3)), lineWidth: 1)
        )
        .opacity(isDisabled ? 0.7 : 1)
    }
}

struct ScanStatusCard: View {
    let pantryName: String
    let statusText: String
    let animationStep: Int
    let funEmoji: String
    let accentColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.18), Color.pink.opacity(0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 54, height: 54)

                Text(funEmoji)
                    .font(.system(size: 28))
                    .scaleEffect(animationStep % 2 == 0 ? 1.0 : 1.08)
                    .animation(.spring(response: 0.35, dampingFraction: 0.65), value: animationStep)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("ChefBuddy is organizing \(pantryName)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 5) {
                    Text("Scanning")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    BouncingDotsView(step: animationStep, color: accentColor)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(accentColor.opacity(0.16), lineWidth: 1)
        )
    }
}

struct BouncingDotsView: View {
    let step: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index <= (step % 3) ? color : Color.gray.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .offset(y: index == (step % 3) ? -2 : 0)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }
}


@available(iOS 16.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let point = result.frames[index].origin
            subview.place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var frames: [CGRect] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if currentX + size.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += rowHeight + spacing
                    rowHeight = 0
                }

                frames.append(CGRect(x: currentX, y: currentY, width: size.width, height: size.height))
                rowHeight = max(rowHeight, size.height)
                currentX += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: currentY + rowHeight)
        }
    }
}


struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]
        ) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
