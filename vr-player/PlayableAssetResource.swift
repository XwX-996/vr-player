import AVFoundation
import Foundation

final class PlayableAssetResource: @unchecked Sendable {
    let asset: AVURLAsset

    private let securityScopedFile: SecurityScopedFile
    private let resourceLoader: RemoteAssetResourceLoader?
    private let resourceLoaderQueue: DispatchQueue?

    init(item: PlaylistItem) throws {
        securityScopedFile = try SecurityScopedFile(bookmarkData: item.bookmarkData)

        if item.sourceKind == .remote {
            let cache = try ByteRangeCache(
                sourceURL: securityScopedFile.url,
                cacheKey: item.id
            )
            let loader = RemoteAssetResourceLoader(
                cache: cache,
                fileExtension: securityScopedFile.url.pathExtension
            )
            let queue = DispatchQueue(label: "cxc.vr-player.resource-loader.delegate")
            var components = URLComponents()
            components.scheme = "vrplayer"
            components.host = item.id.uuidString
            components.path = "/video.\(securityScopedFile.url.pathExtension)"
            guard let virtualURL = components.url else {
                throw URLError(.badURL)
            }
            asset = AVURLAsset(url: virtualURL)
            asset.resourceLoader.setDelegate(loader, queue: queue)
            resourceLoader = loader
            resourceLoaderQueue = queue
        } else {
            asset = AVURLAsset(url: securityScopedFile.url)
            resourceLoader = nil
            resourceLoaderQueue = nil
        }
    }
}
