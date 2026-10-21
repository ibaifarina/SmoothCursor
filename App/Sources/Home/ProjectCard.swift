import SCCore
import SCProject
import SwiftUI

struct ProjectCard: View {
    let summary: ProjectSummary
    let isRenaming: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onCommitRename: (String) -> Void

    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            preview
            VStack(alignment: .leading, spacing: 3) {
                if isRenaming {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(Typo.bodyMedium)
                        .focused($nameFocused)
                        .onSubmit { onCommitRename(draftName) }
                        .onExitCommand { onCommitRename(summary.name) }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Palette.raised, in: .rect(cornerRadius: Radius.s))
                        .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(Palette.accent))
                        .onAppear { draftName = summary.name; nameFocused = true }
                        .onChange(of: nameFocused) { if !nameFocused { onCommitRename(draftName) } }
                } else {
                    Text(summary.name)
                        .font(Typo.bodyMedium)
                        .lineLimit(1)
                        .onTapGesture(count: 2, perform: onRename)
                }
                HStack(spacing: 6) {
                    Image(systemName: summary.sourceKind.symbol).font(.system(size: 10, weight: .semibold))
                    Text(summary.modifiedAt, format: .relative(presentation: .named))
                    Text("·")
                    Text(verbatim: "\(summary.pixelSize.width)×\(summary.pixelSize.height)")
                }
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 2)
        }
        .task(id: summary.thumbnailURL) { await loadThumbnail() }
    }

    private var preview: some View {
        ZStack {
            Rectangle().fill(Palette.surface)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: "film").font(.system(size: 22)).foregroundStyle(Palette.textTertiary)
            }
            Color.black.opacity(hovering ? 0.25 : 0)
            Image(systemName: "play.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: .circle)
                .opacity(hovering ? 1 : 0)
                .scaleEffect(hovering ? 1 : 0.85)
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Radius.l))
        .overlay(alignment: .bottomTrailing) {
            Text(summary.duration.clock)
                .font(Typo.mono)
                .foregroundStyle(.white)
                .padding(.horizontal, 7).frame(height: 20)
                .background(.black.opacity(0.65), in: .capsule)
                .padding(8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.l)
                .strokeBorder(hovering ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(hovering ? 0.45 : 0.2), radius: hovering ? 16 : 6, y: hovering ? 8 : 3)
        .offset(y: hovering ? -2 : 0)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onOpen)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
    }

    private func loadThumbnail() async {
        let url: URL? = if let existing = summary.thumbnailURL { existing } else { await Thumbnailer.ensureThumbnail(for: summary.url) }
        thumbnail = url.flatMap(NSImage.init(contentsOf:))
    }
}

extension RecordingInfo.SourceKind {
    var symbol: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        case .iPhone, .simulator: "iphone"
        case .imported: "film"
        }
    }
}
