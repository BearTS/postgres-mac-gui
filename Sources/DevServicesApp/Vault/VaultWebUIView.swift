import ServiceKit
import SwiftUI
import WebKit

/// Hosts Vault's own web UI.
///
/// Vault ships a complete UI at `/ui`, so embedding it gives policies, auth methods, leases and
/// everything else for free rather than reimplementing them. The one piece of glue worth adding
/// is signing in: the token is already known, so it is injected instead of being retyped.
struct VaultWebUIView: NSViewRepresentable {

    let url: URL
    let token: String?
    /// Bumping this reloads the view — used by the Reload button and after a restart.
    let reloadToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(token: token)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Vault's UI keeps its session in localStorage, so seeding that before any page script
        // runs is what makes the embedded UI arrive already signed in.
        if let token, !token.isEmpty {
            let script = WKUserScript(
                source: Coordinator.loginScript(token: token),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(script)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        context.coordinator.lastLoaded = url
        context.coordinator.lastReloadToken = reloadToken
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let shouldReload = context.coordinator.lastLoaded != url
            || context.coordinator.lastReloadToken != reloadToken
        guard shouldReload else { return }
        context.coordinator.lastLoaded = url
        context.coordinator.lastReloadToken = reloadToken
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoaded: URL?
        var lastReloadToken = -1
        private let token: String?

        init(token: String?) {
            self.token = token
        }

        /// Vault's UI has changed how it stores its session between versions, so write every
        /// shape it has used and let the UI pick up whichever one it looks for. If none match,
        /// the UI simply shows its own sign-in form with the token available to copy alongside.
        static func loginScript(token: String) -> String {
            """
            (function () {
              try {
                var payload = {
                  token: "\(token)",
                  displayName: "token",
                  backend: { mountPath: "token", type: "token", displayNamePath: "display_name" },
                  tokenPath: "id",
                  policies: ["root"],
                  renewable: false
                };
                window.localStorage.setItem("vault:authData", JSON.stringify(payload));
                window.localStorage.setItem("vault-token", "\(token)");
              } catch (error) {
                // A blocked localStorage is not fatal: the sign-in form still works.
              }
            })();
            """
        }
    }
}
