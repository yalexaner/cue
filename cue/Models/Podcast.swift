import Foundation
import SwiftData

@Model
final class Podcast {
    #Unique<Podcast>([\.feedURL])

    var feedURL: String  // stored verbatim, may contain auth token
    var title: String
    var author: String?
    var summary: String?
    var artworkURL: String?
    var addedAt: Date
    var lastRefreshedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode] = []

    init(feedURL: String, title: String) {
        self.feedURL = feedURL
        self.title = title
        self.addedAt = .now
    }
}
