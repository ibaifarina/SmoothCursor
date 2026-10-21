import SCCore
import SwiftUI

/// Read-only track view with a draggable playhead. Replaced by the real timeline in step 5b.
struct TimelinePlaceholder: View {
    let project: Project
    @Binding var playhead: Seconds

    private let headerWidth: CGFloat = 116
    private let trackHeight: CGFloat = 32
    private let tracks: [(name: String, icon: String, color: Color)] = [
        ("Video", "film", Palette.trackVideo),
        ("Zoom", "plus.magnifyingglass", Palette.trackZoom),
        ("Camera", "video", Palette.trackCamera),
    ]

    var body: some View {
        GeometryReader { geo in
            let laneWidth = max(1, geo.size.width - headerWidth - 20)
            let duration = max(project.recording.duration, 0.001)
            let scale = laneWidth / duration

            VStack(alignment: .leading, spacing: 6) {
                ruler(duration: duration, scale: scale)
                    .frame(height: 22)
                    .padding(.leading, headerWidth)
                ForEach(tracks, id: \.name) { track in
                    HStack(spacing: 0) {
                        Label(track.name, systemImage: track.icon)
                            .labelStyle(SCLabelStyle())
                            .font(Typo.label)
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: headerWidth, alignment: .leading)
                            .padding(.leading, 14)
                            .frame(width: headerWidth, alignment: .leading)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: Radius.s).fill(Palette.canvas.opacity(0.6))
                            lane(track.name, color: track.color, duration: duration, scale: scale)
                        }
                        .frame(width: laneWidth, height: trackHeight)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                Playhead(height: geo.size.height - 8)
                    .offset(x: headerWidth + playhead * scale - 6)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                playhead = min(max(0, (value.location.x - headerWidth) / scale), duration)
            })
        }
        .padding(.top, 6)
    }

    @ViewBuilder private func lane(_ name: String, color: Color, duration: Seconds, scale: CGFloat) -> some View {
        switch name {
        case "Video":
            Clip(title: "\(project.name) · \(duration.clock)", icon: "film", color: color)
        case "Zoom":
            ForEach(project.zooms) { z in
                Clip(title: String(format: "%.1f×", z.scale), icon: "plus.magnifyingglass", color: color)
                    .frame(width: max(8, z.range.duration * scale))
                    .offset(x: z.range.start * scale)
            }
        default:
            ForEach(project.cameraClips) { c in
                Clip(title: c.preset.label, icon: "video", color: color)
                    .frame(width: max(8, c.range.duration * scale))
                    .offset(x: c.range.start * scale)
            }
        }
    }

    private func ruler(duration: Seconds, scale: CGFloat) -> some View {
        let step = max(1, (duration / 12).rounded())
        return ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: 0, through: duration, by: step)), id: \.self) { t in
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "%d:%02d", Int(t) / 60, Int(t) % 60))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Palette.textTertiary)
                    Rectangle().fill(Palette.strokeStrong).frame(width: 1, height: 5)
                }
                .offset(x: t * scale)
            }
        }
    }
}

private struct Clip: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(title).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.opacity(0.55), in: .rect(cornerRadius: Radius.s))
        .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(color.opacity(0.9), lineWidth: 1))
    }
}

private struct Playhead: View {
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 3)
                .fill(Palette.accent)
                .frame(width: 12, height: 14)
            Rectangle().fill(Palette.accent).frame(width: 2)
        }
        .frame(height: height)
        .shadow(color: Palette.accent.opacity(0.4), radius: 4)
    }
}
