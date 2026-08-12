@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

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
            "只能添加 MP4 和 MOV 视频。"
        case .missingVideoTrack:
            "所选文件不包含视频轨道。"
        case .unsupportedVideoCodec:
            "仅支持 H.264 和 H.265 视频。"
        case .unsupportedAudioCodec:
            "仅支持 AAC 音频。"
        case .hdrVideo:
            "当前版本不支持 HDR 视频。"
        case .unplayableAsset:
            "AVFoundation 无法播放所选视频。"
        }
    }
}

nonisolated enum SupportedVideoCodec: String, Codable, Equatable, Sendable {
    case h264 = "H.264"
    case hevc = "HEVC"
}

nonisolated struct HEVCHardwareProbeResult: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case supported
        case unsupported
        case inconclusive
    }

    let status: Status
    let statusCode: Int32?
    let detail: String

    static func supported() -> Self {
        Self(status: .supported, statusCode: nil, detail: "首个 HEVC 帧已通过硬件解码。")
    }

    static func unsupported(statusCode: OSStatus, detail: String) -> Self {
        Self(status: .unsupported, statusCode: statusCode, detail: detail)
    }

    static func inconclusive(statusCode: OSStatus? = nil, detail: String) -> Self {
        Self(status: .inconclusive, statusCode: statusCode, detail: detail)
    }
}

nonisolated struct MediaInspection: Equatable, Sendable {
    let container: String
    let videoCodec: SupportedVideoCodec
    let sampleEntries: [String]
    let width: Int
    let height: Int
    let frameRate: Double
    let bitRate: Double
    let isHDR: Bool
    let audioCodecs: [String]
    let isSystemPlayable: Bool
    let hevcHardwareProbe: HEVCHardwareProbeResult?

    var exceedsValidatedPlaybackRange: Bool {
        width > 4_096 || height > 2_160 || frameRate > 60.5
    }

    var requiresCompatibilityConfirmation: Bool {
        guard videoCodec == .hevc else { return false }
        return exceedsValidatedPlaybackRange
            || !isSystemPlayable
            || hevcHardwareProbe?.status != .supported
    }

    var summary: String {
        let dimensions = width > 0 && height > 0 ? "\(width)x\(height)" : "分辨率未知"
        let fps = frameRate > 0 ? String(format: "%.1f fps", frameRate) : "帧率未知"
        let rate = bitRate > 0 ? String(format: "%.1f Mbps", bitRate / 1_000_000) : "码率未知"
        let entries = sampleEntries.isEmpty ? videoCodec.rawValue : sampleEntries.joined(separator: ", ")
        return "\(videoCodec.rawValue) (\(entries)), \(dimensions), \(fps), \(rate)"
    }

    var compatibilityWarning: String {
        var reasons: [String] = []
        if exceedsValidatedPlaybackRange {
            reasons.append("此视频超出了已验证的 4K60 播放范围。")
        }
        if !isSystemPlayable {
            reasons.append("AVFoundation 检测到完整文件可能无法正常播放。")
        }
        if let probe = hevcHardwareProbe, probe.status != .supported {
            reasons.append(probe.detail)
        }
        reasons.append("仍可添加原始文件并尝试硬件播放，不会降低画质。")
        return "\(summary)\n\n\(reasons.joined(separator: " "))"
    }
}

