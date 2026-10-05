import SwiftUI

/// Full controls for the episode held by the process-wide playback engine.
///
/// Dismissing this sheet leaves the engine and its audio untouched. Session
/// history, a sleep timer and artwork arrive in their own roadmap steps.
struct PlayerView: View {
    @Environment(PlaybackEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var isSeeking = false
    @State private var pendingPosition: TimeInterval = 0
    @State private var playbackErrorText: String?

    private var displayedPosition: TimeInterval {
        isSeeking ? pendingPosition : engine.elapsed
    }

    private var sliderUpperBound: TimeInterval {
        playerSliderUpperBound(duration: engine.duration)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Text(engine.episodeTitle ?? "Nothing Playing")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(engine.podcastTitle ?? "Unknown Podcast")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { displayedPosition },
                            set: { pendingPosition = $0 }
                        ),
                        in: 0...sliderUpperBound,
                        onEditingChanged: updateSeeking
                    )
                    .disabled(!isPlaybackDurationUsable(engine.duration))
                    HStack {
                        Text(playerTimeText(displayedPosition))
                        Spacer()
                        Text(remainingTimeText)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 36) {
                    Button {
                        engine.skip(by: -30)
                    } label: {
                        Image(systemName: "gobackward.30")
                    }
                    .accessibilityLabel("Skip Back 30 Seconds")

                    Button(action: togglePlayback) {
                        Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                    .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")

                    Button {
                        engine.skip(by: 30)
                    } label: {
                        Image(systemName: "goforward.30")
                    }
                    .accessibilityLabel("Skip Forward 30 Seconds")
                }
                .font(.title)

                Picker(
                    "Playback Speed",
                    selection: Binding(get: { engine.rate }, set: { engine.setRate($0) })
                ) {
                    ForEach(playbackRates, id: \.self) { rate in
                        Text(playbackRateText(rate)).tag(rate)
                    }
                }
                .pickerStyle(.segmented)

                Spacer()
            }
            .padding()
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: playbackErrorMessage(for: engine.playbackError), initial: true) { _, message in
            if let message {
                playbackErrorText = message
            }
        }
        .errorAlert("Playback Failed", $playbackErrorText)
    }

    private var remainingTimeText: String {
        playerRemainingTimeText(elapsed: displayedPosition, duration: engine.duration)
    }

    private func updateSeeking(_ editing: Bool) {
        if editing {
            pendingPosition = engine.elapsed
            isSeeking = true
        } else {
            engine.seek(to: pendingPosition)
            isSeeking = false
        }
    }

    private func togglePlayback() {
        do {
            try engine.togglePlayPause()
        } catch {
            playbackErrorText = playbackErrorMessage(for: error)
        }
    }
}
