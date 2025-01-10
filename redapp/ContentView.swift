import SwiftUI
import Combine
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import Foundation
import Kingfisher

// MARK: - UIApplication Extension (for dismissing keyboard)
extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder),
                   to: nil,
                   from: nil,
                   for: nil)
    }
}

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
        URL(string: "https://www.reddit.com\(permalink)")
    }

    var bestImageURL: URL? {
        if let preview = preview, let firstImage = preview.images.first {
            let sourceURLString = firstImage.source.url
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: #"\\+"#, with: "", options: .regularExpression)
            if let sourceURL = URL(string: sourceURLString) {
                return sourceURL
            }
        }
        
        if let media = media_metadata, !media.isEmpty {
            if let firstKey = media.keys.first,
               let metadata = media[firstKey],
               metadata.status == "valid",
               let urlString = metadata.s?.u
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: #"\\+"#, with: "", options: .regularExpression),
               let url = URL(string: urlString) {
                return url
            }
        }
        
        if let urlString = url?.lowercased(),
           (urlString.hasSuffix(".jpg") || urlString.hasSuffix(".jpeg") ||
            urlString.hasSuffix(".png") || urlString.hasSuffix(".gif")) {
            let cleanURL = urlString
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: #"\\+"#, with: "", options: .regularExpression)
            if let fullImageURL = URL(string: cleanURL) {
                return fullImageURL
            }
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
        
        // Preview images
        if let preview = preview, let firstImage = preview.images.first {
            let sourceURLString = firstImage.source.url
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: #"\\+"#, with: "", options: .regularExpression)
            if let url = URL(string: sourceURLString) {
                urls.append(url)
            }
        }
        
        // Gallery images
        if let gallery = gallery_data, let media = media_metadata {
            for item in gallery.items {
                if let mediaItem = media[item.media_id],
                   mediaItem.status == "valid",
                   let urlString = mediaItem.s?.u
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: #"\\+"#, with: "", options: .regularExpression),
                   let url = URL(string: urlString) {
                    urls.append(url)
                }
            }
        }
        
        // Direct image URL
        if let urlString = url?.lowercased(),
           (urlString.hasSuffix(".jpg") || urlString.hasSuffix(".jpeg") ||
            urlString.hasSuffix(".png") || urlString.hasSuffix(".gif")) {
            let cleanURL = urlString
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: #"\\+"#, with: "", options: .regularExpression)
            if let url = URL(string: cleanURL) {
                urls.append(url)
            }
        }
        
        // Thumbnail as fallback
        if urls.isEmpty,
           let thumb = thumbnail,
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


// Gallery & Media
struct GalleryData: Codable {
    let items: [GalleryItem]
}

struct GalleryItem: Codable {
    let media_id: String
    let id: Int
}

struct MediaMetadata: Codable {
    let status: String
    let e: String?
    let m: String?
    let p: [MediaImage]?
    let s: MediaImage?
}

struct MediaImage: Codable {
    let u: String
    let x: Int?
    let y: Int?
}

// MARK: - AuthResponse
struct AuthResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType   = "token_type"
        case expiresIn   = "expires_in"
        case scope
    }
}

// MARK: - CommentData
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
            return attrStr
        } catch {
            print("Failed to create AttributedString: \(error)")
            return nil
        }
    }
}

// MARK: - NetworkService
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

// MARK: - GeminiService
class GeminiService {
    static let shared = GeminiService()
    private init() {}

    // Replace with your own API key
    private let apiKey = ""

    func summarize(text: String) async throws -> String {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=\(apiKey)") else {
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
            throw NSError(domain: "GeminiService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize JSON."])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "GeminiService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP status."])
        }
        guard let responseObj = try? JSONSerialization.jsonObject(with: data, options: []),
              let json = responseObj as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let textSummary = parts.first?["text"] as? String else {
            throw NSError(domain: "GeminiService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Response parse error."])
        }
        return textSummary
    }
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

// MARK: - RedditSubredditViewModel
class RedditSubredditViewModel: ObservableObject {
    @Published var posts = [SubredditPostData]()
    @Published var isLoading = false
    @Published var error: String?
    @Published var postLimit: String = "50"
    @Published var selectedPostType: PostType = .new

    private let clientID = ""
    private let clientSecret = ""
    private let username = ""
    private let password = ""
    private let userAgent = "subreddit_summarizer (by /u/)"