nonisolated enum MediaImportValidator {
    static let hvc1SampleEntry: FourCharCode = fourCC("hvc1")
    static let hev1SampleEntry: FourCharCode = fourCC("hev1")

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

    static func validate(url: URL) async throws -> MediaInspection {
        try validateContainer(url: url)

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw MediaImportValidationError.missingVideoTrack
        }

        var detectedCodec: SupportedVideoCodec?
        var sampleEntries: [String] = []
        var width = 0
        var height = 0
        var frameRate: Double = 0
        var bitRate: Double = 0
        var containsHDR = false

        for track in videoTracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty else {
                throw MediaImportValidationError.unsupportedVideoCodec
            }
            for description in descriptions {
                let subtype = CMFormatDescriptionGetMediaSubType(description)
                guard let codec = videoCodec(for: subtype) else {
                    throw MediaImportValidationError.unsupportedVideoCodec
                }
                if let detectedCodec, detectedCodec != codec {
                    throw MediaImportValidationError.unsupportedVideoCodec
                }
                detectedCodec = codec
                sampleEntries.append(fourCCString(subtype))
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                width = max(width, Int(dimensions.width))
                height = max(height, Int(dimensions.height))
            }

            let characteristics = try await track.load(.mediaCharacteristics)
            containsHDR = containsHDR || characteristics.contains(.containsHDRVideo)
            frameRate = max(frameRate, Double(try await track.load(.nominalFrameRate)))
            bitRate = max(bitRate, Double(try await track.load(.estimatedDataRate)))
        }

        guard let videoCodec = detectedCodec else {
            throw MediaImportValidationError.unsupportedVideoCodec
        }
        var audioCodecNames: [String] = []
        var audioCodecs: [FourCharCode] = []
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty else {
                throw MediaImportValidationError.unsupportedAudioCodec
            }
            for description in descriptions {
                let subtype = CMFormatDescriptionGetMediaSubType(description)
                audioCodecs.append(subtype)
                audioCodecNames.append(fourCCString(subtype))
            }
        }

        let isPlayable = try await asset.load(.isPlayable)
        try validateMediaPolicy(
            videoCodec: videoCodec,
            isHDR: containsHDR,
            audioCodecs: audioCodecs,
            isSystemPlayable: isPlayable
        )

        let probe = videoCodec == .hevc
            ? await HEVCHardwareProbe.probe(asset: asset, track: videoTracks[0])
            : nil

        return MediaInspection(
            container: url.pathExtension.lowercased(),
            videoCodec: videoCodec,
            sampleEntries: Array(Set(sampleEntries)).sorted(),
            width: width,
            height: height,
            frameRate: frameRate,
            bitRate: bitRate,
            isHDR: containsHDR,
            audioCodecs: Array(Set(audioCodecNames)).sorted(),
            isSystemPlayable: isPlayable,
            hevcHardwareProbe: probe
        )
    }

    static func validateContainer(url: URL) throws {
        let supportedExtensions = ["mp4", "mov"]
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw MediaImportValidationError.unsupportedContainer
        }
    }

    static func validateMediaPolicy(
        videoCodec: SupportedVideoCodec,
        isHDR: Bool,
        audioCodecs: [FourCharCode],
        isSystemPlayable: Bool
    ) throws {
        if isHDR {
            throw MediaImportValidationError.hdrVideo
        }
        if audioCodecs.contains(where: { !supportedAudioCodecs.contains($0) }) {
            throw MediaImportValidationError.unsupportedAudioCodec
        }
        if !isSystemPlayable, videoCodec != .hevc {
            throw MediaImportValidationError.unplayableAsset
        }
    }

    static func videoCodec(for subtype: FourCharCode) -> SupportedVideoCodec? {
        switch subtype {
        case kCMVideoCodecType_H264:
            .h264
        case kCMVideoCodecType_HEVC, hvc1SampleEntry, hev1SampleEntry:
            .hevc
        default:
            nil
        }
    }

    static func fourCC(_ text: String) -> FourCharCode {
        text.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    static func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", value)
    }
}

private nonisolated final class HEVCProbeCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var decodedFrame = false
    private(set) var callbackStatus: OSStatus = noErr

    func record(status: OSStatus, imageBuffer: CVImageBuffer?) {
        lock.lock()
        if status != noErr {
            callbackStatus = status
        }
        if imageBuffer != nil {
            decodedFrame = true
        }
        lock.unlock()
    }

    func snapshot() -> (decodedFrame: Bool, status: OSStatus) {
        lock.lock()
        defer { lock.unlock() }
        return (decodedFrame, callbackStatus)
    }
}

