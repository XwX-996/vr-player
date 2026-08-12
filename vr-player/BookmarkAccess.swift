import Foundation

enum BookmarkAccessError: LocalizedError {
    case staleBookmark

    var errorDescription: String? {
        switch self {
        case .staleBookmark:
            "此文件引用已失效，请从“文件”中重新添加视频。"
        }
    }
}

final class SecurityScopedFile: @unchecked Sendable {
    let url: URL
    private let didStartAccess: Bool

    init(bookmarkData: Data) throws {
        var isStale = false
        url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else { throw BookmarkAccessError.staleBookmark }
        didStartAccess = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

enum BookmarkAccess {
    struct ImportDescriptor {
        let bookmarkData: Data
        let sourceKind: MediaSourceKind
    }

    static func createBookmark(for url: URL) throws -> Data {
        try prepareImport(for: url).bookmarkData
    }

    static func prepareImport(for url: URL) throws -> ImportDescriptor {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let bookmarkData = try url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: [.fileSizeKey, .volumeIsLocalKey],
            relativeTo: nil
        )
        return ImportDescriptor(
            bookmarkData: bookmarkData,
            sourceKind: sourceKind(for: url)
        )
    }

    static func sourceKind(for url: URL) -> MediaSourceKind {
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal == false ? .remote : .local
    }
}