    @Published var accessToken: String?

    func authenticate(completion: @escaping () -> Void) {
        guard let url = URL(string: "https://www.reddit.com/api/v1/access_token") else {
            error = "Invalid authentication URL"
            return
        }
        isLoading = true
        error = nil

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        let credentials = "\(clientID):\(clientSecret)"
        guard let credentialsData = credentials.data(using: .utf8) else {
            error = "Invalid credentials format"
            return
        }
        let credentialsBase64 = credentialsData.base64EncodedString()

        request.setValue("Basic \(credentialsBase64)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let bodyString = "grant_type=password&username=\(username)&password=\(password)"
        request.httpBody = bodyString.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        NetworkService.shared.urlSession.dataTask(with: request) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                self?.isLoading = false
                if let err = err {
                    self?.error = "Authentication error: \(err)"
                    return
                }
                guard let data = data else {
                    self?.error = "No data received during auth"
                    return
                }
                do {
                    let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                    self?.accessToken = authResponse.accessToken
                    completion()
                } catch {
                    self?.error = "Failed to decode auth: \(error)"
                }
            }
        }.resume()
    }

    func fetchSubredditPosts(subreddit: String) {
        guard let limit = Int(postLimit), limit > 0, limit <= 100 else {
            error = "Invalid post limit. Enter a number 1–100."
            return
        }
        guard let accessToken = accessToken else {
            error = "Access token not available"
            return
        }
        var components = URLComponents(string: "https://oauth.reddit.com/r/\(subreddit)/\(selectedPostType.rawValue)")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else {
            error = "Invalid URL"
            return
        }

        isLoading = true
        error = nil

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.addValue("bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")

        NetworkService.shared.urlSession.dataTask(with: request) { [weak self] data, response, err in
            DispatchQueue.main.async {
                self?.isLoading = false
                if let err = err {
                    self?.error = "\(err)"
                    return
                }
                guard let data = data else {
                    self?.error = "No data returned."
                    return
                }
                do {
                    let subredditResponse = try JSONDecoder().decode(SubredditResponse.self, from: data)
                    var allPosts = subredditResponse.data.children.map { $0.data }
                    allPosts = allPosts.filter { $0.stickied != true } // remove pinned
                    self?.posts = allPosts
                } catch {
                    self?.error = "Failed to decode posts: \(error)"
                }
            }
        }.resume()
    }
}

import SwiftUI
import Kingfisher

struct ImageViewer: View {
    let imageURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .edgesIgnoringSafeArea(.all)
            
            // Display the image using Kingfisher
            KFImage(imageURL)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding()
                .background(Color.black)
            
            // Close button
            Button(action: {
                dismiss()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white)
                    .font(.title)
                    .padding()
            }
        }
    }
}

struct PostRowView: View {
    let post: SubredditPostData

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // -- Upvotes + Title + Body Text --
            HStack(alignment: .top, spacing: 12) {
                // Vote/Upvote column
                VStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .foregroundColor(.orange)
                    Text("\(post.ups)")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .frame(width: 40)

                // Title + Expandable selftext
                VStack(alignment: .leading, spacing: 6) {
                    Text(post.title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    // Show text if there's selftext, either expanded or shortened
                    if !post.selftext.isEmpty {
                        Text(isExpanded ? post.selftext : post.previewText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(isExpanded ? nil : 3)
                    }

                    // Comments count (no "Open" button, since gesture handles it)
                    HStack {
                        Image(systemName: "bubble.right")
                        Text("\(post.num_comments) comments")
                            .font(.caption)
                        Spacer()
                    }
                    .foregroundColor(.secondary)
                }
            }

            // -- The Post's Image (clickable for larger view) --
            if let imageUrl = post.bestImageURL {
                ClickableImage(url: imageUrl, maxHeight: 300)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal)
        .background(Color.customBackground)

        // Make the entire row respond to horizontal swipes
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    // (1) Right->left swipe => open URL
                    if value.translation.width < -30 {
                        if let fullURL = post.fullURL {
                            #if os(iOS)
                            UIApplication.shared.open(fullURL)
                            #elseif os(macOS)
                            NSWorkspace.shared.open(fullURL)
                            #endif
                        }
                    }
                    // (2) Left->right swipe => toggle expanded text
                    else if value.translation.width > 30 {
                        if !post.selftext.isEmpty {
                            isExpanded.toggle()
                        }
                    }
                }
        )
    }
}


