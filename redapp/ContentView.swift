//
//  ContentView.swift
//  RedditApp
//
//  Created by YourName on 2025-01-01.
//

import SwiftUI
import Combine
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import Foundation
import Kingfisher

// MARK: - Color Extension
extension Color {
    static var customBackground: Color {
        #if os(iOS)
        return Color(UIColor.systemBackground)
        #elseif os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #endif
    }
}
// MARK: - Data Models

struct MediaMetadata: Codable {
    let status: String
    let e: String
    let m: String?
    let p: [MediaImage]?
    let s: MediaImage?
    let id: String

    struct MediaImage: Codable {
        let y: Int?
        let x: Int?
        let u: String? // 'u' is now optional

        enum CodingKeys: String, CodingKey {
            case y, x, u
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            y = try container.decodeIfPresent(Int.self, forKey: .y)
            x = try container.decodeIfPresent(Int.self, forKey: .x)
            u = try container.decodeIfPresent(String.self, forKey: .u)
        }
    }

    enum CodingKeys: String, CodingKey {
        case status, e, m, p, s, id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        e = try container.decode(String.self, forKey: .e)
        m = try container.decodeIfPresent(String.self, forKey: .m)
        p = try container.decodeIfPresent([MediaImage].self, forKey: .p)
        s = try container.decodeIfPresent(MediaImage.self, forKey: .s)
        id = try container.decode(String.self, forKey: .id)
    }
}

struct SubredditResponse: Codable {
    let data: SubredditDataContainer
}

struct SubredditDataContainer: Codable {
    let children: [SubredditPostContainer]
    let after: String?  // For pagination
}

struct SubredditPostContainer: Codable {
    let data: SubredditPostData
}

struct Preview: Codable {
    let images: [PreviewImage]
    let enabled: Bool?
}

struct PreviewImage: Codable {
    let source: PreviewSource
    let resolutions: [PreviewSource]
}

struct PreviewSource: Codable {
    let url: String
    let width: Int
    let height: Int
}

// MARK: - SubredditPostData
struct SubredditPostData: Codable, Identifiable {
    let id: String
    let title: String
    let selftext: String
    let ups: Int
    let num_comments: Int
    let permalink: String
    let thumbnail: String?
    let url: String?
    let preview: Preview?
    let media_metadata: [String: MediaMetadata]?
    let gallery_data: GalleryData?
    let stickied: Bool?

    var previewText: String {
        return String(selftext.prefix(300))
    }

    var fullURL: URL? {
        return URL(string: "https://www.reddit.com\(permalink)")
    }

    var bestImageURL: URL? {
        if let preview = preview, let firstImage = preview.images.first {
            let sourceURLString = firstImage.source.url.replacingOccurrences(of: "&amp;", with: "&")
            if let sourceURL = URL(string: sourceURLString) {
                return sourceURL
            }
        }
        if let mediaMetadata = media_metadata, !mediaMetadata.isEmpty {
            if let firstKey = mediaMetadata.keys.first,
               let metadata = mediaMetadata[firstKey],
               metadata.status == "valid",
               let urlString = metadata.s?.u?.replacingOccurrences(of: "&amp;", with: "&"),
               let url = URL(string: urlString) {
                return url
            }
        }
        if let urlString = url?.lowercased(),
           (urlString.hasSuffix(".jpg") || urlString.hasSuffix(".jpeg") || urlString.hasSuffix(".png") || urlString.hasSuffix(".gif")),
           let fullImageURL = URL(string: urlString) {
            return fullImageURL
        }
        if let thumb = thumbnail,
           !thumb.isEmpty,
           thumb != "self",
           thumb != "default",
           thumb != "nsfw",
           let thumbURL = URL(string: thumb) {
            return thumbURL
        }
        return nil
    }

    var allImageURLs: [URL] {
        var urls = [URL]()
        if let preview = preview, let firstImage = preview.images.first {
            let sourceURLString = firstImage.source.url.replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: sourceURLString) {
                urls.append(url)
            }
        }
        if let gallery = gallery_data, let media = media_metadata {
            for item in gallery.items {
                if let mediaItem = media[item.media_id],
                   mediaItem.status == "valid",
                   let urlString = mediaItem.s?.u?.replacingOccurrences(of: "&amp;", with: "&"),
                   let url = URL(string: urlString) {
                    urls.append(url)
                }
            }
        }
        if let urlString = url?.lowercased(),
           (urlString.hasSuffix(".jpg") || urlString.hasSuffix(".jpeg") || urlString.hasSuffix(".png") || urlString.hasSuffix(".gif")),
           let fullImageURL = URL(string: urlString) {
            urls.append(fullImageURL)
        }
        if let thumb = thumbnail,
           !thumb.isEmpty,
           thumb != "self",
           thumb != "default",
           thumb != "nsfw",
           let thumbURL = URL(string: thumb) {
            urls.append(thumbURL)
        }
        return urls
    }
}

