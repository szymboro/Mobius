import SwiftUI
import MobiusCore

/// YouTube Music-style artist page: artwork header, top songs, then carousels for albums,
/// singles, videos, playlists and related artists. Shown by `ChannelView` for "- Topic" channels
/// (and other channels without videos) that YouTube Music knows as an artist.
struct ArtistPage: View {
    let artist: MusicArtist
    let channelId: String
    let avatar: String?
    @State private var descriptionExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    actions
                }
                if !artist.topSongs.isEmpty { topSongs }
                ForEach(artist.shelves) { shelf in
                    MusicShelfView(shelf: shelf)
                }
                if let description = artist.description, !description.isEmpty { about(description) }
            }
            .padding(.bottom, 24)
        }
    }

    private var header: some View {
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay { RemoteImage(url: artist.thumbnail) }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(artist.name)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    if let audience = artist.audience {
                        Text(audience).font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .foregroundStyle(.white)
                .padding()
            }
            .clipped()
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if let first = artist.topSongs.first {
                // Autoplay carries on with related songs afterwards.
                NavigationLink(value: Route.video(first.videoId)) {
                    Label("Play", systemImage: "play.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
            SubscribeButton(channelId: channelId, name: artist.name, avatar: avatar ?? artist.thumbnail)
        }
        .padding(.horizontal)
    }

    private var topSongs: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Top songs").font(.title3.bold())
                Spacer()
                if let playlistId = artist.topSongsPlaylistId {
                    NavigationLink("See all", value: Route.playlist(playlistId))
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(.horizontal)
            ForEach(artist.topSongs) { track in
                NavigationLink(value: Route.video(track.videoId)) {
                    MusicTrackRow(track: track)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func about(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About").font(.title3.bold())
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(descriptionExpanded ? nil : 4)
            Button(descriptionExpanded ? "Show less" : "Show more") {
                withAnimation { descriptionExpanded.toggle() }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal)
    }
}

private struct MusicTrackRow: View {
    let track: MusicTrack

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: track.thumbnail)
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text([track.album, track.plays].compactMap { $0 }.joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .contentShape(Rectangle())
    }
}

/// One horizontal carousel (Albums, Singles & EPs, Videos, Featured on, Fans might also like…).
private struct MusicShelfView: View {
    let shelf: MusicShelf

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shelf.title)
                .font(.title3.bold())
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shelf.items) { item in
                        NavigationLink(value: route(for: item)) {
                            MusicTile(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func route(for item: MusicItem) -> Route {
        switch item.kind {
        case .album(let id), .playlist(let id): .playlist(id)
        case .video(let id): .video(id)
        case .artist(let id): .channel(id)
        }
    }
}

private struct MusicTile: View {
    let item: MusicItem

    private var isArtist: Bool {
        if case .artist = item.kind { return true }
        return false
    }

    var body: some View {
        let width: CGFloat = item.isSquare ? 140 : 220
        VStack(alignment: isArtist ? .center : .leading, spacing: 6) {
            Color.clear
                .aspectRatio(item.isSquare ? 1 : 16 / 9, contentMode: .fit)
                .overlay { RemoteImage(url: item.thumbnail) }
                .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(.rect(cornerRadius: 8)))
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(isArtist ? .center : .leading)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: isArtist ? .center : .leading)
        .contentShape(Rectangle())
    }
}
