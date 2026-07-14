import Foundation
import Security

// MARK: - Imgur Service
class ImgurService {
    static let shared = ImgurService()
    private init() {}
    
    // Imgur anonymous upload endpoint
    private let uploadURL = "https://api.imgur.com/3/image"
    
    // Keychain keys for Imgur credentials
    private let imgurClientIdKey = "imgur_client_id"
    
    // Simplified response structure - only what we need
    struct ImgurUploadResponse: Codable {
        let data: ImgurImageData?
        let success: Bool
        let status: Int
    }
    
    struct ImgurImageData: Codable {
        let link: String
        let id: String?
        let deletehash: String?
    }
    
    // MARK: - Keychain Methods
    func setImgurClientId(_ clientId: String) {
        let data = clientId.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: imgurClientIdKey,
            kSecValueData as String: data
        ]
        
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    func getStoredClientId() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: imgurClientIdKey,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let clientId = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return clientId
    }
    
    func hasStoredCredentials() -> Bool {
        return getStoredClientId() != nil
    }
    
    func clearImgurCredentials() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: imgurClientIdKey
        ]
        SecItemDelete(query as CFDictionary)
    }
    
    func uploadImage(_ imageData: Data) async throws -> String {
        // Check if client ID is configured
        guard let clientId = getStoredClientId(), !clientId.isEmpty else {
            throw NSError(domain: "ImgurService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Imgur client ID not configured. Please add your Imgur API credentials in Settings."])
        }
        
        var request = URLRequest(url: URL(string: uploadURL)!)
        request.httpMethod = "POST"
        request.setValue("Client-ID \(clientId)", forHTTPHeaderField: "Authorization")
        
        // Convert image data to base64
        let base64Image = imageData.base64EncodedString()
        
        // Create form data
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add image data
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"\r\n\r\n".data(using: .utf8)!)
        body.append(base64Image.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add type parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"type\"\r\n\r\n".data(using: .utf8)!)
        body.append("base64".data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        print("📤 Uploading image to Imgur...")
        print("Image size: \(imageData.count) bytes")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        print("Imgur response status: \(httpResponse.statusCode)")
        
        // Debug: Print raw response
        if let responseString = String(data: data, encoding: .utf8) {
            print("Imgur raw response: \(responseString)")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorString = String(data: data, encoding: .utf8) {
                print("Imgur error response: \(errorString)")
            }
            throw URLError(.badServerResponse)
        }
        
        // Parse response
        do {
            let decoder = JSONDecoder()
            let imgurResponse = try decoder.decode(ImgurUploadResponse.self, from: data)
        
            guard imgurResponse.success, let imageData = imgurResponse.data else {
                print("Imgur response indicates failure or missing data")
                throw URLError(.cannotParseResponse)
            }
            
            print("✅ Image uploaded to Imgur successfully!")
            print("Imgur URL: \(imageData.link)")
            
            return imageData.link
        } catch {
            print("Failed to decode Imgur response: \(error)")
            
            // Try a simpler parsing approach
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let data = json["data"] as? [String: Any],
               let link = data["link"] as? String {
                print("✅ Image uploaded to Imgur successfully (simple parse)!")
                print("Imgur URL: \(link)")
                return link
            }
            
            throw error
        }
    }
    
    // Upload multiple images and return array of URLs
    func uploadImages(_ imageDatas: [Data]) async throws -> [String] {
        var urls: [String] = []
        
        for imageData in imageDatas {
            let url = try await uploadImage(imageData)
            urls.append(url)
        }
        
        return urls
    }
}