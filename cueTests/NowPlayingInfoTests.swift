import MediaPlayer
import Testing

@testable import cue

struct NowPlayingInfoTests {
    @Test func knownDurationPublishesTheExactMetadataWithoutArtwork() {
        let info = nowPlayingInfo(
            title: "Episode",
            podcastTitle: "Podcast",
            duration: 180,
            elapsed: 45,
            rate: 1.5
        )
        #expect(info.count == 5)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Episode")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Podcast")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval == 180)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 45)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
        #expect(info[MPMediaItemPropertyArtwork] == nil)
    }

    @Test func theGivenRateIsPublishedVerbatim() {
        let paused = nowPlayingInfo(
            title: "Episode", podcastTitle: "Podcast", duration: 180, elapsed: 45, rate: 0
        )
        let playing = nowPlayingInfo(
            title: "Episode", podcastTitle: "Podcast", duration: 180, elapsed: 45, rate: 1.75
        )

        #expect(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(playing[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.75)
    }

    @Test func unknownDurationIsOmitted() {
        let info = nowPlayingInfo(
            title: "Episode", podcastTitle: "Podcast", duration: nil, elapsed: 0, rate: 0
        )

        #expect(info[MPMediaItemPropertyPlaybackDuration] == nil)
        #expect(info.count == 4)
    }
}