// MARK: - ClickableImage
import SwiftUI
import Kingfisher

struct ClickableImage: View {
    let url: URL
    let maxHeight: CGFloat
    @State private var showImageViewer = false

    var body: some View {
        Button(action: {
            showImageViewer = true
        }) {
            KFImage(url)
                .resizable()
                .placeholder {
                    ProgressView()
                }
                .cancelOnDisappear(true)
                .scaledToFill()
                .frame(maxHeight: maxHeight)
                .clipped()
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showImageViewer) {
            ImageViewer(imageURL: url)
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
                    ProgressView().padding()
                } else if let err = error {
                    Text(err).foregroundColor(.red).padding()
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(allComments.prefix(visibleCount)) { comment in
                            CommentView(comment: comment)
                        }
                        if visibleCount < allComments.count {
                            Button("Load More Comments") {
                                visibleCount += 20
                            }
                            .foregroundColor(.blue)
                            .padding()
                        }
                    }
                    .padding()
                }
            }
            .onAppear {
                fetchComments()
            }

            // Copy + Summarize
            HStack {
                Button("Copy Comments") {
                    copyCommentsToClipboard()
                }
                .font(.caption)
                .foregroundColor(.blue)

                Spacer()

                Button {
                    summarizeComments()
                } label: {
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

            // Summaries
            if let summary = summary {
                ResizableTextBox(title: "Summary:", content: summary)
                    .padding(.horizontal)
            } else if let summaryError = summaryError {
                Text("Summary Error: \(summaryError)")
                    .foregroundColor(.red)
                    .padding()
            }

            // Q&A
            VStack(alignment: .leading) {
                Text("Ask a question about the comments:")
                    .font(.headline)
                    .padding(.horizontal)

                HStack {
                    TextField("Enter your question", text: $question)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.horizontal)
                        .disabled(isAnswering)
                        .submitLabel(.done)
                        .onSubmit {
                            UIApplication.shared.endEditing()
                            askQuestion()
                        }

                    Button("Ask") {
                        askQuestion()
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                    .disabled(isAnswering || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.bottom)

                if isAnswering {
                    ProgressView("Answering...")
                        .padding(.horizontal)
                } else if let answer = answer {
                    ResizableTextBox(title: "Answer:", content: answer, isAnswer: true)
                        .padding(.horizontal)
                } else if let err = answerError {
                    Text("Question Error: \(err)")
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }
            }
        }
    }

    private func fetchComments() {
        guard let url = URL(string: "https://www.reddit.com\(postPermalink).json")
        else {
            error = "Invalid URL"
            isLoading = false
            return
        }
        let request = URLRequest(url: url, timeoutInterval: 30)
        NetworkService.shared.urlSession.dataTask(with: request) { data, response, networkError in
            if let e = networkError {
                DispatchQueue.main.async {
                    self.error = e.localizedDescription
                    self.isLoading = false
                }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async {
                    self.error = "No data"
                    self.isLoading = false
                }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let parsedComments = try parseAndProcessComments(data)
                    DispatchQueue.main.async {
                        self.allComments = parsedComments
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.error = "Failed to parse comments: \(error.localizedDescription)"
                        self.isLoading = false
                    }
                }
            }
        }.resume()
    }

    private func parseAndProcessComments(_ data: Data) throws -> [CommentData] {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]],
              json.count > 1,
              let dataDict = json[1]["data"] as? [String: Any],
              let commentsArray = dataDict["children"] as? [[String: Any]]
        else {
            return []
        }
        return parseAllComments(commentsArray)
    }

    private func parseAllComments(_ arr: [[String: Any]]) -> [CommentData] {
        arr.compactMap { commentDict in
            guard let data = commentDict["data"] as? [String: Any],
                  let id = data["id"] as? String,
                  let body = data["body"] as? String
            else { return nil }

            var replies: [CommentData] = []
            if let repliesDict = data["replies"] as? [String: Any],
               let repliesData = repliesDict["data"] as? [String: Any],
               let children = repliesData["children"] as? [[String: Any]] {
                replies = parseAllComments(children)
            }
            let imageURLs = parseImageURLs(from: body)
            let links = parseLinks(from: body)
            let processedText = processText(body, removingImageURLs: imageURLs)
            return CommentData(
                id: id,
                rawText: body,
                replies: replies,
                processedText: processedText,
                imageURLs: imageURLs,
                links: links
            )
        }
    }

    private func flattenComments(comments: [CommentData], depth: Int = 0) -> [String] {
        var allRaw = [String]()
        let indent = String(repeating: "    ", count: depth)
        for c in comments {
            let item = "\(indent)- \(c.rawText)"
            allRaw.append(item)
            allRaw.append(contentsOf: flattenComments(comments: c.replies, depth: depth+1))
        }
        return allRaw
    }

    private func copyCommentsToClipboard() {
        let prependText = """
        You are the best content writer in the world! These are a Reddit post's comments.
                Summarise the key themes and main points. Identify the top points or themes discussed in the comments, with examples for each. Include a brief overview of any major differing viewpoints if present.
        """
        let allRaw = flattenComments(comments: allComments).joined(separator: "\n\n")
        let finalContent = prependText + "\n\n" + allRaw

        #if os(iOS)
        UIPasteboard.general.string = finalContent
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(finalContent, forType: .string)
        #endif
    }

    private func summarizeComments() {
        isSummarizing = true
        summaryError = nil

        let allRaw = flattenComments(comments: allComments).joined(separator: "\n\n")
        let prompt = """
        Summarize the following Reddit comments, summarizing key themes and main points, with examples. Provide a final summary of overall comments:
        \(allRaw)
        """
        Task {
            do {
                let result = try await GeminiService.shared.summarize(text: prompt)
                DispatchQueue.main.async {
                    self.summary = result
                    self.isSummarizing = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.summaryError = "\(error)"
                    self.isSummarizing = false
                }
            }
        }
    }

    private func askQuestion() {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isAnswering = true
        answer = nil
        answerError = nil

        let allRaw = flattenComments(comments: allComments).joined(separator: "\n\n")
        let prompt = """
        Let's consider these Reddit comments:

        \(allRaw)

        Now, answer the question: \(question)
        """
        Task {
            do {
                let result = try await GeminiService.shared.summarize(text: prompt)
                DispatchQueue.main.async {
                    self.answer = result
                    self.isAnswering = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.answerError = "\(error)"
                    self.isAnswering = false
                }
            }
        }
    }
}