// Supporting structs for gallery and media metadata
struct GalleryData: Codable {
    let items: [GalleryItem]
}

struct GalleryItem: Codable {
    let media_id: String
    let id: Int
}



struct MediaImage: Codable {
    let u: String
    let x: Int?
    let y: Int?
}

struct CommentData: Identifiable {
    let id: String
    let rawText: String
    let replies: [CommentData]
    let processedText: String
    let imageURLs: [URL]
    let links: [(String, URL)]

    var limitedImageURLs: [URL] {
        Array(imageURLs.prefix(2))
    }

    var hasMoreImages: Bool {
        imageURLs.count > 2
    }

    var attributedText: AttributedString? {
        do {
            let attrStr = try AttributedString(markdown: processedText)
            print("Attributed String Created Successfully for Comment ID: \(id)")
            return attrStr
        } catch {
            print("Failed to Create Attributed String for Comment ID: \(id), Error: \(error)")
            return nil
        }
    }
}
// MARK: - Network Service
class NetworkService {
    static let shared = NetworkService()
    private init() {}

    var urlSession: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }
}

// MARK: - Gemini Service
class GeminiService {
    static let shared = GeminiService()
    private init() {}

    var apiKey: String?

    func summarize(text: String) async throws -> String {
        guard let apiKey = apiKey, !apiKey.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=\(apiKey)") else {
            print("GeminiService - Error: API key missing or invalid URL.")
            throw URLError(.badURL)
        }

        let parameters: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": text]
                    ]
                ]
            ]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: parameters) else {
            print("GeminiService - Error: Failed to serialize request body.")
            throw NSError(domain: "GeminiService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize request body."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody

        print("GeminiService - Info: Sending request to \(url.absoluteString)")
        print("GeminiService - Debug: Request body: \(String(data: httpBody, encoding: .utf8) ?? "Invalid body")")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("GeminiService - Error: Invalid HTTP response.")
            throw NSError(domain: "GeminiService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."])
        }

        print("GeminiService - Info: Received response with status code: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            print("GeminiService - Error: HTTP request failed with status code: \(httpResponse.statusCode)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("GeminiService - Debug: Response body: \(responseString)")
            }
            throw NSError(domain: "GeminiService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP request failed."])
        }

        guard let responseString = String(data: data, encoding: .utf8) else {
            print("GeminiService - Error: Failed to decode response data.")
            throw NSError(domain: "GeminiService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to decode response data."])
        }

        print("GeminiService - Debug: Response body: \(responseString)")

        guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            print("GeminiService - Error: Failed to parse JSON response.")
            throw NSError(domain: "GeminiService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON response."])
        }

        guard let candidates = json["candidates"] as? [[String: Any]], !candidates.isEmpty else {
            print("GeminiService - Error: No candidates found in response.")
            throw NSError(domain: "GeminiService", code: 5, userInfo: [NSLocalizedDescriptionKey: "No candidates found in response."])
        }

        guard let content = candidates.first?["content"] as? [String: Any] else {
            print("GeminiService - Error: Content not found in the first candidate.")
            throw NSError(domain: "GeminiService", code: 6, userInfo: [NSLocalizedDescriptionKey: "Content not found in the first candidate."])
        }

        guard let parts = content["parts"] as? [[String: Any]], !parts.isEmpty else {
            print("GeminiService - Error: No parts found in content.")
            throw NSError(domain: "GeminiService", code: 7, userInfo: [NSLocalizedDescriptionKey: "No parts found in content."])
        }

        guard let textSummary = parts.first?["text"] as? String else {
            print("GeminiService - Error: Text summary not found in the first part.")
            throw NSError(domain: "GeminiService", code: 8, userInfo: [NSLocalizedDescriptionKey: "Text summary not found in the first part."])
        }

        print("GeminiService - Info: Successfully summarized text.")
        return textSummary
    }
}

