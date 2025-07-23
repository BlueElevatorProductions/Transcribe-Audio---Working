import Foundation
import AVFAudio

@MainActor final class TranscriptPlayer: ObservableObject {
    @Published var segments: [WordSegment] = []
    @Published var playbackTime: TimeInterval = 0

    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?

    func configure(audioURL: URL, segments: [WordSegment]) {
        self.segments = segments
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
            audioPlayer?.prepareToPlay()
        } catch {
            print("Failed to initialize audio player: \(error)")
        }
    }

    func play() {
        audioPlayer?.play()
        startTimer()
    }

    func pause() {
        audioPlayer?.pause()
        timer?.invalidate()
        timer = nil
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        playbackTime = time
    }

    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.playbackTime = self.audioPlayer?.currentTime ?? 0
            if self.audioPlayer?.isPlaying == false {
                self.timer?.invalidate()
                self.timer = nil
            }
        }
    }
}
