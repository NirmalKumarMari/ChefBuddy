// AuthViewModel.swift
// Manages everything related to who is logged in.
// Handles sign-up, sign-in (email and Google), sign-out, and keeping the user's
// Firestore profile in sync. Published properties drive the routing in ContentView
// so the app automatically shows the right screen when auth state changes.

import SwiftUI
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import GoogleSignIn
import Combine

extension Notification.Name {
    static let activePantrySelectionDidChange = Notification.Name("ActivePantrySelectionDidChange")
    static let discoveryFeedbackDidReset = Notification.Name("DiscoveryFeedbackDidReset")
}

// UIKit helper needed because GIDSignIn requires a UIViewController to present
// the OAuth web view. SwiftUI doesn't expose one directly, so we reach into
// the connected scene hierarchy to get the root view controller.
extension UIApplication {
    func getRootViewController() -> UIViewController {
        guard let screen = self.connectedScenes.first as? UIWindowScene else { return UIViewController() }
        guard let root = screen.windows.first?.rootViewController else { return UIViewController() }
        return root
    }
}

// Single source of truth for authentication state. All views that need to know
// who is logged in read from this object via @EnvironmentObject.
class AuthViewModel: ObservableObject {
    @Published var userSession: FirebaseAuth.User?
    @Published var currentUserProfile: DBUser?
    @Published var isFetchingProfile: Bool = true
    @Published var errorMessage: String = ""

    private let db = Firestore.firestore()

    private func sanitizedHandle(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let collapsed = lowered.replacingOccurrences(of: " ", with: "")
        return collapsed.isEmpty ? "chefbuddy" : collapsed
    }

    private func notificationPreferencePayload(_ preferences: [NotificationSlotPreference]) -> [[String: Any]] {
        preferences.map { preference in
            [
                "slotId": preference.slotId,
                "title": preference.title,
                "hour": preference.hour,
                "minute": preference.minute,
                "isEnabled": preference.isEnabled,
                "kind": preference.kind.rawValue
            ]
        }
    }

    init() {

        self.userSession = Auth.auth().currentUser
        if self.userSession != nil {
            fetchUserProfile()
        } else {
            self.isFetchingProfile = false
        }
    }


    // Writes a brand-new DBUser document to Firestore after the user completes
    // onboarding. Called once — subsequent edits use updateUserPreferences.
    func saveUserPreferences(level: String, diets: Set<String>, allergy: Set<String>, macros: Set<String>,
                             age: String, height: String, weight: String, sex: String, targetGoal: String, activity: String,
                             appliances: Set<String>, cookTime: String, mealPrep: Bool, cuisines: Set<String>,
                             spice: String, dislikes: String, servings: String, budget: String,
                             measurementSystem: String = "🇺🇸 US cups & ounces",
                             dailyCalorieTarget: Int?) {
        guard let user = userSession else { return }
        persistChefBuddyMeasurementSystem(measurementSystem)

        let newUser = DBUser(
            auth: user,
            level: level,
            diets: diets,
            allergy: allergy,
            macros: macros,
            age: age,
            height: height,
            weight: weight,
            sex: sex,
            targetGoal: targetGoal,
            activityLevel: activity,
            appliances: appliances,
            cookTime: cookTime,
            mealPrep: mealPrep,
            cuisines: cuisines,
            spiceTolerance: spice,
            dislikes: dislikes,
            servingSize: servings,
            budget: budget,
            measurementSystem: measurementSystem,
            dailyCalorieTarget: dailyCalorieTarget
        )

        do {
            try db.collection("users").document(user.uid).setData(from: newUser)
            self.currentUserProfile = newUser
            print("Successfully saved all user preferences to Firestore.")
        } catch {
            self.errorMessage = "Failed to save profile: \(error.localizedDescription)"
        }
    }

