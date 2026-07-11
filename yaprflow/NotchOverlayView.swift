import AppKit
import SwiftUI

/// The floating pill that appears while yaprflow is recording / processing.
///
/// Lives at the **bottom-center** of the screen (previously top-attached to
/// the display notch — hence the filename). The pill shows three animated
/// audio-level bars on the left and the live transcript / status text on the
/// right, on a dark `hudWindow` blur. Bouncing-bar visualization matches the
/// Wispr Flow shape: a clear visual signal that the mic is actually live and
/// the user is being heard.
struct NotchOverlayView: View {
    @ObservedObject var state: AppState

    private static let transcriptFont = Font.system(size: 14, weight: .medium)
    private static let cornerRadius: CGFloat = 18
    private static let maxCharsPerLine = 56

    var body: some View {
        pill
            // Window is a fixed-size transparent canvas (we deliberately don't
            // let NSHostingController auto-shrink to the SwiftUI intrinsic, or
            // an idle/empty body would collapse the window to 0×0). Filling
            // the container and centering the pill puts it in the middle of
            // the canvas regardless of how big the inner content is.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pill: some View {
        HStack(alignment: .center, spacing: 10) {
            leadingIndicator

            if !displayText.isEmpty {
                Text(displayText)
                    .font(Self.transcriptFont)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch state.status {
        case .listening:
            WaveformView(level: state.inputLevel)
        case .preparing, .finishing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .correcting, .summarizing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .copied, .inserted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16, weight: .semibold))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 16, weight: .semibold))
        case .idle:
            // Idle state shouldn't normally render — the window is hidden
            // outside of an active session — but show static bars as a
            // fallback rather than collapsing the layout to zero width.
            LevelBarsView(level: 0, active: false)
        }
    }

    private var displayText: String {
        switch state.status {
        case .idle:                       return ""
        case .preparing(let message):     return message
        case .listening:
            // No placeholder while waiting for speech — the live waveform IS
            // the "listening" signal, and the bare pill reads cleaner.
            return state.liveTranscript.isEmpty ? "" : Self.wrappedTail(of: state.liveTranscript)
        case .finishing:
            return state.liveTranscript.isEmpty ? "Processing…" : Self.wrappedTail(of: state.liveTranscript)
        case .correcting(let message):    return message
        case .summarizing:                return "Summarizing…"
        case .copied:                     return "Copied"
        case .inserted:                   return "Inserted"
        case .error(let message):         return message
        }
    }

    private static func wrappedTail(of text: String) -> String {
        wrapLines(text, maxCharsPerLine: maxCharsPerLine)
            .suffix(2)
            .joined(separator: "\n")
    }

    private static func wrapLines(_ text: String, maxCharsPerLine: Int) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate: String = current.isEmpty ? String(word) : current + " " + word
            if candidate.count <= maxCharsPerLine {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                current = word.count > maxCharsPerLine ? String(word.prefix(maxCharsPerLine)) : String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}

/// Wispr-style scrolling waveform: a rolling history of the live input level
/// rendered as vertically-centered capsules, newest sample on the right,
/// scrolling left as new audio arrives. Because each bar keeps its value as
/// it drifts left (instead of every bar re-animating to the newest level),
/// the motion reads as a waveform of what you actually said rather than a
/// choppy synchronized pump.
private struct WaveformView: View {
    let level: Float

    // 14 bars ≈ 75 pt — compact enough to sit alone in the pill without
    // reading as a long strip, still enough history to see speech shape.
    private static let barCount = 14
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2.5
    private static let baseHeight: CGFloat = 3.5
    private static let maxHeight: CGFloat = 22

    /// Rolling normalized-amplitude history, oldest first.
    @State private var history: [Float] = Array(repeating: 0, count: barCount)

    var body: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { idx in
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(opacity(at: idx)))
                    .frame(width: Self.barWidth, height: height(at: idx))
            }
        }
        .frame(height: Self.maxHeight)
        .onChange(of: level) { _, newLevel in
            // Soft gain + gamma: speech RMS sits ~0.05–0.25 on a typical mic;
            // the curve lets normal speech reach the upper range without
            // shouting, while keeping silence visibly flat.
            let amplified = min(1.0, newLevel * 3.5)
            let shaped = pow(amplified, 0.65)
            history.removeFirst()
            history.append(shaped)
        }
        .animation(.linear(duration: 0.05), value: history)
    }

    private func height(at index: Int) -> CGFloat {
        Self.baseHeight + CGFloat(history[index]) * (Self.maxHeight - Self.baseHeight)
    }

    /// Older samples fade toward the left edge so the trail dissolves
    /// instead of ending in a hard cliff.
    private func opacity(at index: Int) -> Double {
        0.30 + 0.62 * (Double(index) / Double(Self.barCount - 1))
    }
}

/// Static bars for the idle fallback state (the overlay is normally hidden
/// when idle; this just keeps the layout from collapsing).
private struct LevelBarsView: View {
    let level: Float
    let active: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 3, height: 4)
            }
        }
    }
}

/// Wraps `NSVisualEffectView` so SwiftUI can use a real AppKit blur (the
/// `.regularMaterial` / `.ultraThinMaterial` SwiftUI materials don't include
/// the darker `hudWindow` look that fits a floating overlay against arbitrary
/// app backgrounds).
private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
