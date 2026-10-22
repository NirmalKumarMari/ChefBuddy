// ChefBuddyApp.swift
// The app's entry point. Configures Firebase before any view loads (required by the SDK)
// and registers the Google Sign-In URL handler so OAuth callbacks are routed correctly.

import SwiftUI
import FirebaseCore
import GoogleSignIn

// AppDelegate exists solely to call FirebaseApp.configure() at the earliest
// possible moment. Firebase must be configured before any SDK call happens,
// which is why this lives in didFinishLaunchingWithOptions rather than a view.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {


        FirebaseApp.configure()

        return true
    }
}

@main
struct ChefBuddyApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()

                .onOpenURL { url in
                    if ChefBuddyDeepLinkRouter.shared.handle(url) == false {
                        // Routes OAuth redirect URLs back to GIDSignIn after the user
                        // authenticates in Safari. Without this, Google Sign-In breaks.
                        GIDSignIn.sharedInstance.handle(url)
                    }
                }
        }
    }
}
