import SwiftUI
import AppKit
import AVFAudio
import Speech
import UniformTypeIdentifiers
import NaturalLanguage

/// The main view for selecting audio, transcribing it, and displaying/editing the transcript.
struct ContentView: View {
    @StateObject private var player = TranscriptPlayer()
    @State private var isEditing = false
    @State private var isTranscribing = false
    @State private var transcriptionProgress: Double = 0.0
    @State private var audioDuration: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Top controls
            HStack {
                Button("Select Audio") { selectAudio() }
                    .disabled(isTranscribing)

                if !isEditing && !player.segments.isEmpty {
                    Button(player.isPlaying ? "Pause" : "Play") {
                        player.togglePlayPause()
                    }
                }

                Toggle("Edit", isOn: $isEditing)
                    .toggleStyle(.checkbox)
                    .disabled(player.segments.isEmpty)

                Button("Copy") {
                    let text = buildText(from: player.segments)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(player.segments.isEmpty)

                Button("Export") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [UTType.plainText]
                    panel.nameFieldStringValue = "Transcript.txt"
                    if panel.runModal() == .OK, let url = panel.url {
                        let text = buildText(from: player.segments)
                        do {
                            try text.write(to: url, atomically: true, encoding: .utf8)
                        } catch {
                            // If save panel or write fails, show an alert rather than crashing
                            let alert = NSAlert(error: error)
                            alert.runModal()
                        }
                    }
                }
                .disabled(player.segments.isEmpty)

                Spacer()
                if isTranscribing {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 150)
                }
            }

            // Transcript display / editor
            Group {
                if isEditing {
                    // In-place per-word editor
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach($player.segments) { $seg in
                                HStack {
                                    Text(String(format: "%.2fs", seg.start))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("", text: $seg.text)
                                        .textFieldStyle(.plain)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .border(Color.secondary, width: 1)
                } else {
                    // Playback-mode: dynamic wrap & click-to-seek
                    GeometryReader { geo in
                        ScrollView {
                            // Estimate chars per line (~7pt per char)
                            let maxChars = max(10, Int(geo.size.width / 7))
                            let lines = makeLines(from: player.segments, maxChars: maxChars)

                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(lines.indices, id: \.self) { row in
                                    HStack(spacing: 0) {
                                        ForEach(lines[row], id: \.id) { seg in
                                            let active = player.playbackTime >= seg.start &&
                                                         player.playbackTime < seg.start + seg.duration
                                            Text(display(for: seg, in: player.segments) + " ")
                                                .foregroundColor(active ? .accentColor : .primary)
                                                .bold(active)
                                                .onTapGesture { player.seek(to: seg.start) }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(4)
                            .frame(width: geo.size.width, alignment: .topLeading)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .border(Color.secondary, width: 1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300)

            Spacer()
        }
        .padding()
        .frame(minWidth: 600, minHeight: 500)
    }

    // MARK: - File picker & transcription

    private func selectAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.audio]
        if panel.runModal() == .OK, let url = panel.url {
            _ = url.startAccessingSecurityScopedResource()
            // Get total duration for progress calculation
            let asset = AVURLAsset(url: url)
            audioDuration = CMTimeGetSeconds(asset.duration)
            transcribe(url: url)
        }
    }

    private func transcribe(url: URL) {
        isTranscribing = true
        transcriptionProgress = 0.0
        player.pause()

        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                isTranscribing = false
                return
            }
            Task.detached {
                do {
                    let (_, segments) = try await performTranscription(url: url)
                    await MainActor.run {
                        try? player.configure(audioURL: url, segments: segments)
                        isTranscribing = false
                    }
                } catch {
                    await MainActor.run {
                        isTranscribing = false
                    }
                }
            }
        }
    }

    private func performTranscription(url: URL) async throws -> (String, [WordSegment]) {
        try await withCheckedThrowingContinuation { cont in
            guard let recognizer = SFSpeechRecognizer(locale: Locale.current) else {
                cont.resume(throwing: NSError(domain: "Recognizer", code: -1))
                return
            }
            recognizer.supportsOnDeviceRecognition = true
            let req = SFSpeechURLRecognitionRequest(url: url)
            req.taskHint = .dictation
            // Enable interim results so we can update progress as we go
            req.shouldReportPartialResults = true

            recognizer.recognitionTask(with: req) { res, err in
                if let err {
                    cont.resume(throwing: err)
                    return
                }
                guard let res else { return }
                // Update progress based on last segment timestamp
                if let last = res.bestTranscription.segments.last {
                    let progress = min(last.timestamp / audioDuration, 1.0)
                    Task { @MainActor in
                        transcriptionProgress = progress
                    }
                }
                if res.isFinal {
                    let segments = res.bestTranscription.segments.map {
                        WordSegment(text: $0.substring,
                                    start: $0.timestamp,
                                    duration: $0.duration)
                    }
                    let full = buildText(from: segments)
                    cont.resume(returning: (full, segments))
                }
            }
        }
    }
}

// MARK: - Transcript text builders

/// Builds a simple punctuation-aware, capitalized string of the transcript.
private func buildText(from segments: [WordSegment], gap: TimeInterval = 0.6) -> String {
    guard segments.count > 1 else {
        return segments.first?.text.capitalized.appending(".") ?? ""
    }
    let questionWords: Set<String> = ["who","what","when","where","why","how",
                                      "is","are","do","does","did","can","could","would","will"]

    var out = ""
    var prevEnd: TimeInterval = 0
    for (i, seg) in segments.enumerated() {
        let startSentence = i == 0 || (seg.start - prevEnd) >= gap
        var w = seg.text
        if startSentence, let first = w.first {
            w.replaceSubrange(w.startIndex...w.startIndex,
                              with: String(first).uppercased())
        }
        out += w

        let last = i == segments.count - 1
        if last {
            if !".!?".contains(w.last ?? " ") { out += "." }
            break
        }
        let next = segments[i+1]
        let silence = next.start - (seg.start + seg.duration)
        prevEnd = seg.start + seg.duration

        if silence >= gap {
            if !".!?".contains(w.last ?? " ") {
                out += questionWords.contains(w.lowercased()) ? "?" : "."
            }
            out += " "
        } else {
            out += " "
        }
    }
    return out
}

/// Display rules for an individual segment: capitalization, punctuation.
private func display(for seg: WordSegment, in segments: [WordSegment], gap: TimeInterval = 0.6) -> String {
    var w = seg.text
    // Determine sentence start via gap
    if let idx = segments.firstIndex(where: { $0.id == seg.id }) {
        let isStart = idx == 0 ||
            (seg.start - (segments[idx-1].start + segments[idx-1].duration)) >= gap
        if isStart, let first = w.first {
            w.replaceSubrange(w.startIndex...w.startIndex,
                              with: String(first).uppercased())
        }
        // Respect existing punctuation
        if w.hasSuffix(".") || w.hasSuffix("?") || w.hasSuffix("!") {
            return w
        }
        // Add period on long gap or at end
        if idx == segments.count - 1 ||
           (segments[idx+1].start - (seg.start + seg.duration)) >= gap {
            w += "."
        }
    }
    return w
}

/// Wraps segments into lines of up to `maxChars` words.
private func makeLines(from segments: [WordSegment], maxChars: Int = 90) -> [[WordSegment]] {
    var lines: [[WordSegment]] = [[]]
    var len = 0
    for seg in segments {
        let wLen = seg.text.count + 1
        if len + wLen > maxChars {
            lines.append([seg])
            len = wLen
        } else {
            lines[lines.count-1].append(seg)
            len += wLen
        }
    }
    return lines
}

/// Builds an AttributedString with per-word highlighting.
private func highlightedText(from segments: [WordSegment],
                             playbackTime: TimeInterval) -> AttributedString {
    var result = AttributedString()
    for seg in segments {
        let word = display(for: seg, in: segments)
        var attr = AttributedString(word + " ")
        if playbackTime >= seg.start && playbackTime < seg.start + seg.duration {
            attr.foregroundColor = .accentColor
        }
        result += attr
    }
    return result
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
