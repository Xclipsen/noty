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
    /// When the request started: a cancel within moments cannot be the user's.
    private var started = Date.distantPast

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
            started = Date()
            controller.performRequests()
        }
    }

    private func finish(_ outcome: AppleAuthorizationOutcome) {
        let continuation = continuation
        self.continuation = nil; controller = nil; nonce = ""
        continuation?.resume(returning: outcome)
    }

    // The delegate callbacks take only Sendable values off the system's
    // objects and then hop onto the main actor; iOS does not promise the
    // main thread here, so `MainActor.assumeIsolated` could trap.
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        let token = AppleSignIn.identityToken(credential?.identityToken)
        let givenName = credential?.fullName?.givenName
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let token, !self.nonce.isEmpty else { return self.finish(.failed("Apple hat keine gültige Anmeldung geliefert. Bitte erneut versuchen.")) }
            self.finish(.authorized(AppleAuthorization(nonce: self.nonce, identityToken: token, givenName: givenName)))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let code = (error as? ASAuthorizationError)?.code.rawValue ?? ASAuthorizationError.Code.unknown.rawValue
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        let domain = underlying?.domain, underlyingCode = underlying?.code
        Task { @MainActor [weak self] in
            guard let self else { return }
            // An immediate cancel (no Apple ID signed in) gives a hint instead of silence.
            let elapsed = Date().timeIntervalSince(self.started)
            if let message = AppleSignInFailure.message(code: code, elapsed: elapsed, underlyingDomain: domain, underlyingCode: underlyingCode) {
                self.finish(.failed(message))
            } else { self.finish(.canceled) }
        }
    }

    /// The key window of the active iPad scene, so the sheet appears over noty
    /// and not over a window that is in the background or gone. Must answer
    /// synchronously: on the main thread directly, otherwise through it.
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if Thread.isMainThread { return MainActor.assumeIsolated { Self.anchor() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { Self.anchor() } }
    }

    private static func anchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.filter { $0.activationState == .foregroundActive } + scenes.filter { $0.activationState != .foregroundActive }
        for scene in ordered {
            if let window = scene.keyWindow ?? scene.windows.first(where: { !$0.isHidden }) { return window }
        }
        if let scene = ordered.first { return UIWindow(windowScene: scene) }
        return ASPresentationAnchor()
    }
}

/// Apple's own button (`ASAuthorizationAppleIDButton`), as Apple's guidelines ask.
/// Type and style are fixed when such a button is created, so the host view
/// replaces it whenever either changes („Konto erstellen“ ↔ „Anmelden“,
/// light ↔ dark).
struct AppleSignInButton: UIViewRepresentable {
    var type: ASAuthorizationAppleIDButton.ButtonType = .signIn
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .clear
        install(in: host, context: context)
        return host
    }
    func updateUIView(_ host: UIView, context: Context) {
        context.coordinator.action = action
        let style: ASAuthorizationAppleIDButton.Style = colorScheme == .dark ? .white : .black
        if context.coordinator.type != type || context.coordinator.style != style { install(in: host, context: context) }
        guard let button = context.coordinator.button else { return }
        button.isEnabled = isEnabled
        button.alpha = isEnabled ? 1 : 0.5
        button.accessibilityLabel = type == .signUp ? "Mit Apple registrieren" : "Mit Apple anmelden"
    }
    private func install(in host: UIView, context: Context) {
        let style: ASAuthorizationAppleIDButton.Style = colorScheme == .dark ? .white : .black
        context.coordinator.button?.removeFromSuperview()
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: type, authorizationButtonStyle: style)
        button.cornerRadius = 10
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: host.leadingAnchor), button.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            button.topAnchor.constraint(equalTo: host.topAnchor), button.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        context.coordinator.button = button
        context.coordinator.type = type
        context.coordinator.style = style
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        var button: ASAuthorizationAppleIDButton?
        var type: ASAuthorizationAppleIDButton.ButtonType?
        var style: ASAuthorizationAppleIDButton.Style?
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tap() { action() }
    }
}