// MARK: - CommentView
struct CommentView: View {
    let comment: CommentData
    @State private var showAllImages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                // The blue line at left
                Rectangle()
                    .fill(Color.blue.opacity(0.3))
                    .frame(width: 2)
                    .padding(.leading, 8)

                VStack(alignment: .leading, spacing: 4) {
                    // -- Comment Text with older "frosted" styling --
                    Text(comment.processedText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background {
                            ZStack {
                                // Slightly transparent background
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.ultraThinMaterial)
                                // Subtle gradient blur on top
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
                                // Stroke around the edges
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                            }
                        }
                        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 2)

                    // -- Any images attached to this comment --
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

                    // -- Links in the comment --
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

                    // -- Recursively show replies --
                    ForEach(comment.replies) { reply in
                        CommentView(comment: reply)
                    }
                }
            }
        }
        .padding(.leading, 8)
    }
}


// MARK: - Helper Parsing Functions
func parseImageURLs(from text: String) -> [URL] {
    let pattern = "(?i)(?:!\\[[^\\]]*\\]\\()?(https?://[^\\s\\)]+?\\.(?:jpg|jpeg|gif|png|webp|bmp|tiff)(?:\\?[^\\s\\)]+)?)\\)?"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, options: [], range: range)
    return matches.compactMap { match in
        guard let range = Range(match.range(at: 1), in: text) else { return nil }
        let urlString = String(text[range])
            .replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: urlString)
    }
}

func parseLinks(from text: String) -> [(String, URL)] {
    let pattern = "\\[([^\\]]+)\\]\\(([^\\)]+)\\)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, options: [], range: range)
    let imageExtensions = ["jpg", "jpeg", "gif", "png", "webp", "bmp", "tiff"]
    var results = [(String, URL)]()
    for match in matches {
        guard let textRange = Range(match.range(at: 1), in: text),
              let urlRange = Range(match.range(at: 2), in: text) else { continue }
        let linkText = String(text[textRange])
        let urlString = String(text[urlRange])
        if let url = URL(string: urlString),
           !imageExtensions.contains(url.pathExtension.lowercased()) {
            results.append((linkText, url))
        }
    }
    return results
}