// MARK: - Helper Functions for Image and Link Parsing
func parseImageURLs(from text: String) -> [URL] {
    let imagePattern = "(?i)(?:!\\[[^\\]]*\\]\\()?(https?://[^\\s\\)]+?\\.(?:jpg|jpeg|gif|png|webp|bmp|tiff)(?:\\?[^\\s\\)]+)?)\\)?"

    guard let regex = try? NSRegularExpression(pattern: imagePattern, options: []) else {
        return []
    }

    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, options: [], range: range)

    return matches.compactMap { match in
        guard let range = Range(match.range(at: 1), in: text) else { return nil }

        let urlString = String(text[range])
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return URL(string: urlString)
    }
}

func parseLinks(from text: String) -> [(String, URL)] {
    let linkPattern = "\\[([^\\]]+)\\]\\(([^\\)]+)\\)"
    guard let regex = try? NSRegularExpression(pattern: linkPattern, options: []) else {
        print("Failed to create regex for links.")
        return []
    }
    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, options: [], range: range)

    let imageExtensions = ["jpg", "jpeg", "gif", "png", "webp", "bmp", "tiff"]
    var parsedLinks = [(String, URL)]()

    for match in matches {
        guard let textRange = Range(match.range(at: 1), in: text),
              let urlRange = Range(match.range(at: 2), in: text),
              let url = URL(string: String(text[urlRange])) else {
            continue
        }

        if imageExtensions.contains(url.pathExtension.lowercased()) {
            print("Excluding Image Link: \(url)")
            continue
        }

        let linkText = String(text[textRange])
        parsedLinks.append((linkText, url))
        print("Including Non-Image Link: \(linkText) -> \(url)")
    }

    return parsedLinks
}

func processText(_ text: String, removingImageURLs imageURLs: [URL]) -> String {
    var processedText = text
    for url in imageURLs {
        let urlString = url.absoluteString
        let encodedURLString = urlString.replacingOccurrences(of: "&", with: "&amp;")

        let markdownImagePattern = "!\\[[^\\]]*\\]\\(\(NSRegularExpression.escapedPattern(for: urlString))\\)"
        if let regex = try? NSRegularExpression(pattern: markdownImagePattern, options: []) {
            let range = NSRange(processedText.startIndex..., in: processedText)
            processedText = regex.stringByReplacingMatches(in: processedText, options: [], range: range, withTemplate: "")
            print("Removed Markdown Image: \(urlString)")
        }

        processedText = processedText.replacingOccurrences(of: urlString, with: "")
        print("Removed Standalone Image URL: \(urlString)")

        processedText = processedText.replacingOccurrences(of: encodedURLString, with: "")
        print("Removed Standalone Image URL (encoded): \(encodedURLString)")
    }

    let malformedLinkPattern = "\\]\\s*\\("
    if let regex = try? NSRegularExpression(pattern: malformedLinkPattern, options: []) {
        let range = NSRange(processedText.startIndex..., in: processedText)
        processedText = regex.stringByReplacingMatches(in: processedText, options: [], range: range, withTemplate: "](")
        print("Fixed Malformed Links: Replaced '] (' with ']('")
    }

    return processedText.trimmingCharacters(in: .whitespacesAndNewlines)
}
// MARK: - PostType
enum PostType: String, CaseIterable, Identifiable {
    case new, hot, top

    var id: Self { self }

    var displayName: String {
        switch self {
        case .new: return "New"
        case .hot: return "Hot"
        case .top: return "Top"
        }
    }
}



class RedditAPI {
    static let shared = RedditAPI()
    private init() {}
    
    private var linkId: String?
    private let maxRetryCount = 5
    private let backoffFactor: Double = 2.0
    
