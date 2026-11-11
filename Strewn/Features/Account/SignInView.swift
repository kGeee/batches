import SwiftUI
import AuthenticationServices
import CryptoKit

/// First screen when signed out. Email code works on any build; Sign in with Apple shows once
/// APPLE_SIGN_IN = YES (it needs a paid developer team and the Apple provider in Supabase).
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var working = false
    @State private var problem: String?
    @State private var nonce = ""
    /// Only the App Review account has a password; the link to it stays small.
    @State private var usePassword = false
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case email, code, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LittlePile().frame(height: 150).frame(maxWidth: .infinity).padding(.top, 48)
                Text("Batches").font(.system(size: 46, weight: .bold, design: .serif))
                Text("Your photos in batches, full frame, shared with the people who were there.")
                    .font(.title3).foregroundStyle(.secondary)

                if model.isDemo {
                    Label("Demo mode: no server yet, so you'll be kevin with a few sample friends. Any six-digit code works.",
                          systemImage: "testtube.2")
                        .font(.footnote).padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                if model.appleSignInEnabled {
                    SignInWithAppleButton(.continue) { request in
                        nonce = Self.randomNonce()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = Self.sha256(nonce)
                    } onCompletion: { result in
                        handleApple(result)
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    HStack { line; Text("or").font(.footnote).foregroundStyle(.secondary); line }
                }

                if usePassword {
                    TextField("Email", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .email).submitLabel(.next).onSubmit { focus = .password }
                        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12))
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password).submitLabel(.go).onSubmit(signInWithPassword)
                        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12))
                    Button(action: signInWithPassword) {
                        Text("Sign in").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(.primary)
                    .foregroundStyle(!emailLooksValid || password.isEmpty || working ? Color.secondary : Color(uiColor: .systemBackground))
                    .disabled(!emailLooksValid || password.isEmpty || working)
                    Button("Use a sign-in code instead") { usePassword = false; password = ""; problem = nil }
                        .font(.footnote)
                } else if !codeSent {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .email).submitLabel(.send).onSubmit(sendCode)
                        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12))
                    Button(action: sendCode) {
                        Text("Email me a sign-in code").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(.primary)
                    // The button is white at night, so the label can't be the default white too.
                    .foregroundStyle(!emailLooksValid || working ? Color.secondary : Color(uiColor: .systemBackground))
                    .disabled(!emailLooksValid || working)
                    Button("Sign in with a password") { usePassword = true; problem = nil; focus = .email }
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Tap the link we sent to \(email) on this phone, or enter its six-digit code.").font(.subheadline)
                    TextField("123456", text: $code)
                        .textContentType(.oneTimeCode).keyboardType(.numberPad)
                        .font(.title2.monospacedDigit()).multilineTextAlignment(.center)
                        .focused($focus, equals: .code)
                        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12))
                        .onChange(of: code) { _, new in
                            code = String(new.filter(\.isNumber).prefix(6))
                            if code.count == 6 { verify() }
                        }
                    HStack {
                        Button("Use a different email") { codeSent = false; code = ""; focus = .email }
                        Spacer()
                        Button("Send again", action: sendCode).disabled(working)
                    }
                    .font(.footnote)
                }

                if working { ProgressView().frame(maxWidth: .infinity) }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DeskMatBackground())
    }

    private var line: some View { Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1) }

    private var emailLooksValid: Bool {
        let parts = email.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".")
    }

    private func sendCode() {
        guard emailLooksValid else { return }
        run {
            try await model.sendSignInCode(to: email.trimmingCharacters(in: .whitespaces))
            codeSent = true
            focus = .code
        }
    }

    private func signInWithPassword() {
        guard emailLooksValid, !password.isEmpty else { return }
        run { try await model.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password) }
    }

    private func verify() {
        run { try await model.verifySignInCode(email: email.trimmingCharacters(in: .whitespaces), code: code) }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                problem = "Apple didn't send a sign-in token. Try again, or use email."
                return
            }
            run { try await model.signInWithApple(idToken: token, nonce: nonce) }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled { problem = error.localizedDescription }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        problem = nil
        Task {
            do { try await work() } catch { problem = error.localizedDescription; code = ""; password = "" }
            working = false
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Three prints on the mat, the same picture as the app icon.
struct LittlePile: View {
    var body: some View {
        ZStack {
            card(colors: [.blue.opacity(0.7), .orange.opacity(0.6)], angle: 12, x: 26, y: -8)
            card(colors: [.teal.opacity(0.6), Color(white: 0.85)], angle: -10, x: -22, y: 6)
            card(colors: [.indigo.opacity(0.7), .orange], angle: -2, x: 0, y: 10)
        }
    }

    private func card(colors: [Color], angle: Double, x: CGFloat, y: CGFloat) -> some View {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            .frame(width: 150, height: 100)
            .padding(7)
            .background(Color.paper)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 5)
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: y)
    }
}
