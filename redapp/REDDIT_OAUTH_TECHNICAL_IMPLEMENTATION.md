# Reddit OAuth2 Reply Feature - Technical Implementation

## Overview

This document details the technical implementation of Reddit's OAuth2 authentication and reply functionality in the RedApp iOS/macOS application. The implementation transforms a read-only Reddit viewer into a fully interactive client capable of posting replies, voting, and managing comments.

## Architecture Overview

### Core Components

1. **RedditAuthManager** - Singleton authentication manager
2. **OAuth2 Flow Handler** - ASWebAuthenticationSession integration
3. **Keychain Storage** - Secure token persistence
4. **Authenticated API Layer** - OAuth-enabled Reddit API methods
5. **UI Components** - Reply composers and authentication UI

## OAuth2 Implementation Details

### 1. Authentication Flow

```swift
// OAuth2 Authorization Code Flow
1. User initiates login
2. App opens ASWebAuthenticationSession with Reddit authorization URL
3. User authenticates on Reddit.com
4. Reddit redirects to app with authorization code
5. App exchanges code for access token
6. App stores tokens securely in Keychain
```

#### Key Configuration
```swift
struct RedditOAuthConfig {
    static let clientId = "YOUR_CLIENT_ID"
    static let redirectURI = "redapp://auth"
    static let authorizationURL = "https://www.reddit.com/api/v1/authorize.compact"
    static let tokenURL = "https://www.reddit.com/api/v1/access_token"
    static let scopes = ["identity", "edit", "vote", "submit", "read"]
}
```

### 2. Token Management

#### Token Storage (Keychain)
- **Access Token**: Used for API requests
- **Refresh Token**: Used to obtain new access tokens
- **Expiration Date**: Tracks token validity
- **Username**: Cached for UI display

#### Automatic Token Refresh
```swift
private func refreshTokenIfNeeded() async throws {
    guard let expirationDate = tokenExpirationDate else {
        throw RedditAuthError.notAuthenticated
    }
    
    // Refresh if token expires in less than 5 minutes
    if expirationDate.timeIntervalSinceNow < 300 {
        try await refreshAccessToken()
    }
}
```

### 3. Secure Storage Implementation

#### Keychain Integration
```swift
private func saveToKeychain(value: String, key: String) {
    let data = value.data(using: .utf8)!
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: key,
        kSecValueData as String: data
    ]
    
    SecItemDelete(query as CFDictionary)  // Remove existing
    SecItemAdd(query as CFDictionary, nil) // Add new
}
```

### 4. Authenticated API Requests

#### Request Authentication
```swift
func makeAuthenticatedRequest(url: URL, method: String, body: Data?) async throws -> Data {
    // Ensure token is valid
    try await RedditAuthManager.shared.refreshTokenIfNeeded()
    
    guard let accessToken = RedditAuthManager.shared.accessToken else {
        throw RedditAuthError.notAuthenticated
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("RedditApp/1.0", forHTTPHeaderField: "User-Agent")
    request.httpBody = body
    
    let (data, response) = try await URLSession.shared.data(for: request)
    // Handle response...
}
```

## Reply Feature Implementation

### 1. Comment Posting

```swift
func postComment(parentId: String, text: String) async throws -> CommentData {
    let url = URL(string: "https://oauth.reddit.com/api/comment")!
    
    let parameters = [
        "thing_id": parentId,  // t1_xxx for comments, t3_xxx for posts
        "text": text,
        "api_type": "json"
    ]
    
    let body = parameters
        .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
        .joined(separator: "&")
        .data(using: .utf8)
    
    let data = try await makeAuthenticatedRequest(url: url, method: "POST", body: body)
    return parseCommentResponse(data)
}
```

### 2. Real-time UI Updates

#### ObservableObject Pattern
```swift
class CommentData: Identifiable, ObservableObject {
    @Published var replies: [CommentData]
    
    // When user posts a reply, it's immediately added
    func addReply(_ reply: CommentData) {
        replies.insert(reply, at: 0)
    }
}
```

### 3. Reply UI Components

