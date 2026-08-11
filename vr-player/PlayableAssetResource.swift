import AVFoundation
import Foundation

final class PlayableAssetResource: @unchecked Sendable {
    let asset: AVURLAsset

    private let securityScopedFile: SecurityScopedFile
    private let resourceLoader: RemoteAssetResourceLoader?
    private let resourceLoaderQueue: DispatchQueue?
    private let cache: ByteRangeCache?

    init(item: PlaylistItem) throws {
        securityScopedFile = try SecurityScopedFile(bookmarkData: item.bookmarkData)

        if item.sourceKind == .remote {
            let cache = try ByteRangeCache(
                sourceURL: securityScopedFile.url,
                cacheKey: item.id,
                persistedIndexData: item.cacheIndexData,
                persistedContentLength: item.cacheContentLength,
                persistedModificationDate: item.cacheSourceModificationDate
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
            self.cache = cache
        } else {
            asset = AVURLAsset(url: securityScopedFile.url)
            resourceLoader = nil
            resourceLoaderQueue = nil
            cache = nil
        }
    }

    func persistCacheIndex(to item: PlaylistItem) {
        guard let cache else { return }
        item.cacheIndexData = cache.indexSnapshotData()
        item.cacheContentLength = cache.contentLength
        item.cacheSourceModificationDate = cache.sourceModificationDate
        item.cacheUpdatedAt = .now
    }
}
