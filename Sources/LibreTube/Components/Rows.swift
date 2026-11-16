import SwiftUI
import LibreTubeCore

/// Compact video row: thumbnail on the left, details on the right.
struct VideoRow: View {
    let video: VideoInfo
    var progress: Double? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VideoThumbnail(video: video, progress: progress)
                .frame(width: 160)
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let uploader = video.uploaderName, !uploader.isEmpty {
                    UploaderLabel(name: uploader, verified: video.uploaderVerified)
                }
                if !video.metadataLine.isEmpty {
                    Text(video.metadataLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .videoContextMenu(video)
    }
}

/// Large video card used on the Home and Subscriptions feeds.
struct VideoCard: View {
    let video: VideoInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoThumbnail(video: video)
            HStack(alignment: .top, spacing: 10) {
                if video.uploaderAvatar != nil {
                    Avatar(url: video.uploaderAvatar)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    let details = [video.uploaderName, video.metadataLine]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " • ")
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
        .videoContextMenu(video)
    }
}

struct UploaderLabel: View {
    let name: String
    let verified: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(name)
            if verified {
                Image(systemName: "checkmark.seal.fill")
                    .imageScale(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct ChannelRow: View {
    let name: String
    let avatar: String?
    var verified = false
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: avatar, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(name).font(.headline).lineLimit(1)
                    if verified {
                        Image(systemName: "checkmark.seal.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

struct PlaylistRow: View {
    let name: String
    let thumbnail: String?
    var subtitle: String? = nil
    var videoCount: Int? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { RemoteImage(url: thumbnail) }
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .trailing) {
                    if let videoCount {
                        VStack(spacing: 2) {
                            Image(systemName: "list.bullet")
                            Text("\(videoCount)").font(.caption.monospacedDigit())
                        }
                        .foregroundStyle(.white)
                        .frame(maxHeight: .infinity)
                        .frame(width: 48)
                        .background(.black.opacity(0.6))
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 12, topTrailingRadius: 12))
                    }
                }
                .frame(width: 160)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Renders any search / channel result with the matching row.
struct ContentRow: View {
    let item: ContentItem

    var body: some View {
        switch optional(item.type) ?? "stream" {
        case "channel":
            ChannelRow(
                name: optional(item.name) ?? "",
                avatar: optional(item.thumbnail),
                verified: optional(item.verified) ?? false,
                subtitle: channelSubtitle
            )
        case "playlist":
            PlaylistRow(
                name: optional(item.name) ?? "",
                thumbnail: optional(item.thumbnail),
                subtitle: optional(item.uploaderName),
                videoCount: intValue(item.videos)
            )
        default:
            if let video = VideoInfo(item) {
                VideoRow(video: video)
            }
        }
    }

    private var channelSubtitle: String? {
        guard let subscribers = intValue(item.subscribers) else { return nil }
        return "\(Formatters.compactCount(subscribers)) subscribers"
    }
}