private nonisolated enum HEVCHardwareProbe {
    static func probe(asset: AVAsset, track: AVAssetTrack) async -> HEVCHardwareProbeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: probeSynchronously(asset: asset, track: track))
            }
        }
    }

    private static func probeSynchronously(asset: AVAsset, track: AVAssetTrack) -> HEVCHardwareProbeResult {
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                return .inconclusive(detail: "HEVC 硬件检查无法读取压缩视频轨道。")
            }
            reader.add(output)
            guard reader.startReading() else {
                return .inconclusive(
                    detail: reader.error?.localizedDescription
                        ?? "HEVC 硬件检查无法开始读取视频轨道。"
                )
            }

            var firstSample: CMSampleBuffer?
            for _ in 0..<120 {
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard CMSampleBufferGetNumSamples(sample) > 0,
                      CMSampleBufferGetDataBuffer(sample) != nil,
                      CMSampleBufferGetFormatDescription(sample) != nil
                else { continue }
                firstSample = sample
                break
            }
            guard let firstSample,
                  let formatDescription = CMSampleBufferGetFormatDescription(firstSample)
            else {
                return .inconclusive(
                    detail: reader.error?.localizedDescription
                        ?? "HEVC 硬件检查未找到可解码的视频样本。"
                )
            }

            let callbackState = HEVCProbeCallbackState()
            let decoderSpecification = [
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true,
            ] as CFDictionary
            let imageAttributes = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ] as CFDictionary
            var session: VTDecompressionSession?
            let creationStatus = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: decoderSpecification,
                imageBufferAttributes: imageAttributes,
                outputCallback: nil,
                decompressionSessionOut: &session
            )
            guard creationStatus == noErr, let session else {
                return .unsupported(
                    statusCode: creationStatus,
                    detail: "此设备无法为该视频创建 HEVC 硬件解码器（OSStatus \(creationStatus)）。"
                )
            }
            defer { VTDecompressionSessionInvalidate(session) }

            var decodeStatus = noErr
            var currentSample: CMSampleBuffer? = firstSample
            var submittedSamples = 0
            while let sample = currentSample, submittedSamples < 120 {
                guard CMSampleBufferGetNumSamples(sample) > 0,
                      CMSampleBufferGetDataBuffer(sample) != nil
                else {
                    currentSample = output.copyNextSampleBuffer()
                    continue
                }
                var infoFlags = VTDecodeInfoFlags()
                decodeStatus = VTDecompressionSessionDecodeFrame(
                    session,
                    sampleBuffer: sample,
                    flags: [],
                    infoFlagsOut: &infoFlags,
                    outputHandler: { status, _, imageBuffer, _, _ in
                        callbackState.record(status: status, imageBuffer: imageBuffer)
                    }
                )
                submittedSamples += 1
                if decodeStatus != noErr || callbackState.snapshot().decodedFrame {
                    break
                }
                currentSample = output.copyNextSampleBuffer()
            }
            let finishStatus = VTDecompressionSessionFinishDelayedFrames(session)
            let waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(session)
            let snapshot = callbackState.snapshot()
            if snapshot.decodedFrame {
                return .supported()
            }
            let finalStatus = [decodeStatus, finishStatus, waitStatus, snapshot.status]
                .first(where: { $0 != noErr }) ?? noErr
            if finalStatus != noErr {
                return .unsupported(
                    statusCode: finalStatus,
                    detail: "HEVC 硬件解码器拒绝了首个视频样本（OSStatus \(finalStatus)）。"
                )
            }
            return .inconclusive(
                detail: "HEVC 硬件解码器已打开，但首个样本未生成可见画面。"
            )
        } catch {
            return .inconclusive(detail: "HEVC 硬件检查失败：\(error.localizedDescription)")
        }
    }
}
