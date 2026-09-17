import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import SwiftUI

/// Google sign-in using OAuth 2.0 with PKCE (no Google SDK needed).
/// Grants read-only access to the user's Google Docs and their Drive file list.
@Observable
final class GoogleAuth {
    enum AuthError: LocalizedError {
        case notConfigured
        case notSignedIn
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Google sign-in isn't set up yet. Add your OAuth client ID in AppConfig.swift (see README)."
            case .notSignedIn:
                "Sign in with Google in Settings to read this doc."
            case .cancelled:
                "Google sign-in was cancelled."
            case .failed(let message):
                "Google sign-in failed: \(message)"
            }
        }
    }

    private struct StoredTokens: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var email: String?
        var grantedScopes: [String]?
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Double
        let refreshToken: String?
        let idToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case scope
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    enum Scope {
        static let docs = "https://www.googleapis.com/auth/documents.readonly"
        /// File names and dates only, used to list the user's Docs.
        static let driveList = "https://www.googleapis.com/auth/drive.metadata.readonly"
    }

    static let scopes = ["openid", "email", Scope.docs, Scope.driveList].joined(separator: " ")

    private(set) var email: String?
    private(set) var isSignedIn = false
    private(set) var grantedScopes: Set<String> = []
    private var tokens: StoredTokens?
    private var refreshTask: Task<String, Error>?

    var isConfigured: Bool { !AppConfig.googleClientID.isEmpty }

    /// Whether the user allowed NoteFlash to list their Docs. Google lets people
    /// decline individual permissions, and older sign-ins predate this one.
    var canListDocs: Bool { isSignedIn && grantedScopes.contains(Scope.driveList) }

    init() {
        if let data = KeychainStore.data(for: .googleTokens),
           let stored = try? JSONDecoder().decode(StoredTokens.self, from: data) {
            apply(stored)
        }
    }

    // MARK: Sign in / out

    func signIn(using session: WebAuthenticationSession) async throws {
        guard isConfigured else { throw AuthError.notConfigured }

        let verifier = Self.randomURLSafeString(byteCount: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(byteCount: 16)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.googleClientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        if let email {
            components.queryItems?.append(URLQueryItem(name: "login_hint", value: email))
        }

        let callbackURL: URL
        do {
            callbackURL = try await session.authenticate(
                using: components.url!,
                callbackURLScheme: Self.redirectScheme
            )
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw AuthError.cancelled
        }

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw error == "access_denied" ? AuthError.cancelled : AuthError.failed(error)
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.failed("Unexpected response from Google.")
        }

        let response = try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "client_id": AppConfig.googleClientID,
            "redirect_uri": Self.redirectURI,
        ])
        // Google only returns a refresh token on first consent, so keep the existing one.
        let stored = StoredTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? tokens?.refreshToken,
            expiresAt: Date.now.addingTimeInterval(response.expiresIn),
            email: response.idToken.flatMap(Self.email(fromIDToken:)) ?? email,
            grantedScopes: response.scope.map(Self.scopeList)
        )
        save(stored)
    }

    func signOut() {
        if let token = tokens?.refreshToken ?? tokens?.accessToken {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncoded(["token": token])
            Task { _ = try? await URLSession.shared.data(for: request) }
        }
        refreshTask?.cancel()
        refreshTask = nil
        save(nil)
    }

    // MARK: Tokens

    /// Returns an unexpired access token, refreshing it if needed.
    func validAccessToken() async throws -> String {
        guard let tokens else { throw AuthError.notSignedIn }
        if tokens.expiresAt.timeIntervalSinceNow > 60 {
            return tokens.accessToken
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let refreshToken = tokens.refreshToken else {
            save(nil)
            throw AuthError.notSignedIn
        }

        let task = Task { () throws -> String in
            do {
                let response = try await self.requestTokens([
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": AppConfig.googleClientID,
                ])
                var updated = tokens
                updated.accessToken = response.accessToken
                updated.expiresAt = Date.now.addingTimeInterval(response.expiresIn)
                if let newRefresh = response.refreshToken { updated.refreshToken = newRefresh }
                if let scope = response.scope { updated.grantedScopes = Self.scopeList(scope) }
                self.save(updated)
                return response.accessToken
            } catch AuthError.failed(let reason) where reason.contains("invalid_grant") {
                // Refresh token was revoked or expired; the user needs to sign in again.
                self.save(nil)
                throw AuthError.notSignedIn
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Forces the next `validAccessToken()` call to refresh (after a 401).
    func invalidateAccessToken() {
        guard var current = tokens else { return }
        current.expiresAt = .distantPast
        tokens = current
    }

    private func requestTokens(_ parameters: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(parameters)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data)
            let reason = [oauthError?.error, oauthError?.errorDescription].compactMap { $0 }.joined(separator: ": ")
            throw AuthError.failed(reason.isEmpty ? "HTTP \(status)" : reason)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func save(_ stored: StoredTokens?) {
        KeychainStore.set(stored.flatMap { try? JSONEncoder().encode($0) }, for: .googleTokens)
        apply(stored)
    }

    private func apply(_ stored: StoredTokens?) {
        tokens = stored
        email = stored?.email
        isSignedIn = stored != nil
        grantedScopes = Set(stored?.grantedScopes ?? [])
    }

    // MARK: Helpers

    /// iOS OAuth clients redirect to the reversed client ID scheme.
    private static var redirectScheme: String {
        let prefix = AppConfig.googleClientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(prefix)"
    }

    private static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    private static func scopeList(_ scope: String) -> [String] {
        scope.split(separator: " ").map(String.init)
    }

    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ parameters: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = parameters
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}