    func fetchComments(permalink: String) async throws -> [CommentData] {
        var components = URLComponents(string: "https://www.reddit.com\(permalink).json")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "depth", value: "10"),
            URLQueryItem(name: "threaded", value: "false")
        ]
        
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        print("🌐 Fetching from: \(url)")
        
        let (data, response) = try await NetworkService.shared.urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            print("❌ Bad status: \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              json.count > 1,
              let postData = json[0] as? [String: Any],
              let postDataChildren = (postData["data"] as? [String: Any])?["children"] as? [[String: Any]],
              let firstPost = postDataChildren.first?["data"] as? [String: Any],
              let postId = firstPost["id"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        
        self.linkId = "t3_\(postId)"
        
        let dataDict = json[1]["data"] as? [String: Any]
        let commentsArray = dataDict?["children"] as? [[String: Any]] ?? []
        
        print("📝 Found \(commentsArray.count) top-level comments")
        return try await parseAllComments(commentsArray)
    }
    
    private func parseAllComments(_ commentsArray: [[String: Any]], depth: Int = 0) async throws -> [CommentData] {
        var result = [CommentData]()
        var moreQueue = [(comments: [[String: Any]], depth: Int)]()
        moreQueue.append((commentsArray, depth))
        
        while !moreQueue.isEmpty {
            let current = moreQueue.removeFirst()
            let comments = current.comments
            let currentDepth = current.depth
            
            for commentDict in comments {
                guard let kind = commentDict["kind"] as? String else { continue }
                
                if kind == "t1" {
                    guard let commentData = commentDict["data"] as? [String: Any],
                          let id = commentData["id"] as? String,
                          let body = commentData["body"] as? String else {
                        continue
                    }
                    
                    var replies: [CommentData] = []
                    if let repliesDict = commentData["replies"] as? [String: Any],
                       let repliesData = repliesDict["data"] as? [String: Any],
                       let children = repliesData["children"] as? [[String: Any]] {
                        moreQueue.append((children, currentDepth + 1))
                    }
                    
                    let imageURLs = parseImageURLs(from: body)
                    let links = parseLinks(from: body)
                    let processedText = processText(body, removingImageURLs: imageURLs)
                    
                    let newComment = CommentData(
                        id: id,
                        rawText: body,
                        replies: replies,
                        processedText: processedText,
                        imageURLs: imageURLs,
                        links: links
                    )
                    result.append(newComment)
                    
                } else if kind == "more" {
                    if let moreData = commentDict["data"] as? [String: Any],
                       let children = moreData["children"] as? [String],
                       !children.isEmpty {
                        
                        // Handle rate limiting with exponential backoff
                        var retryCount = 0
                        var moreComments: [CommentData] = []
                        
                        repeat {
                            do {
                                moreComments = try await fetchMoreChildren(children: children)
                                break
                            } catch {
                                retryCount += 1
                                if retryCount >= maxRetryCount { break }
                                let delay = pow(backoffFactor, Double(retryCount))
                                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            }
                        } while retryCount < maxRetryCount
                        
                        result.append(contentsOf: moreComments)
                    }
                }
            }
        }
        
        return result
    }
    
    private func fetchMoreChildren(children: [String]) async throws -> [CommentData] {
        guard let linkId = self.linkId else {
            print("❌ No link_id available for fetchMoreChildren")
            throw URLError(.badURL)
        }
        
        var components = URLComponents(string: "https://www.reddit.com/api/morechildren")!
        components.queryItems = [
            URLQueryItem(name: "api_type", value: "json"),
            URLQueryItem(name: "link_id", value: linkId),
            URLQueryItem(name: "children", value: children.joined(separator: ",")),
            URLQueryItem(name: "sort", value: "confidence"),
            URLQueryItem(name: "limit_children", value: "false"),
            URLQueryItem(name: "depth", value: "10")
        ]
        
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await NetworkService.shared.urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            print("❌ Bad status: \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jsonData = json["json"] as? [String: Any],
              let data = jsonData["data"] as? [String: Any],
              let things = data["things"] as? [[String: Any]] else {
            return []
        }
        
        return try await parseAllComments(things)
    }
    
    func fetchPosts(subreddit: String, type: PostType, limit: Int) async throws -> [SubredditPostData] {
        var components = URLComponents(string: "https://www.reddit.com/r/\(subreddit)/\(type.rawValue).json")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit))
        ]
        
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        
        let (data, response) = try await NetworkService.shared.urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        let subredditResponse = try JSONDecoder().decode(SubredditResponse.self, from: data)
        return subredditResponse.data.children.map { $0.data }
    }
}












// MARK: - ViewModel
class RedditSubredditViewModel: ObservableObject {
    @Published var posts = [SubredditPostData]()
    @Published var isLoading = false
    @Published var error: String?
    @Published var postLimit: String = "50"
    @Published var selectedPostType: PostType = .new

