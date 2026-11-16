import AVFoundation
import LibreTubeCore

/// Serves the playlists of a `LocalHLS` presentation to AVPlayer through a custom URL scheme.
/// Only the `.m3u8` text goes through here; AVPlayer fetches the media byte ranges from
/// googlevideo.com directly.
final class LocalHLSLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "ltlocalhls"

    private let playlists: [String: Data]
    let queue = DispatchQueue(label: "LocalHLSLoader")

    init(hls: LocalHLS) {
        playlists = hls.playlists.mapValues { Data($0.utf8) }
    }

    var masterURL: URL {
        URL(string: "\(Self.scheme)://local/\(LocalHLS.masterName)")!
    }

    /// Keep the returned loader alive for as long as the asset plays (the resource loader holds it weakly).
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: masterURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme,
              let data = playlists[url.lastPathComponent] else {
            return false
        }
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = "public.m3u-playlist"
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
        return true
    }
}