    // Reads the user's Firestore document and populates currentUserProfile.
    // Called on init and after sign-in so the app always has fresh preferences.
    func fetchUserProfile() {
        guard let uid = userSession?.uid else {
            self.isFetchingProfile = false
            return
        }

        self.isFetchingProfile = true
        db.collection("users").document(uid).getDocument { [weak self] snapshot, error in
            DispatchQueue.main.async {
                self?.isFetchingProfile = false
                if let document = snapshot, document.exists {
                    do {
                        var profile = try document.data(as: DBUser.self)
                        if profile.profileHandle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                            profile.profileHandle = profile.email?.split(separator: "@").first.map(String.init) ?? "chefbuddy"
                        }
                        if profile.profileBio == nil {
                            profile.profileBio = ""
                        }
                        if profile.xpTotal == nil { profile.xpTotal = 0 }
                        if profile.rankTier == nil { profile.rankTier = RankTier.lineCook.rawValue }
                        if profile.currentStreak == nil { profile.currentStreak = 0 }
                        if profile.longestStreak == nil { profile.longestStreak = 0 }
                        if profile.activityStats == nil { profile.activityStats = [:] }
                        persistChefBuddyMeasurementSystem(profile.measurementSystem ?? "🇺🇸 US cups & ounces")
                        self?.currentUserProfile = profile
                    } catch {
                        print("Error decoding user profile: \(error)")
                        self?.currentUserProfile = nil
                    }
                } else {
                    self?.currentUserProfile = nil
                }
            }
        }
    }

    // Merges updated preferences into the existing Firestore document.
    // Using merge: true means fields not included here are left untouched.
    func updateUserPreferences(level: String, diets: Set<String>, allergy: Set<String>, macros: Set<String>,
                               age: String, height: String, weight: String, sex: String, targetGoal: String, activity: String,
                               appliances: Set<String>, cookTime: String, mealPrep: Bool, cuisines: Set<String>,
                               spice: String, dislikes: String, servings: String, budget: String,
                               dailyCalorieTarget: Int?,
                               activePantryId: String?,
                               measurementSystem: String = "🇺🇸 US cups & ounces",
                               goalPace: String = "🌱 Steady",
                               cookingFrequency: String = "📅 3–4 days/week",
                               cleanupPreference: String = "🧽 Balanced cleanup",
                               leftoverPreference: String = "🥡 Enjoy leftovers",
                               aiCoachingStyle: String = "🎯 Direct & practical",
                               aiCreativity: String = "✨ Balanced") {
        guard let uid = userSession?.uid else { return }
        persistChefBuddyMeasurementSystem(measurementSystem)
        if var localProfile = currentUserProfile {
            localProfile.measurementSystem = measurementSystem
            currentUserProfile = localProfile
        }

        var updatedData: [String: Any] = [
            "chefLevel": level,
            "dietTags": Array(diets),
            "allergies": Array(allergy),
            "macroTags": Array(macros),
            "age": age,
            "height": height,
            "weight": weight,
            "sex": sex,
            "targetGoal": targetGoal,
            "activityLevel": activity,
            "appliances": Array(appliances),
            "cookTime": cookTime,
            "mealPrep": mealPrep,
            "cuisines": Array(cuisines),
            "spiceTolerance": spice,
            "dislikes": dislikes,
            "servingSize": servings,
            "budget": budget,
            "measurementSystem": measurementSystem,
            "goalPace": goalPace,
            "cookingFrequency": cookingFrequency,
            "cleanupPreference": cleanupPreference,
            "leftoverPreference": leftoverPreference,
            "aiCoachingStyle": aiCoachingStyle,
            "aiCreativity": aiCreativity
        ]

        if let dailyCalorieTarget {
            updatedData["dailyCalorieTarget"] = dailyCalorieTarget
            if var targets = currentUserProfile?.nutritionTargets {
                targets.calories = dailyCalorieTarget
                targets.updatedAt = Date()
                if let encodedTargets = try? Firestore.Encoder().encode(targets) {
                    updatedData["nutritionTargets"] = encodedTargets
                }
            }
        } else {
            updatedData["dailyCalorieTarget"] = FieldValue.delete()
        }

        if let activePantryId {
            updatedData["activePantryId"] = activePantryId
        }

        db.collection("users").document(uid).setData(updatedData, merge: true) { [weak self] error in
            if let error = error {
                self?.errorMessage = "Failed to update preferences: \(error.localizedDescription)"
            } else {
                self?.fetchUserProfile()
                print("Successfully updated extensive preferences.")
            }
        }
    }

    func updateProfileIdentity(handle: String, bio: String) {
        guard let uid = userSession?.uid else { return }

        let normalizedHandle = sanitizedHandle(handle)
        let normalizedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)

        let payload: [String: Any] = [
            "profileHandle": normalizedHandle,
            "profileBio": normalizedBio
        ]

        db.collection("users").document(uid).setData(payload, merge: true) { [weak self] error in
            if let error {
                self?.errorMessage = "Failed to update profile identity: \(error.localizedDescription)"
                return
            }

            guard var profile = self?.currentUserProfile else {
                self?.fetchUserProfile()
                return
            }

            profile.profileHandle = normalizedHandle
            profile.profileBio = normalizedBio
            self?.currentUserProfile = profile
        }
    }

    func completeNotificationOnboarding(enabled: Bool, authorizationStatus: String) {
        guard let uid = userSession?.uid else { return }

        let encodedPreferences = notificationPreferencePayload(NotificationSlotPreference.defaults)

        let updates: [String: Any] = [
            "didCompleteNotificationOnboarding": true,
            "notificationsEnabled": enabled,
            "notificationAuthorizationStatus": authorizationStatus,
            "notificationPreferences": encodedPreferences
        ]

        db.collection("users").document(uid).setData(updates, merge: true) { [weak self] error in
            if let error = error {
                self?.errorMessage = "Failed to update notification preferences: \(error.localizedDescription)"
                return
            }

            guard var profile = self?.currentUserProfile else {
                self?.fetchUserProfile()
                return
            }

            profile.didCompleteNotificationOnboarding = true
            profile.notificationsEnabled = enabled
            profile.notificationAuthorizationStatus = authorizationStatus
            if profile.notificationPreferences == nil {
                profile.notificationPreferences = NotificationSlotPreference.defaults
            }
            self?.currentUserProfile = profile
        }
    }

    func updateNotificationPreferences(
        enabled: Bool,
        authorizationStatus: String,
        preferences: [NotificationSlotPreference]
    ) {
        guard let uid = userSession?.uid else { return }

        let encodedPreferences = notificationPreferencePayload(preferences)
        let updates: [String: Any] = [
            "notificationsEnabled": enabled,
            "notificationAuthorizationStatus": authorizationStatus,
            "notificationPreferences": encodedPreferences
        ]

        db.collection("users").document(uid).setData(updates, merge: true) { [weak self] error in
            if let error = error {
                self?.errorMessage = "Failed to update notification preferences: \(error.localizedDescription)"
                return
            }

            guard var profile = self?.currentUserProfile else {
                self?.fetchUserProfile()
                return
            }

            profile.notificationsEnabled = enabled
            profile.notificationAuthorizationStatus = authorizationStatus
            profile.notificationPreferences = preferences
            self?.currentUserProfile = profile
        }
    }

    func updateActivePantrySelection(_ pantryId: String?) {
        guard let uid = userSession?.uid else { return }

        let payload: [String: Any] = pantryId.map { ["activePantryId": $0] } ?? ["activePantryId": FieldValue.delete()]

        db.collection("users").document(uid).setData(payload, merge: true) { [weak self] error in
            if let error = error {
                self?.errorMessage = "Failed to save pantry preference: \(error.localizedDescription)"
                return
            }

            guard var profile = self?.currentUserProfile else { return }
            profile.activePantryId = pantryId
            self?.currentUserProfile = profile
            NotificationCenter.default.post(
                name: .activePantrySelectionDidChange,
                object: nil,
                userInfo: ["pantryId": pantryId as Any]
            )
        }
    }

    func updateNutritionTargets(_ targets: NutritionTargets) {
        guard let uid = userSession?.uid else { return }

        do {
            let encoded = try Firestore.Encoder().encode(targets)
            let payload: [String: Any] = [
                "nutritionTargets": encoded,
                "dailyCalorieTarget": targets.calories
            ]

            db.collection("users").document(uid).setData(payload, merge: true) { [weak self] error in
                if let error {
                    self?.errorMessage = "Failed to save nutrition targets: \(error.localizedDescription)"
                    return
                }

                guard var profile = self?.currentUserProfile else {
                    self?.fetchUserProfile()
                    return
                }
                profile.nutritionTargets = targets
                profile.dailyCalorieTarget = targets.calories
                self?.currentUserProfile = profile
            }
        } catch {
            errorMessage = "Failed to encode nutrition targets: \(error.localizedDescription)"
        }
    }

    func resetDiscoverySuggestions(completion: ((Bool) -> Void)? = nil) {
        guard let uid = userSession?.uid else {
            completion?(false)
            return
        }

        Task {
            do {
                let feedbackRef = db.collection("users").document(uid).collection("discoveryFeedback")
                let snapshot = try await feedbackRef.getDocuments()
                let batch = db.batch()
                snapshot.documents.forEach { batch.deleteDocument($0.reference) }
                try await batch.commit()

                await MainActor.run {
                    NotificationCenter.default.post(name: .discoveryFeedbackDidReset, object: nil)
                    completion?(true)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to reset AI suggestions: \(error.localizedDescription)"
                    completion?(false)
                }
            }
        }
    }


    // Creates a new Firebase Auth account then immediately fetches the profile
    // so ContentView can route to the preferences setup screen.
    func signUp(email: String, pass: String) {
        Auth.auth().createUser(withEmail: email, password: pass) { [weak self] result, error in
            if let error = error {
                self?.errorMessage = error.localizedDescription
                return
            }
            self?.userSession = result?.user
            self?.fetchUserProfile()
        }
    }

    // Signs in with email/password and fetches the profile to restore app state.
    func signIn(email: String, pass: String) {
        Auth.auth().signIn(withEmail: email, password: pass) { [weak self] result, error in
            if let error = error {
                self?.errorMessage = error.localizedDescription
                return
            }
            self?.userSession = result?.user
            self?.fetchUserProfile()
        }
    }


    // Triggers the Google OAuth flow. On success, exchanges the Google credential
    // for a Firebase credential so Auth and Firestore stay in sync.
    func signInWithGoogle() {

        guard let clientID = FirebaseApp.app()?.options.clientID else { return }


        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config


        GIDSignIn.sharedInstance.signIn(withPresenting: UIApplication.shared.getRootViewController()) { [weak self] result, error in
            if let error = error {
                let loweredDescription = error.localizedDescription.lowercased()
                if loweredDescription.contains("canceled") || loweredDescription.contains("cancelled") {
                    self?.errorMessage = ""
                    return
                }
                self?.errorMessage = error.localizedDescription
                return
            }

            guard let user = result?.user, let idToken = user.idToken?.tokenString else { return }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: user.accessToken.tokenString)

            Auth.auth().signIn(with: credential) { authResult, authError in
                if let error = authError {
                    self?.errorMessage = error.localizedDescription
                    return
                }
                self?.userSession = authResult?.user
                self?.fetchUserProfile()
            }
        }
    }


    // Clears both Firebase and Google sessions and wipes local state so the
    // next view render routes back to onboarding immediately.
    func signOut() {
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
        self.userSession = nil
        self.currentUserProfile = nil
    }
}