    func fetchSubredditPosts(subreddit: String) {
        guard let limit = Int(postLimit), limit > 0, limit <= 100 else {
            error = "Invalid post limit. Please enter a number between 1 and 100."
            return
        }

        isLoading = true
        error = nil

        Task {
            do {
                let fetchedPosts = try await RedditAPI.shared.fetchPosts(
                    subreddit: subreddit,
                    type: selectedPostType,
                    limit: limit
                )
                
                DispatchQueue.main.async {
                    // Filter pinned posts
                    self.posts = fetchedPosts.filter { $0.stickied != true }
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - ClickableImage
struct ClickableImage: View {
    let url: URL
    let maxHeight: CGFloat
    @State private var showFullScreen = false
    
    var body: some View {
        KFImage(url)
            .placeholder {
                ProgressView()
            }
            .resizable()
            .scaledToFit()
            .frame(maxHeight: maxHeight)
            .cornerRadius(8)
            .onTapGesture {
                showFullScreen = true
            }
            #if os(iOS)
.sheet(isPresented: $showFullScreen) {
    FullScreenImageView(imageURL: url, isPresented: $showFullScreen)
        .interactiveDismissDisabled(false)            }
            #elseif os(macOS)
            .sheet(isPresented: $showFullScreen) {
                FullScreenImageView(imageURL: url, isPresented: $showFullScreen)
                    .frame(minWidth: 600, minHeight: 800)
            }
            #endif
    }
}

// MARK: - PostRowView
struct PostRowView: View {
    let post: SubredditPostData
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack {
                    Image(systemName: "arrow.up")
                        .foregroundColor(.orange)
                    Text("\(post.ups)")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .frame(width: 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text(post.title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    if !post.selftext.isEmpty {
                        Text(isExpanded ? post.selftext : post.previewText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(isExpanded ? nil : 3)

                        if post.selftext.count > 10 {
                            Button(action: { isExpanded.toggle() }) {
                                Text(isExpanded ? "Show less" : "Show more")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                    }

                    HStack {
                        Image(systemName: "bubble.right")
                        Text("\(post.num_comments) comments")
                        Spacer()

                        if let fullURL = post.fullURL {
                            Button(action: {
                                #if os(iOS)
                                UIApplication.shared.open(fullURL)
                                #elseif os(macOS)
                                NSWorkspace.shared.open(fullURL)
                                #endif
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "safari")
                                    Text("Open")
                                        .font(.caption)
                                }
                                .foregroundColor(.blue)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            if let imageUrl = post.bestImageURL {
                ClickableImage(url: imageUrl, maxHeight: 300)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal)
        .background(Color.customBackground)
    }
}
// MARK: - ResizableTextBox Component
struct ResizableTextBox: View {
    let title: String
    let content: String
    let isAnswer: Bool
    @State private var boxHeight: CGFloat

    init(title: String, content: String, isAnswer: Bool = false) {
        self.title = title
        self.content = content
        self.isAnswer = isAnswer
        _boxHeight = State(initialValue: isAnswer ? 300 : 150)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            ScrollView {
                Text(content)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: boxHeight)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.thinMaterial)
                        .opacity(0.7)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThinMaterial)
                        .opacity(0.5)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.4),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blur(radius: 8)
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                }
            }
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)

            HStack {
                Spacer()
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 30, height: 4)
                    .cornerRadius(2)
                Spacer()
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .local)
                    .onChanged { gesture in
                        let maxHeight = isAnswer ? CGFloat(1000) : CGFloat(800)
                        boxHeight = max(100, min(maxHeight, boxHeight + gesture.translation.height))
                    }
            )
        }
    }
}

// MARK: - CommentView
struct CommentView: View {
    let comment: CommentData
    @State private var showAllImages = false
    @State private var visibleRepliesCount: Int = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.blue.opacity(0.3))
                    .frame(width: 2)
                    .padding(.leading, 8)

                VStack(alignment: .leading, spacing: 4) {
                    Text(comment.processedText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.ultraThinMaterial)
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.5),
                                        Color.white.opacity(0.2)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .blur(radius: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                            }
                        }
                        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 2)

                    let imagesToShow = showAllImages ? comment.imageURLs : comment.limitedImageURLs

                    if !imagesToShow.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(imagesToShow, id: \.self) { url in
                                    ClickableImage(url: url, maxHeight: 150)
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                    }

