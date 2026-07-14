import Foundation
import AuthenticationServices
import Security

// MARK: - Reddit OAuth Configuration
struct RedditOAuthConfig {
    // IMPORTANT: Users must provide their own Reddit app credentials
    // To get a client ID:
    // 1. Go to https://www.reddit.com/prefs/apps
    // 2. Click "Create App" or "Create Another App"
    // 3. Choose "installed app" as the type
    // 4. Set redirect URI to: redapp://auth
    // 5. Copy the client ID (shown under your app name)
    // Note: For "installed apps", client secret is not required (leave empty)
    
    static let redirectURI = "redapp://auth"
    static let authorizationURL = "https://www.reddit.com/api/v1/authorize.compact"
    static let tokenURL = "https://www.reddit.com/api/v1/access_token"
    static let scopes = ["identity", "edit", "vote", "submit", "read", "mysubreddits", "privatemessages", "history", "flair"]
    
    static var clientId: String {
        return RedditAuthManager.shared.getStoredClientId() ?? ""
    }
    
    static var clientSecret: String {
        return RedditAuthManager.shared.getStoredClientSecret() ?? ""
    }
    
    static var isConfigured: Bool {
        let id = clientId
        // For installed apps, only client ID is required
        return !id.isEmpty
    }
}

// MARK: - Authentication Errors
enum RedditAuthError: LocalizedError {
    case notAuthenticated
    case tokenExpired
    case networkError(Error)
    case invalidResponse
    case keychainError
    case authenticationCancelled
    case notConfigured
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Please log in to perform this action"
        case .tokenExpired:
            return "Session expired. Please log in again"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from Reddit"
        case .keychainError:
            return "Failed to save credentials"
        case .authenticationCancelled:
            return "Authentication was cancelled"
        case .notConfigured:
            return "Reddit API credentials not configured. Please enter your Reddit app credentials in Settings."
        }
    }
}

// MARK: - Reddit Auth Manager
class RedditAuthManager: NSObject, ObservableObject {
    static let shared = RedditAuthManager()
    
    @Published var isAuthenticated = false
    @Published var username: String?
    @Published var accessToken: String?
    
    private var refreshToken: String?
    private var tokenExpirationDate: Date?
    private var authenticationSession: ASWebAuthenticationSession?
    
    // Keychain keys
    private let keychainService = "com.redapp.reddit"
    private let accessTokenKey = "reddit_access_token"
    private let refreshTokenKey = "reddit_refresh_token"
    private let usernameKey = "reddit_username"
    private let expirationKey = "reddit_token_expiration"
    private let clientIdKey = "reddit_client_id"
    private let clientSecretKey = "reddit_client_secret"
    
    override init() {
        super.init()
        loadStoredCredentials()
    }
    
    // MARK: - Public Methods
    