#### ReplyComposer
- TextEditor with glass morphism styling
- Character validation
- Loading states during submission
- Error handling with user-friendly messages

#### Integration Points
1. **Comment replies**: "Reply" button on each comment
2. **Post replies**: "Reply to Post" button under post content
3. **Authentication prompts**: Automatic login flow when unauthenticated

## Security Considerations

### 1. Token Security
- All tokens stored in iOS Keychain (encrypted)
- Tokens never exposed in logs or UI
- Automatic cleanup on logout

### 2. State Parameter (CSRF Protection)
```swift
let state = UUID().uuidString
UserDefaults.standard.set(state, forKey: "reddit_oauth_state")
// Verify state on callback to prevent CSRF attacks
```

### 3. URL Scheme Security
- Custom URL scheme: `redapp://auth`
- Registered in Info.plist
- Prevents interception by other apps

## Error Handling

### Error Types
```swift
enum RedditAuthError: LocalizedError {
    case notAuthenticated
    case tokenExpired
    case networkError(Error)
    case invalidResponse
    case keychainError
    case authenticationCancelled
    case notConfigured
}
```

### User Experience
- Clear error messages
- Automatic retry for network failures
- Graceful degradation (read-only mode when not authenticated)

## Performance Optimizations

### 1. Token Caching
- Tokens loaded once on app startup
- Stored in memory for quick access
- Background refresh before expiration

### 2. Lazy Authentication
- Authentication only required when user attempts interactive actions
- App remains fully functional in read-only mode

### 3. Optimistic UI Updates
- Replies appear immediately in UI
- Rollback on failure
- No need to refresh entire comment tree

## Platform Considerations

### iOS/macOS Compatibility
```swift
#if os(iOS)
    // iOS-specific implementation
    let window = UIApplication.shared.keyWindow
#else
    // macOS-specific implementation
    let window = NSApplication.shared.windows.first
#endif
```

### ASWebAuthenticationSession
- Universal authentication flow
- Works on iOS 12+ and macOS 10.15+
- Handles app switching automatically

## Post Creation Implementation

### 1. Submit Post API Method

```swift
func submitPost(subreddit: String, title: String, text: String?, url: String?) async throws -> String {
    let submitURL = URL(string: "https://oauth.reddit.com/api/submit")!
    
    var parameters = [
        "sr": subreddit,
        "kind": text != nil ? "self" : "link",
        "title": title,
        "api_type": "json"
    ]
    
    if let text = text {
        parameters["text"] = text
    } else if let url = url {
        parameters["url"] = url
    }
    
    // Submit and parse response for new post URL
    let data = try await makeAuthenticatedRequest(url: submitURL, method: "POST", body: body)
    return parsePostURL(from: data)
}
```

### 2. PostComposer UI

The PostComposer provides a clean interface for creating new Reddit posts:

- **Post Type Selection**: Toggle between text posts and link posts
- **Title Input**: Required field with validation
- **Content Input**: 
  - TextEditor for text posts
  - URL field for link posts
- **Submission Handling**: Loading states and error handling
- **Success Action**: Notifies the main view to refresh posts

### 3. Integration Features

- **Toolbar Button**: "Create Post" button appears when authenticated
- **Current Subreddit Context**: Posts are created in the currently viewed subreddit
- **Automatic Refresh**: Posts list refreshes after successful submission
- **Cross-Platform**: Works on iOS, iPadOS, and macOS

## Future Enhancements

1. **Biometric Authentication**: Add Face ID/Touch ID for token access
2. **Multiple Account Support**: Switch between Reddit accounts
3. **Offline Queue**: Queue replies and posts when offline
4. **Push Notifications**: Notify on reply responses
5. **Rich Text Editor**: Markdown preview in composer
6. **Draft Support**: Save post drafts locally
7. **Media Upload**: Support for image/video posts

## Conclusion

This implementation provides a secure, user-friendly way to add Reddit interactivity while maintaining the app's clean architecture. The OAuth2 flow is properly implemented with security best practices, and the UI seamlessly integrates authentication without disrupting the user experience.