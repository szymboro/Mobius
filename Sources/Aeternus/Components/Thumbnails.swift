import SwiftUI
import AeternusCore

/// Remote image with a neutral placeholder.
struct RemoteImage: View {
    let url: String?

    var body: some View {
        AsyncImage(url: Self.resolve(url)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            default:
                Rectangle().fill(.quaternary)
            }
        }
    }

    /// YouTube avatar URLs can be protocol-relative ("//yt3.ggpht.com/…"); empty means none.
    static func resolve(_ url: String?) -> URL? {
        guard var string = url?.trimmingCharacters(in: .whitespaces), !string.isEmpty else { return nil }
        if string.hasPrefix("//") { string = "https:" + string }
        return URL(string: string)
    }
}

/// 16:9 video thumbnail with a duration / live badge and optional watch progress.
struct VideoThumbnail: View {
    let video: VideoInfo
    var progress: Double? = nil
    /// Lengths found after the list loaded show up without a reload.
    @ObservedObject private var durations = VideoDurations.shared
    @ObservedObject private var deArrow = DeArrow.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { image }
            .clipShape(.rect(cornerRadius: 12))
            .overlay(alignment: .bottomTrailing) { badge }
            .overlay(alignment: .bottom) {
                if let progress, progress > 0 {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(.tint)
                            .frame(width: proxy.size.width * min(progress, 1), height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .clipShape(.rect(cornerRadius: 12))
                }
            }
            .task(id: "\(video.videoId)|\(settings.deArrowTitles)|\(settings.deArrowThumbnails)") {
                await deArrow.load(videoId: video.videoId)
            }
    }

    @ViewBuilder
    private var image: some View {
        if let url = deArrow.thumbnailURL(for: video.videoId) {
            // DeArrow renders frames on demand; fall back to YouTube's thumbnail if it can't.
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: RemoteImage(url: video.thumbnail)
                default: Rectangle().fill(.quaternary)
                }
            }
        } else {
            RemoteImage(url: video.thumbnail)
        }
    }

    private var badgeText: String? {
        if video.isLive { return "LIVE" }
        guard let duration = video.knownDuration, duration > 0 else { return nil }
        return Formatters.duration(duration)
    }

    @ViewBuilder
    private var badge: some View {
        if let text = badgeText {
            Text(text)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(video.isLive ? Color.red : Color.black.opacity(0.75), in: Capsule())
                .padding(6)
        }
    }
}

struct Avatar: View {
    let url: String?
    var size: CGFloat = 36

    var body: some View {
        RemoteImage(url: url)
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}
