import Foundation

/// Looks up a bird photo on Wikipedia by scientific name and caches the result.
actor BirdImageService {
    static let shared = BirdImageService()

    private var cache: [String: URL?] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private struct Summary: Decodable {
        struct Image: Decodable { let source: URL }
        let thumbnail: Image?
    }

    /// Thumbnail URL for the species, or nil if Wikipedia has none.
    func thumbnail(forScientificName name: String) async -> URL? {
        if let cached = cache[name] { return cached }
        let title = name.replacingOccurrences(of: " ", with: "_")
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue("MMT bird app (github.com/Be-To-mu/MMT)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await session.data(for: request)
            let result = try JSONDecoder().decode(Summary.self, from: data).thumbnail?.source
            cache[name] = result
            return result
        } catch {
            return nil  // not cached, so it's retried next time
        }
    }
}