    func authenticate() async throws {
        // Check if client ID is configured
        guard RedditOAuthConfig.isConfigured else {
            throw RedditAuthError.notConfigured
        }
        
        let authURL = try buildAuthorizationURL()
        
        return try await withCheckedThrowingContinuation { continuation in
            authenticationSession = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "redapp"
            ) { [weak self] callbackURL, error in
                guard let self = self else { return }
                
                if let error = error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: RedditAuthError.authenticationCancelled)
                    } else {
                        continuation.resume(throwing: RedditAuthError.networkError(error))
                    }
                    return
                }
                
                guard let callbackURL = callbackURL,
                      let code = self.extractCode(from: callbackURL) else {
                    continuation.resume(throwing: RedditAuthError.invalidResponse)
                    return
                }
                
                Task {
                    do {
                        try await self.exchangeCodeForToken(code: code)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            authenticationSession?.presentationContextProvider = self
            authenticationSession?.prefersEphemeralWebBrowserSession = false
            authenticationSession?.start()
        }
    }
    
    func logout() {
        // Clear tokens from memory
        accessToken = nil
        refreshToken = nil
        username = nil
        tokenExpirationDate = nil
        isAuthenticated = false
        
        // Clear tokens from keychain
        deleteFromKeychain(key: accessTokenKey)
        deleteFromKeychain(key: refreshTokenKey)
        deleteFromKeychain(key: usernameKey)
        deleteFromKeychain(key: expirationKey)
    }

    /// Force a token refresh using the stored refresh token.
    /// Useful when the current access token is invalid but not near expiry.
    func refreshAccessTokenManually() async throws {
        try await refreshAccessToken()
    }

    func refreshTokenIfNeeded() async throws {
        guard let expirationDate = tokenExpirationDate else {
            throw RedditAuthError.notAuthenticated
        }
        
        // Refresh if token expires in less than 5 minutes
        if expirationDate.timeIntervalSinceNow < 300 {
            try await refreshAccessToken()
        }
    }
    
    // MARK: - Private Methods
    
    private func buildAuthorizationURL() throws -> URL {
        var components = URLComponents(string: RedditOAuthConfig.authorizationURL)!
        
        let state = UUID().uuidString
        UserDefaults.standard.set(state, forKey: "reddit_oauth_state")
        
        components.queryItems = [
            URLQueryItem(name: "client_id", value: RedditOAuthConfig.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: RedditOAuthConfig.redirectURI),
            URLQueryItem(name: "duration", value: "permanent"),
            URLQueryItem(name: "scope", value: RedditOAuthConfig.scopes.joined(separator: " "))
        ]
        
        guard let url = components.url else {
            throw RedditAuthError.invalidResponse
        }
        
        return url
    }
    
    private func extractCode(from url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        
        // Verify state to prevent CSRF
        if let state = components?.queryItems?.first(where: { $0.name == "state" })?.value,
           let savedState = UserDefaults.standard.string(forKey: "reddit_oauth_state"),
           state == savedState {
            UserDefaults.standard.removeObject(forKey: "reddit_oauth_state")
            return components?.queryItems?.first(where: { $0.name == "code" })?.value
        }
        
        return nil
    }
    
    private func exchangeCodeForToken(code: String) async throws {
        var request = URLRequest(url: URL(string: RedditOAuthConfig.tokenURL)!)
        request.httpMethod = "POST"
        
        // Reddit requires basic auth for token exchange
        // For installed apps, use empty string if no client secret
        let clientSecret = RedditOAuthConfig.clientSecret.isEmpty ? "" : RedditOAuthConfig.clientSecret
        let credentials = "\(RedditOAuthConfig.clientId):\(clientSecret)"
        let base64Credentials = credentials.data(using: .utf8)!.base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
        
        let parameters = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": RedditOAuthConfig.redirectURI
        ]
        
        request.httpBody = parameters
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RedditAuthError.invalidResponse
        }
        
        try await handleTokenResponse(data: data)
        
        // Fetch user info after successful authentication
        try await fetchUserInfo()
    }
    
    private func refreshAccessToken() async throws {
        guard let refreshToken = refreshToken else {
            throw RedditAuthError.notAuthenticated
        }
        
        var request = URLRequest(url: URL(string: RedditOAuthConfig.tokenURL)!)
        request.httpMethod = "POST"
        
        // For installed apps, use empty string if no client secret
        let clientSecret = RedditOAuthConfig.clientSecret.isEmpty ? "" : RedditOAuthConfig.clientSecret
        let credentials = "\(RedditOAuthConfig.clientId):\(clientSecret)"
        let base64Credentials = credentials.data(using: .utf8)!.base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
        
        let parameters = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        
        request.httpBody = parameters
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            // Only force logout when token is truly invalid/revoked.
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 400 || httpResponse.statusCode == 401 || httpResponse.statusCode == 403,
               responseIndicatesInvalidRefreshToken(data: data) {
                logout()
                throw RedditAuthError.tokenExpired
            }
            throw RedditAuthError.invalidResponse
        }
        
        try await handleTokenResponse(data: data)
    }
    
    private func handleTokenResponse(data: Data) async throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw RedditAuthError.invalidResponse
        }
        
        self.accessToken = accessToken
        
        if let refreshToken = json["refresh_token"] as? String {
            self.refreshToken = refreshToken
        }
        
        // Calculate expiration date
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        self.tokenExpirationDate = Date().addingTimeInterval(expiresIn)
        
        // Save to keychain
        await MainActor.run {
            self.isAuthenticated = true
        }
        
        saveToKeychain(value: accessToken, key: accessTokenKey)
        if let refreshToken = refreshToken {
            saveToKeychain(value: refreshToken, key: refreshTokenKey)
        }
        if let expirationDate = tokenExpirationDate {
            saveToKeychain(value: String(expirationDate.timeIntervalSince1970), key: expirationKey)
        }
    }
    
    private func fetchUserInfo() async throws {
        guard let accessToken = accessToken else {
            throw RedditAuthError.notAuthenticated
        }
        
        var request = URLRequest(url: URL(string: "https://oauth.reddit.com/api/v1/me")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("RedditApp/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let username = json["name"] as? String else {
            throw RedditAuthError.invalidResponse
        }
        
        await MainActor.run {
            self.username = username
        }
        
        saveToKeychain(value: username, key: usernameKey)
    }
    
    // MARK: - Keychain Management
    
    private func saveToKeychain(value: String, key: String) {
        let data = value.data(using: .utf8)!

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus != errSecDuplicateItem {
            print("⚠️ [RedditAuthManager] Keychain add failed for '\(key)': \(addStatus)")
            return
        }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus != errSecSuccess {
            print("⚠️ [RedditAuthManager] Keychain update failed for '\(key)': \(updateStatus)")
        }
    }
    
    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        
        return nil
    }
    
    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
    
    private func loadStoredCredentials() {
        accessToken = loadFromKeychain(key: accessTokenKey)
        refreshToken = loadFromKeychain(key: refreshTokenKey)
        username = loadFromKeychain(key: usernameKey)
        
        if let expirationString = loadFromKeychain(key: expirationKey),
           let expirationInterval = Double(expirationString) {
            tokenExpirationDate = Date(timeIntervalSince1970: expirationInterval)
        }
        
        isAuthenticated = accessToken != nil && refreshToken != nil
        
        // Check if token is expired
        if let expirationDate = tokenExpirationDate,
           expirationDate < Date() {
            // Token expired, attempt refresh
            Task {
                try? await refreshAccessToken()
            }
        }
    }
    
    // MARK: - Reddit API Credentials Management
    
    func setRedditCredentials(clientId: String, clientSecret: String) {
        saveToKeychain(value: clientId, key: clientIdKey)
        saveToKeychain(value: clientSecret, key: clientSecretKey)
    }
    
    func getStoredClientId() -> String? {
        return loadFromKeychain(key: clientIdKey)
    }
    
    func getStoredClientSecret() -> String? {
        return loadFromKeychain(key: clientSecretKey)
    }
    
    func clearRedditCredentials() {
        deleteFromKeychain(key: clientIdKey)
        deleteFromKeychain(key: clientSecretKey)
    }
    
    func hasStoredCredentials() -> Bool {
        // For installed apps, only client ID is required
        guard let clientId = getStoredClientId() else { return false }
        return !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func responseIndicatesInvalidRefreshToken(data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        let errorString = (json["error"] as? String)?.lowercased() ?? ""
        let description = (json["error_description"] as? String)?.lowercased() ?? ""
        let combined = "\(errorString) \(description)"

        return combined.contains("invalid_grant")
            || combined.contains("invalid_token")
            || combined.contains("revoked")
            || combined.contains("expired")
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding
extension RedditAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            fatalError("No window found")
        }
        return window
        #else
        return NSApplication.shared.windows.first!
        #endif
    }
}