func processText(_ text: String, removingImageURLs imageURLs: [URL]) -> String {
    var newText = text
    for url in imageURLs {
        let urlString = url.absoluteString
        let encoded = urlString.replacingOccurrences(of: "&", with: "&amp;")
        // Remove Markdown image
        let pattern = "!\\[[^\\]]*\\]\\(\(NSRegularExpression.escapedPattern(for: urlString))\\)"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(newText.startIndex..., in: newText)
            newText = regex.stringByReplacingMatches(in: newText, range: range, withTemplate: "")
        }
        // Remove standalone
        newText = newText.replacingOccurrences(of: urlString, with: "")
        newText = newText.replacingOccurrences(of: encoded, with: "")
    }
    // fix malformed markdown
    let malformedPattern = "\\]\\s*\\("
    if let reg = try? NSRegularExpression(pattern: malformedPattern) {
        let range = NSRange(newText.startIndex..., in: newText)
        newText = reg.stringByReplacingMatches(in: newText, range: range, withTemplate: "](")
    }
    return newText.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - ResizableTextBox
struct ResizableTextBox: View {
    let title: String
    let content: String
    let isAnswer: Bool
    @State private var boxHeight: CGFloat

    init(title: String, content: String, isAnswer: Bool = false) {
        self.title = title
        self.content = content
        self.isAnswer = isAnswer
        // Make answers a bit taller by default
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
                    // Based on older code layering
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

            // Draggable handle to resize
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
                DragGesture()
                    .onChanged { gesture in
                        // Cap the height to avoid going too large or too small
                        let maxHeight = isAnswer ? 1000.0 : 800.0
                        boxHeight = max(100, min(maxHeight, boxHeight + gesture.translation.height))
                    }
            )
        }
    }
}

// MARK: - OverallExtractionView
@MainActor
struct OverallExtractionView: View {
    @Environment(\.dismiss) private var dismiss

    // Local states
    @State private var isLoading = false
    @State private var error: String?
    @State private var progress: String?
    @State private var allComments = [CommentData]()
    @State private var summary: String?
    @State private var summaryError: String?
    @State private var question: String = ""
    @State private var answer: String?
    @State private var answerError: String?
    @State private var isSummarizing = false
    @State private var isAnswering = false

    let subreddit: String
    let postType: PostType
    let accessToken: String
    let customLimit: Int

    private let userAgent = "subreddit_summarizer"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
                .padding([.top, .trailing], 8)

