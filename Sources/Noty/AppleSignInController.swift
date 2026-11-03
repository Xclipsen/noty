import SwiftUI
import UIKit
import AuthenticationServices
import NotebookCore

/// One Apple sheet at a time (docs/APPLE-LOGIN.md). What comes back is handed
/// on to the account server and then dropped: no Apple user ID, e-mail or name
/// is stored, logged or put into UserDefaults or backups.
struct AppleAuthorization: Sendable {
    /// Raw nonce for the server; Apple saw only its SHA-256.
    var nonce: String
    var identityToken: String
    /// Only on the very first authorisation for this app, otherwise nil.
    var givenName: String?
}

enum AppleAuthorizationOutcome: Sendable {
    case authorized(AppleAuthorization)
    case canceled
    case failed(String)
}

@MainActor
final class AppleSignInController: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AppleAuthorizationOutcome, Never>?
    private var controller: ASAuthorizationController?
    private var nonce = ""

    /// `withName`: ask for the name (sign-in); linking needs nothing from Apple but the token.
    func authorize(withName: Bool) async -> AppleAuthorizationOutcome {
        guard continuation == nil else { return .canceled }
        nonce = AppleSignIn.makeNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = withName ? [.fullName] : []
        request.nonce = AppleSignIn.hashedNonce(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(_ outcome: AppleAuthorizationOutcome) {
        let continuation = continuation
        self.continuation = nil; controller = nil; nonce = ""
        continuation?.resume(returning: outcome)
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        let token = AppleSignIn.identityToken(credential?.identityToken)
        let givenName = credential?.fullName?.givenName
        MainActor.assumeIsolated {
            guard let token, !nonce.isEmpty else { return finish(.failed("Apple hat keine gültige Anmeldung geliefert. Bitte erneut versuchen.")) }
            finish(.authorized(AppleAuthorization(nonce: nonce, identityToken: token, givenName: givenName)))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let code = (error as? ASAuthorizationError)?.code.rawValue ?? ASAuthorizationError.Code.unknown.rawValue
        MainActor.assumeIsolated {
            if let message = AppleSignInFailure.message(code: code) { finish(.failed(message)) } else { finish(.canceled) }
        }
    }

    /// The key window of the active iPad scene, so the sheet appears over noty
    /// and not over a window that is in the background or gone.
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let ordered = scenes.filter { $0.activationState == .foregroundActive } + scenes.filter { $0.activationState != .foregroundActive }
            for scene in ordered {
                if let window = scene.keyWindow ?? scene.windows.first(where: { !$0.isHidden }) { return window }
            }
            if let scene = ordered.first { return UIWindow(windowScene: scene) }
            return ASPresentationAnchor()
        }
    }
}

/// Apple's own button (`ASAuthorizationAppleIDButton`), as Apple's guidelines ask.
struct AppleSignInButton: UIViewRepresentable {
    var type: ASAuthorizationAppleIDButton.ButtonType = .signIn
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        // The style is fixed at creation; `.id(colorScheme)` at the call site rebuilds it.
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: type, authorizationButtonStyle: colorScheme == .dark ? .white : .black)
        button.cornerRadius = 10
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = isEnabled
        button.alpha = isEnabled ? 1 : 0.5
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tap() { action() }
    }
}
