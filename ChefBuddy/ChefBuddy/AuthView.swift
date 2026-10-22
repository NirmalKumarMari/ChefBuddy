import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var authVM: AuthViewModel

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isSignUp = true
    @State private var showPassword = false
    @State private var animateScene = false

    let onAuthSuccess: () -> Void

    private var isValidEmail: Bool {
        let expression = "[A-Z0-9a-z._%+]+@[A-Za-z0-9.]+\\.[A-Za-z]{2,64}"
        return NSPredicate(format: "SELF MATCHES %@", expression).evaluate(with: email)
    }

    private var isValidPassword: Bool {
        let expression = "^(?=.*[0-9])(?=.*[!@#$%^&*()_+=\\[\\]{};':\"\\\\|,.<>\\/?]).{6,}$"
        return NSPredicate(format: "SELF MATCHES %@", expression).evaluate(with: password)
    }

    private var isFormValid: Bool {
        isValidEmail && isValidPassword && (!isSignUp || password == confirmPassword)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.18, green: 0.07, blue: 0.24), .black, Color(red: 0.34, green: 0.12, blue: 0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.orange.opacity(0.22))
                .frame(width: 330, height: 330)
                .blur(radius: 80)
                .offset(x: animateScene ? 150 : 90, y: animateScene ? -300 : -235)

            Image(systemName: "fork.knife")
                .font(.system(size: 220, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.035))
                .rotationEffect(.degrees(animateScene ? 9 : -7))
                .offset(x: -145, y: 270)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    ZStack {
                        Circle()
                            .stroke(Color.orange.opacity(0.22), lineWidth: 1)
                            .frame(width: 152, height: 152)
                            .scaleEffect(animateScene ? 1.07 : 0.94)

                        Image("ChefBuddyLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 132, height: 132)
                            .shadow(color: .orange.opacity(0.26), radius: 24, y: 12)
                    }
                    .padding(.top, 16)

                    VStack(spacing: 8) {
                        Text(isSignUp ? "Join ChefBuddy" : "Welcome back")
                            .font(.system(size: 36, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)

                        Text(isSignUp
                             ? "Build a kitchen that remembers what you love."
                             : "Your pantry, cookbook, and plans are ready.")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 4) {
                        authModeButton("Create account", selected: isSignUp) {
                            switchMode(true)
                        }
                        authModeButton("Sign in", selected: !isSignUp) {
                            switchMode(false)
                        }
                    }
                    .padding(4)
                    .background(Color.white.opacity(0.07), in: Capsule())

                    VStack(spacing: 14) {
                        authField(icon: "envelope.fill") {
                            TextField("Email address", text: $email)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .autocorrectionDisabled()
                        }

                        authField(icon: "lock.fill") {
                            HStack {
                                Group {
                                    if showPassword {
                                        TextField("Password", text: $password)
                                    } else {
                                        SecureField("Password", text: $password)
                                    }
                                }
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showPassword.toggle()
                                    }
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                        .foregroundStyle(.white.opacity(0.52))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if isSignUp {
                            authField(icon: "checkmark.shield.fill") {
                                Group {
                                    if showPassword {
                                        TextField("Confirm password", text: $confirmPassword)
                                    } else {
                                        SecureField("Confirm password", text: $confirmPassword)
                                    }
                                }
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            }

                            HStack(spacing: 14) {
                                requirement(password.count >= 6, "6 characters")
                                requirement(password.rangeOfCharacter(from: .decimalDigits) != nil, "1 number")
                                requirement(password.rangeOfCharacter(from: CharacterSet(charactersIn: "!@#$%^&*()_+=[]{};':\"|,.<>/?")) != nil, "1 symbol")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !authVM.errorMessage.isEmpty {
                            Label(authVM.errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.12), lineWidth: 1))

                    Button(action: submit) {
                        HStack {
                            Text(isSignUp ? "Create my kitchen" : "Enter my kitchen")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(
                            isFormValid ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color.white.opacity(0.12)),
                            in: Capsule()
                        )
                        .shadow(color: isFormValid ? .orange.opacity(0.30) : .clear, radius: 18, y: 9)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isFormValid)

                    HStack(spacing: 12) {
                        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                        Text("OR")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                    }

                    ModernGoogleButton {
                        ChefBuddyHaptics.medium()
                        authVM.signInWithGoogle()
                    }

                    Text("Your kitchen data stays attached to your private account.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 28)
                }
                .padding(.horizontal, 24)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                animateScene = true
            }
        }
        .onChange(of: authVM.userSession) { _, session in
            if session != nil { onAuthSuccess() }
        }
    }

    private func switchMode(_ signUp: Bool) {
        ChefBuddyHaptics.selection()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            isSignUp = signUp
            confirmPassword = ""
            authVM.errorMessage = ""
        }
    }

    private func submit() {
        ChefBuddyHaptics.medium()
        if isSignUp {
            authVM.signUp(email: email, pass: password)
        } else {
            authVM.signIn(email: email, pass: password)
        }
    }

    private func authModeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(selected ? Color.white.opacity(0.15) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func authField<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: 22)
            content()
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func requirement(_ met: Bool, _ title: String) -> some View {
        Label(title, systemImage: met ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(met ? .green : .white.opacity(0.38))
    }
}

private struct ModernGoogleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("G")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .red, .yellow, .green],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                    .background(Color.white, in: Circle())

                Text("Continue with Google")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: "arrow.right")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
