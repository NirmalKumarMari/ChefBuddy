# ChefBuddy: AI-Powered Cooking Assistant (iOS)

A native iOS app that turns a photo of your fridge into recipes and then guides you through cooking step by step, with live camera and voice interaction.

**Timeline:** September 2025 to March 2026 (started as the INFO 449 final iOS project at the University of Washington)  
**Tech:** Swift, SwiftUI, Firebase (Firestore, Storage, Firebase AI Logic), Google Gemini

## Features

- **Fridge scan:** point the camera at your ingredients and get recipe suggestions generated with Gemini.
- **Live cooking guidance:** real-time, step-by-step help driven by live camera frames, with voice questions while you cook.
- **Profiles and nutrition history** stored in Cloud Firestore.
- Optional text-to-speech and Instacart shopping hand-off, enabled with your own keys.

## Setup

1. Open `ChefBuddy/ChefBuddy.xcodeproj` in Xcode.
2. Create your own Firebase project, enable Firestore, Storage, and Firebase AI Logic, and add its `GoogleService-Info.plist` to the `ChefBuddy` target. This file is not included in the repository.
3. Optional: set `GOOGLE_TTS_API_KEY` and `INSTACART_API_KEY` in the app configuration to enable voice output and one-tap shopping.
4. Build and run on a device (the camera is needed for the fridge scan).
