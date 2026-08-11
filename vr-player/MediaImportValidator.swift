import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

nonisolated enum MediaImportValidationError: LocalizedError {
    case unsupportedContainer
    case missingVideoTrack
    case unsupportedVideoCodec
    case unsupportedAudioCodec
    case hdrVideo
    case unplayableAsset

    var errorDescription: String? {
        switch self {
        case .unsupportedContainer:
            "Only MP4 and MOV videos can be added."
        case .missingVideoTrack:
            "The selected file does not contain a video track."
        case .unsupportedVideoCodec:
            "Only H.264 and H.265 video are supported."
        case .unsupportedAudioCodec:
            "Only AAC audio is supported."
        case .hdrVideo:
            "HDR video is not supported in this version."
        case .unplayableAsset:
            "The selected video cannot be played by AVFoundation."
        }
    }
}

nonisolated enum MediaImportValidator {
    private static let supportedVideoCodecs: Set<FourCharCode> = [
        kCMVideoCodecType_H264,
        kCMVideoCodecType_HEVC,
    ]

    private static let supportedAudioCodecs: Set<FourCharCode> = [
        kAudioFormatMPEG4AAC,
        kAudioFormatMPEG4AAC_HE,
        kAudioFormatMPEG4AAC_HE_V2,
        kAudioFormatMPEG4AAC_LD,
        kAudioFormatMPEG4AAC_ELD,
        kAudioFormatMPEG4AAC_ELD_SBR,
        kAudioFormatMPEG4AAC_ELD_V2,
        kAudioFormatMPEG4AAC_Spatial,
    ]

    static func validate(url: URL) async throws {
        try validateContainer(url: url)

        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw MediaImportValidationError.unplayableAsset
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw MediaImportValidationError.missingVideoTrack
        }
        for track in videoTracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty,
                  descriptions.allSatisfy({ supportedVideoCodecs.contains(CMFormatDescriptionGetMediaSubType($0)) })
            else {
                throw MediaImportValidationError.unsupportedVideoCodec
            }
            let characteristics = try await track.load(.mediaCharacteristics)
            if characteristics.contains(.containsHDRVideo) {
                throw MediaImportValidationError.hdrVideo
            }
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty,
                  descriptions.allSatisfy({ supportedAudioCodecs.contains(CMFormatDescriptionGetMediaSubType($0)) })
            else {
                throw MediaImportValidationError.unsupportedAudioCodec
            }
        }
    }

    static func validateContainer(url: URL) throws {
        let supportedExtensions = ["mp4", "mov"]
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw MediaImportValidationError.unsupportedContainer
        }
    }
}