                    if comment.hasMoreImages && !showAllImages {
                        Button("Show more images") {
                            showAllImages = true
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                    }

                    if !comment.links.isEmpty {
                        ForEach(comment.links, id: \.1) { (linkText, url) in
                            Link(destination: url) {
                                Text(linkText)
                                    .foregroundColor(.blue)
                                    .underline()
                            }
                            .padding(.horizontal, 8)
                            .font(.footnote)
                        }
                    }

                    if !comment.replies.isEmpty {
                        ForEach(comment.replies.prefix(visibleRepliesCount)) { reply in
                            CommentView(comment: reply)
                        }

                        if visibleRepliesCount < comment.replies.count {
                            Button("Show more replies") {
                                visibleRepliesCount += 2
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 8)
                        }
                    }
                }
            }
        }
        .padding(.leading, 8)
    }
}

// MARK: - Main View
struct ContentView: View {
    @State private var subreddit: String = "SwiftUI"
    @State private var selectedPost: SubredditPostData?
    @ObservedObject var viewModel = RedditSubredditViewModel()

    var body: some View {
        NavigationSplitView {
            VStack {
                HStack {
                    TextField("Enter subreddit", text: $subreddit)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(maxWidth: 200)
                }
                .padding(.horizontal)

                HStack {
                    Text("Show")
                    TextField("Number of posts", text: $viewModel.postLimit)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        .frame(width: 60)
                        #else
                        .frame(width: 80)
                        #endif
                    Text("posts")

                    Picker("Sort by", selection: $viewModel.selectedPostType) {
                        ForEach(PostType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                }
                .padding(.horizontal)

                Button(action: {
                    viewModel.fetchSubredditPosts(subreddit: subreddit)
                }) {
                    Text("Load")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .disabled(viewModel.isLoading)
                .padding(.bottom)

                ScrollView {
                    if viewModel.isLoading {
                        ProgressView()
                            .padding()
                    } else if let error = viewModel.error {
                        Text(error)
                            .foregroundColor(.red)
                            .padding()
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.posts) { post in
                                Button {
                                    selectedPost = nil
                                    DispatchQueue.main.async {
                                        selectedPost = post
                                    }
                                } label: {
                                    PostRowView(post: post)
                                        .background(
                                            selectedPost?.id == post.id
                                            ? Color.gray.opacity(0.2)
                                            : Color.clear
                                        )
                                }
                                .buttonStyle(PlainButtonStyle())
                                Divider()
                            }
                        }
                    }
                }
            }
            .navigationTitle("r/\(subreddit)")
        } detail: {
            if let selectedPost = selectedPost {
                RedditCommentsView(postPermalink: selectedPost.permalink)
                    .id(selectedPost.id)
            } else {
                Text("Select a post to view comments")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - RedditCommentsView
    struct RedditCommentsView: View {
        let postPermalink: String
        @State private var isLoading = true
        @State private var error: String?
        @State private var allComments = [CommentData]()
        @State private var visibleCount = 20
        @State private var summary: String? = nil
        @State private var isSummarizing = false
        @State private var summaryError: String? = nil
        @State private var question: String = ""
        @State private var answer: String?
        @State private var isAnswering: Bool = false
        @State private var answerError: String? = nil

        var body: some View {
            VStack {
                ScrollView {
                    if isLoading {
                        ProgressView()
                            .padding()
                    } else if let error = error {
                        Text(error)
                            .foregroundColor(.red)
                            .padding()
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(allComments.prefix(visibleCount)) { comment in
                                CommentView(comment: comment)
                            }
                            if visibleCount < allComments.count {
                                Button("Load More Comments") {
                                    visibleCount += 10
                                }
                                .foregroundColor(.blue)
                                .padding()
                            }
                        }
                        .padding()
                    }
                }
                
                HStack {
                    Button(action: copyCommentsToClipboard) {
                        Text("Copy Comments")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    Spacer()
                    Button(action: summarizeComments) {
                        if isSummarizing {
                            ProgressView()
                        } else {
                            Text("Summarize Comments")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    .disabled(isSummarizing)
                }
                .padding(.horizontal)
                .padding(.bottom)

                if let summary = summary {
                    ResizableTextBox(title: "Summary:", content: summary)
                        .padding(.horizontal)
                } else if let summaryError = summaryError {
                    Text("Summary Error: \(summaryError)")
                        .foregroundColor(.red)
                        .padding()
                }

                VStack(alignment: .leading) {
                    Text("Ask a question about the comments:")
                        .font(.headline)
                        .padding(.horizontal)

                    HStack {
                        TextField("Enter your question", text: $question)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .padding(.horizontal)
                            .disabled(isAnswering)
                            .onSubmit {
                                askQuestion()
                            }

                        Button(action: askQuestion) {
                            Text("Ask")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .disabled(isAnswering || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.bottom)

                    if isAnswering {
                        ProgressView("Answering...")
                            .padding(.horizontal)
                    } else if let answer = answer {
                        ResizableTextBox(title: "Answer:", content: answer, isAnswer: true)
                            .padding(.horizontal)
                    } else if let answerError = answerError {
                        Text("Question Error: \(answerError)")
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }
                }
            }
            .onAppear {
                fetchComments()
            }
        }

        private func fetchComments() {
            isLoading = true
            error = nil
            
            Task {
                do {
                    // Instead of creating a SubredditPostData, let's just use the permalink directly
                    let comments = try await RedditAPI.shared.fetchComments(permalink: postPermalink)
                    DispatchQueue.main.async {
                        self.allComments = comments
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.error = error.localizedDescription
                        self.isLoading = false
                    }
                }
            }
        }
        

        private func copyCommentsToClipboard() {
            let prependText = """
            You are the best content writer in the world! These are a Reddit post's comments.
            Summarise the key themes and main points. Identify the top points or themes discussed in the comments, with examples for each. Include a brief overview of any major differing viewpoints if present.

            """
            let allRawComments = flattenComments(comments: allComments).joined(separator: "\n\n")
            let finalClipboardContent = prependText + allRawComments

            #if os(iOS)
            UIPasteboard.general.string = finalClipboardContent
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finalClipboardContent, forType: .string)
            #endif
        }

        private func flattenComments(comments: [CommentData], depth: Int = 0) -> [String] {
            var allRawComments = [String]()
            let indent = String(repeating: "    ", count: depth)
            
            for comment in comments {
                let formattedComment = "\(indent)- \(comment.rawText)"
                allRawComments.append(formattedComment)
                allRawComments.append(contentsOf: flattenComments(comments: comment.replies, depth: depth + 1))
            }
            
            if depth == 0 {
                print("Total comments sent to LLM: \(allRawComments.count)")
            }
            
            return allRawComments
        }

        private func summarizeComments() {
            isSummarizing = true
            summaryError = nil
            let allRawComments = flattenComments(comments: allComments).joined(separator: "\n\n")
            let prompt = """
            Summarize the following Reddit comments, summarize the key themes and main points, with examples of each, provide a final summary of the overall comments:

            \(allRawComments)
            """

            Task {
                do {
                    let fetchedSummary = try await GeminiService.shared.summarize(text: prompt)
                    DispatchQueue.main.async {
                        self.summary = fetchedSummary
                        self.isSummarizing = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.summaryError = error.localizedDescription
                        self.isSummarizing = false
                    }
                }
            }
        }

        private func askQuestion() {
            guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            isAnswering = true
            answer = nil
            answerError = nil

            let allRawComments = flattenComments(comments: allComments).joined(separator: "\n\n")
            let prompt = """
            Let's consider the following Reddit comments:

            \(allRawComments)

            Answer the following question based on the information in the comments above: \(question)
            """

            Task {
                do {
                    let fetchedAnswer = try await GeminiService.shared.summarize(text: prompt)
                    DispatchQueue.main.async {
                        self.answer = fetchedAnswer
                        self.isAnswering = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.answerError = error.localizedDescription
                        self.isAnswering = false
                    }
                }
            }
        }
    }
    
    // MARK: - App Entry Point
    @main
    struct RedditApp: App {
        @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "isOnboarded")

        var body: some Scene {
            WindowGroup {
                if showOnboarding {
                    OnboardingView {
                        loadCredentials()
                        showOnboarding = false
                    }
                    .preferredColorScheme(.dark)
                } else {
                    ContentView()
                        .preferredColorScheme(.dark)
                        .onAppear {
                            loadCredentials()
                        }
                }
            }
        }

        private func loadCredentials() {
            let geminiKey = KeychainHelper.shared.read(forKey: "geminiApiKey")
            GeminiService.shared.apiKey = geminiKey

            // TODO: Set Reddit credentials in your Reddit API client here
            // let redditClientId = KeychainHelper.shared.read(forKey: "redditClientId")
            // let redditClientSecret = KeychainHelper.shared.read(forKey: "redditClientSecret")
            // let redditUsername = KeychainHelper.shared.read(forKey: "redditUsername")
        }
    }
}
