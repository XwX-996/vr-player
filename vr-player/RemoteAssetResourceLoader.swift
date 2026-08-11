import AVFoundation
import Foundation
import UniformTypeIdentifiers

nonisolated final class ResourceLoadingRequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequests: Set<ObjectIdentifier> = []
    private var cancelledRequests: Set<ObjectIdentifier> = []

    func register(_ requestID: ObjectIdentifier) {
        lock.lock()
        activeRequests.insert(requestID)
        lock.unlock()
    }

    func cancel(_ requestID: ObjectIdentifier) {
        lock.lock()
        if activeRequests.contains(requestID) {
            cancelledRequests.insert(requestID)
        }
        lock.unlock()
    }

    func isCancelled(_ requestID: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledRequests.contains(requestID)
    }

    func finish(_ requestID: ObjectIdentifier) {
        lock.lock()
        activeRequests.remove(requestID)
        cancelledRequests.remove(requestID)
        lock.unlock()
    }
}

nonisolated final class RemoteAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let cache: ByteRangeCache
    private let contentType: String
    private let workQueue = DispatchQueue(
        label: "cxc.vr-player.resource-loader.work",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let requestRegistry = ResourceLoadingRequestRegistry()

    init(cache: ByteRangeCache, fileExtension: String) {
        self.cache = cache
        contentType = UTType(filenameExtension: fileExtension)?.identifier ?? UTType.movie.identifier
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let requestID = ObjectIdentifier(loadingRequest)
        requestRegistry.register(requestID)
        workQueue.async { [weak self, weak loadingRequest] in
            guard let self else { return }
            guard let loadingRequest else {
                self.requestRegistry.finish(requestID)
                return
            }
            self.fulfill(loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        requestRegistry.cancel(ObjectIdentifier(loadingRequest))
    }

    private nonisolated func fulfill(_ loadingRequest: AVAssetResourceLoadingRequest) {
        defer { requestRegistry.finish(ObjectIdentifier(loadingRequest)) }
        do {
            if let informationRequest = loadingRequest.contentInformationRequest {
                informationRequest.contentType = contentType
                informationRequest.contentLength = cache.contentLength
                informationRequest.isByteRangeAccessSupported = true
            }

            guard let dataRequest = loadingRequest.dataRequest else {
                loadingRequest.finishLoading()
                return
            }

            var offset = dataRequest.currentOffset > 0
                ? dataRequest.currentOffset
                : dataRequest.requestedOffset
            let resourceEnd = cache.contentLength
            guard offset >= 0, offset <= resourceEnd else {
                throw ByteRangeCacheError.invalidOffset
            }
            let requestedEnd: Int64
            if dataRequest.requestsAllDataToEndOfResource {
                requestedEnd = resourceEnd
            } else {
                let requestedLength = Int64(dataRequest.requestedLength)
                let (unboundedEnd, overflow) = dataRequest.requestedOffset.addingReportingOverflow(requestedLength)
                guard dataRequest.requestedOffset >= 0, requestedLength >= 0, !overflow else {
                    throw ByteRangeCacheError.invalidOffset
                }
                requestedEnd = min(unboundedEnd, resourceEnd)
            }

            while offset < requestedEnd {
                if isCancelled(loadingRequest) { return }
                let chunkSize = Int(min(1_048_576, requestedEnd - offset))
                let data = try cache.read(offset: offset, length: chunkSize)
                guard !data.isEmpty else { throw ByteRangeCacheError.sourceEndedEarly }
                dataRequest.respond(with: data)
                offset += Int64(data.count)
            }
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }

    private nonisolated func isCancelled(_ request: AVAssetResourceLoadingRequest) -> Bool {
        requestRegistry.isCancelled(ObjectIdentifier(request))
    }
}