                if let error = error {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                        .padding()
                }
                if let progress = progress {
                    Text(progress)
                        .foregroundColor(.blue)
                        .padding()
                }
                if isLoading {
                    ProgressView("Loading Comments...")
                        .padding()
                } else {
                    Button("Summarize All Comments") {
                        summarizeAllComments()
                    }
                    .font(.caption)
                    .padding(.horizontal)

                    if isSummarizing {
                        HStack {
                            ProgressView()
                            Text("Summarizing...")
                                .foregroundColor(.gray)
                        }
                        .padding(.horizontal)
                    }

                    if let summary = summary {
                        Text(summary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .shadow(radius: 1)
                            .padding()
                    } else if let summaryError = summaryError {
                        Text("Summary Error: \(summaryError)")
                            .foregroundColor(.red)
                            .padding()
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ask a question about all these comments:")
                            .font(.headline)

                        HStack {
                            TextField("Enter your question here", text: $question)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .submitLabel(.done)
                                .onSubmit {
                                    UIApplication.shared.endEditing()
                                    askQuestion()
                                }

                            Button("Ask") {
                                askQuestion()
                            }
                            .font(.caption)
                            .disabled(isAnswering || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if isAnswering {
                            HStack {
                                ProgressView()
                                Text("Generating Answer...")
                                    .foregroundColor(.gray)
                            }
                        }

                        if let answer = answer {
                            Text(answer)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .shadow(radius: 1)
                                .padding(.vertical, 4)
                        } else if let answerError = answerError {
                            Text("Question Error: \(answerError)")
                                .foregroundColor(.red)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            fetchAllPostsAndComments()
        }
        .frame(minWidth: 350, minHeight: 600)
        .background(Color.customBackground)
    }

    private func fetchAllPostsAndComments() {
        isLoading = true
        error = nil
        progress = "Fetching up to \(customLimit) \(postType.displayName) posts for r/\(subreddit)..."

        Task {
            do {
                let allPosts = try await fetchUpToCustomLimitPosts(
                    subreddit: subreddit,
                    postType: postType,
                    limit: customLimit
                )
                var combined = [CommentData]()
                for (index, post) in allPosts.enumerated() {
                    progress = "Fetching comments for post \(index+1) of \(allPosts.count)..."
                    let c = try await fetchComments(for: post)
                    combined.append(contentsOf: c)
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                allComments = combined
                progress = "Fetched \(combined.count) total comments!"
                isLoading = false
            } catch {
                self.error = "\(error)"
                isLoading = false
            }
        }
    }

    private func fetchUpToCustomLimitPosts(subreddit: String, postType: PostType, limit: Int) async throws -> [SubredditPostData] {
        var fetched = [SubredditPostData]()
        var after: String? = nil

        while fetched.count < limit {
            var components = URLComponents(string: "https://oauth.reddit.com/r/\(subreddit)/\(postType.rawValue)")!
            components.queryItems = [ URLQueryItem(name: "limit", value: "25") ]
            if let a = after {
                components.queryItems?.append(URLQueryItem(name: "after", value: a))
            }
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.addValue("bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.addValue(userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            }
            let subResp = try JSONDecoder().decode(SubredditResponse.self, from: data)
            var newPosts = subResp.data.children.map { $0.data }
            newPosts = newPosts.filter { $0.stickied != true }
            fetched.append(contentsOf: newPosts)

            if let next = subResp.data.after, !next.isEmpty, newPosts.count > 0 {
                after = next
            } else {
                break
            }
        }

        if fetched.count > limit {
            fetched = Array(fetched.prefix(limit))
        }
        return fetched
    }

    private func fetchComments(for post: SubredditPostData) async throws -> [CommentData] {
        guard let url = URL(string: "https://www.reddit.com\(post.permalink).json") else {
            return []
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        let comments = try parseAndProcessComments(data)
        return comments
    }

    private func parseAndProcessComments(_ data: Data) throws -> [CommentData] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              json.count > 1,
              let dataDict = json[1]["data"] as? [String: Any],
              let arr = dataDict["children"] as? [[String: Any]]
        else { return [] }
        return parseAllComments(arr)
    }

    private func parseAllComments(_ arr: [[String: Any]]) -> [CommentData] {
        var results = [CommentData]()
        for dict in arr {
            guard let kind = dict["kind"] as? String, kind == "t1",
                  let data = dict["data"] as? [String: Any],
                  let id = data["id"] as? String,
                  let body = data["body"] as? String
            else { continue }

            var replies = [CommentData]()
            if let repliesDict = data["replies"] as? [String: Any],
               let rd = repliesDict["data"] as? [String: Any],
               let children = rd["children"] as? [[String: Any]] {
                replies = parseAllComments(children)
            }
            let imageURLs = parseImageURLs(from: body)
            let links = parseLinks(from: body)
            let processed = processText(body, removingImageURLs: imageURLs)
            let newC = CommentData(
                id: id,
                rawText: body,
                replies: replies,
                processedText: processed,
                imageURLs: imageURLs,
                links: links
            )
            results.append(newC)
        }
        return results
    }

    private func flattenComments(comments: [CommentData], depth: Int = 0) -> [String] {
        var all = [String]()
        let indent = String(repeating: "    ", count: depth)
        for c in comments {
            let line = "\(indent)- \(c.rawText)"
            all.append(line)
            all.append(contentsOf: flattenComments(comments: c.replies, depth: depth+1))
        }
        return all
    }

    private func summarizeAllComments() {
        isSummarizing = true
        summaryError = nil
        let raw = flattenComments(comments: allComments).joined(separator: "\n\n")
        let prompt = """
           Provide a detailed summary of the following Reddit comments from multiple posts within this subreddit. Identify and explain the primary topics and discussions being addressed. Highlight key themes, recurring viewpoints, and any significant patterns or trends present in the conversations. Ensure the summary is clear, well-structured:

        \(raw)
        """
        Task {
            do {
                let s = try await GeminiService.shared.summarize(text: prompt)
                summary = s
                isSummarizing = false
            } catch {
                summaryError = "\(error)"
                isSummarizing = false
            }
        }
    }

    private func askQuestion() {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isAnswering = true
        answer = nil
        answerError = nil

        let raw = flattenComments(comments: allComments).joined(separator: "\n\n")
        let prompt = """
        We have these Reddit comments from multiple posts:

        \(raw)

        Based on the above, answer: \(question)
        """
        Task {
            do {
                let ans = try await GeminiService.shared.summarize(text: prompt)
                answer = ans
                isAnswering = false
            } catch {
                answerError = "\(error)"
                isAnswering = false
            }
        }
    }
}

// MARK: - ContentView
import SwiftUI

struct ContentView: View {
    // MARK: - State & ViewModel
    @State var subreddit: String = "SwiftUI"
    @State var selectedPost: SubredditPostData?
    @ObservedObject var viewModel = RedditSubredditViewModel()

    // Tracks whether to show the OverallExtractionView as a sheet
    @SceneStorage("showOverallOverlay") var showOverlay = false

    // Detect size class for iPhone vs. iPad
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    var body: some View {
        Group {
            // iPad / macOS
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    // Left side: a sidebar with posts
                    sidebarView
                } detail: {
                    // Right side: Comments
                    if let selected = selectedPost {
                        RedditCommentsView(postPermalink: selected.permalink)
                            .id(selected.id)
                    } else {
                        Text("Select a post to view comments")
                            .foregroundColor(.secondary)
                    }
                }
            }
            // iPhone
            else {
                NavigationView {
                    VStack {
                        headerView

                        if viewModel.isLoading {
                            ProgressView()
                                .padding()
                        } else if let error = viewModel.error {
                            Text(error)
                                .foregroundColor(.red)
                                .padding()
                        } else {
                            List(viewModel.posts) { post in
                                // Wrap PostRowView in a NavigationLink
                                NavigationLink(destination: RedditCommentsView(postPermalink: post.permalink)) {
                                    PostRowView(post: post)
                                }
                                .buttonStyle(.plain)

                                // SWIPE ACTIONS (right->left) to open in Safari:
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        if let fullURL = post.fullURL {
                                            #if os(iOS)
                                            UIApplication.shared.open(fullURL)
                                            #elseif os(macOS)
                                            NSWorkspace.shared.open(fullURL)
                                            #endif
                                        }
                                    } label: {
                                        Label("Open", systemImage: "safari")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .listStyle(.plain)
                        }
                    }
                    .navigationTitle("r/\(subreddit)")
                    .navigationBarTitleDisplayMode(.inline)
                    // OverallExtractionView sheet remains the same:
                    .sheet(isPresented: $showOverlay) {
                        if let token = viewModel.accessToken {
                            OverallExtractionView(
                                subreddit: subreddit,
                                postType: viewModel.selectedPostType,
                                accessToken: token,
                                customLimit: Int(viewModel.postLimit) ?? 50
                            )
                        } else {
                            Text("No valid access token available.")
                                .frame(width: 300, height: 200)
                                .background(Color.customBackground)
                                .cornerRadius(10)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sidebar for iPad
    var sidebarView: some View {
        VStack {
            headerView

            ScrollView {
                if viewModel.isLoading {
                    ProgressView()
                        .padding()
                } else if let error = viewModel.error {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                } else {
                    // Show the post list in a LazyVStack
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.posts) { post in
                            // Tapping a row sets selectedPost for iPad
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
    }

    // MARK: - Header
    var headerView: some View {
        VStack(spacing: 8) {
            // Subreddit text field
            HStack {
                TextField("Enter subreddit", text: $subreddit)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.webSearch)
                    .frame(maxWidth: 160)
            }

            // Post limit + sort type
            HStack {
                Text("Show")

                TextField("Number of posts", text: $viewModel.postLimit)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numberPad)
                    .frame(width: 60)
                    // “Done” button above the number pad
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") {
                                UIApplication.shared.endEditing()
                            }
                        }
                    }

                Text("posts")

                Picker("Sort by", selection: $viewModel.selectedPostType) {
                    ForEach(PostType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }

            // Load + Overall buttons
            HStack {
                Button("Load") {
                    viewModel.authenticate {
                        viewModel.fetchSubredditPosts(subreddit: subreddit)
                    }
                }
                .disabled(viewModel.isLoading)

                Button("Overall") {
                    if viewModel.accessToken == nil {
                        // If no token, authenticate first
                        viewModel.authenticate {
                            if viewModel.accessToken != nil {
                                showOverlay = true
                            }
                        }
                    } else {
                        showOverlay = true
                    }
                }
                .disabled(viewModel.isLoading)
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

// MARK: - App Entry Point
@main
struct RedditApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}


