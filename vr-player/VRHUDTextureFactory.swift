import UIKit

@MainActor
enum VRHUDTextureFactory {
    static let pixelSize = CGSize(width: 1_200, height: 640)

    static func makeImage(state: VRHUDState) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            let graphics = context.cgContext
            graphics.setFillColor(UIColor.black.withAlphaComponent(0.72).cgColor)
            graphics.addPath(UIBezierPath(roundedRect: CGRect(origin: .zero, size: pixelSize), cornerRadius: 8).cgPath)
            graphics.fillPath()

            switch state.mode {
            case .main:
                drawMain(state: state, in: graphics)
            case .playlist:
                drawPlaylist(state: state, in: graphics)
            }
        }.cgImage
    }

    private static func drawMain(state: VRHUDState, in context: CGContext) {
        drawIcon("xmark", in: VRHUDLayout.close, context: context, label: "Close")
        drawIcon("scope", in: VRHUDLayout.recenter, context: context, label: "Center")
        drawIcon("backward.end.fill", in: VRHUDLayout.previous, context: context, label: "Previous")
        drawIcon(state.isPlaying ? "pause.fill" : "play.fill", in: VRHUDLayout.playPause, context: context, label: state.isPlaying ? "Pause" : "Play")
        drawIcon("forward.end.fill", in: VRHUDLayout.next, context: context, label: "Next")
        drawIcon("list.bullet", in: VRHUDLayout.playlist, context: context, label: "Playlist")

        let progressRect = pixelRect(VRHUDLayout.progress).insetBy(dx: 18, dy: 32)
        drawSlider(
            rect: progressRect,
            value: state.duration > 0 ? state.position / state.duration : 0,
            bufferedValue: state.bufferedFraction,
            leadingText: MediaTime.text(state.position),
            trailingText: MediaTime.text(state.duration),
            symbol: nil,
            context: context
        )

        drawSegment(title: "180\u{00b0}", rect: VRHUDLayout.projection180, selected: state.projection == .hemisphere180, context: context)
        drawSegment(title: "360\u{00b0}", rect: VRHUDLayout.projection360, selected: state.projection == .sphere360, context: context)
        drawSegment(title: "Mono", rect: VRHUDLayout.mono, selected: state.stereoLayout == .mono, context: context)
        drawSegment(title: "SBS", rect: VRHUDLayout.sideBySide, selected: state.stereoLayout == .sideBySide, context: context)

        drawSlider(
            rect: pixelRect(VRHUDLayout.brightness).insetBy(dx: 16, dy: 34),
            value: state.brightness,
            bufferedValue: nil,
            leadingText: nil,
            trailingText: nil,
            symbol: "sun.max.fill",
            context: context
        )
        drawSlider(
            rect: pixelRect(VRHUDLayout.volume).insetBy(dx: 16, dy: 34),
            value: state.volume,
            bufferedValue: nil,
            leadingText: nil,
            trailingText: nil,
            symbol: "speaker.wave.2.fill",
            context: context
        )
    }

    private static func drawPlaylist(state: VRHUDState, in context: CGContext) {
        drawIcon("chevron.left", in: VRHUDLayout.playlistBack, context: context, label: "Back")
        drawText(
            "Playlist",
            rect: CGRect(x: 200, y: 42, width: 800, height: 64),
            font: .systemFont(ofSize: 34, weight: .semibold),
            color: .white,
            alignment: .center
        )

        for (index, entry) in state.playlistEntries.enumerated() {
            let rect = pixelRect(VRHUDLayout.playlistRow(index: index))
            context.setFillColor((entry.isCurrent ? UIColor.white.withAlphaComponent(0.18) : UIColor.white.withAlphaComponent(0.07)).cgColor)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath)
            context.fillPath()
            if entry.isCurrent {
                drawSymbol("play.fill", rect: CGRect(x: rect.minX + 24, y: rect.midY - 15, width: 30, height: 30), pointSize: 26)
            }
            drawText(
                entry.name,
                rect: CGRect(x: rect.minX + 74, y: rect.minY, width: rect.width - 100, height: rect.height),
                font: .systemFont(ofSize: 27, weight: entry.isCurrent ? .semibold : .regular),
                color: .white,
                alignment: .left
            )
        }

        if state.playlistPage > 0 {
            drawIcon("chevron.left", in: VRHUDLayout.playlistPreviousPage, context: context, label: "Previous page")
        }
        if state.playlistPage + 1 < state.playlistPageCount {
            drawIcon("chevron.right", in: VRHUDLayout.playlistNextPage, context: context, label: "Next page")
        }
        drawText(
            "\(state.playlistPage + 1) / \(max(state.playlistPageCount, 1))",
            rect: CGRect(x: 480, y: 545, width: 240, height: 54),
            font: .monospacedDigitSystemFont(ofSize: 23, weight: .medium),
            color: UIColor.white.withAlphaComponent(0.72),
            alignment: .center
        )
    }

    private static func drawIcon(
        _ systemName: String,
        in normalizedRect: VRNormalizedRect,
        context: CGContext,
        label: String
    ) {
        let rect = pixelRect(normalizedRect)
        drawSymbol(systemName, rect: CGRect(x: rect.midX - 29, y: rect.minY + 6, width: 58, height: 58), pointSize: 46)
        drawText(
            label,
            rect: CGRect(x: rect.minX, y: rect.maxY - 36, width: rect.width, height: 32),
            font: .systemFont(ofSize: 21, weight: .medium),
            color: UIColor.white.withAlphaComponent(0.82),
            alignment: .center
        )
    }

    private static func drawSegment(title: String, rect normalizedRect: VRNormalizedRect, selected: Bool, context: CGContext) {
        let rect = pixelRect(normalizedRect).insetBy(dx: 5, dy: 6)
        context.setFillColor((selected ? UIColor.white.withAlphaComponent(0.25) : UIColor.white.withAlphaComponent(0.07)).cgColor)
        context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath)
        context.fillPath()
        if selected {
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.62).cgColor)
            context.setLineWidth(2)
            context.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 8).cgPath)
            context.strokePath()
        }
        drawText(title, rect: rect, font: .systemFont(ofSize: 26, weight: .semibold), color: .white, alignment: .center)
    }

    private static func drawSlider(
        rect: CGRect,
        value: Double,
        bufferedValue: Double?,
        leadingText: String?,
        trailingText: String?,
        symbol: String?,
        context: CGContext
    ) {
        var track = rect
        if symbol != nil {
            track.origin.x += 54
            track.size.width -= 54
        }
        let clamped = min(max(value, 0), 1)
        context.setLineCap(.round)
        context.setLineWidth(8)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.18).cgColor)
        context.move(to: CGPoint(x: track.minX, y: track.midY))
        context.addLine(to: CGPoint(x: track.maxX, y: track.midY))
        context.strokePath()
        if let bufferedValue {
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.34).cgColor)
            context.move(to: CGPoint(x: track.minX, y: track.midY))
            context.addLine(to: CGPoint(x: track.minX + track.width * min(max(bufferedValue, 0), 1), y: track.midY))
            context.strokePath()
        }
        context.setStrokeColor(UIColor.white.cgColor)
        context.move(to: CGPoint(x: track.minX, y: track.midY))
        context.addLine(to: CGPoint(x: track.minX + track.width * clamped, y: track.midY))
        context.strokePath()
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: track.minX + track.width * clamped - 9, y: track.midY - 9, width: 18, height: 18))

        if let symbol {
            drawSymbol(symbol, rect: CGRect(x: rect.minX, y: rect.midY - 20, width: 40, height: 40), pointSize: 30)
        }
        if let leadingText, let trailingText {
            drawText(leadingText, rect: CGRect(x: track.minX, y: track.maxY + 6, width: 180, height: 32), font: .monospacedDigitSystemFont(ofSize: 20, weight: .medium), color: .white, alignment: .left)
            drawText(trailingText, rect: CGRect(x: track.maxX - 180, y: track.maxY + 6, width: 180, height: 32), font: .monospacedDigitSystemFont(ofSize: 20, weight: .medium), color: .white, alignment: .right)
        }
    }

    private static func drawSymbol(_ name: String, rect: CGRect, pointSize: CGFloat) {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let image = UIImage(systemName: name, withConfiguration: configuration)?.withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
        let size = image.size
        let scale = min(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        image.draw(in: CGRect(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height))
    }

    private static func drawText(
        _ text: String,
        rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let measured = (text as NSString).boundingRect(
            with: rect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        let drawRect = CGRect(x: rect.minX, y: rect.midY - measured.height / 2, width: rect.width, height: measured.height)
        (text as NSString).draw(in: drawRect, withAttributes: attributes)
    }

    private static func pixelRect(_ rect: VRNormalizedRect) -> CGRect {
        CGRect(
            x: CGFloat(rect.minX) * pixelSize.width,
            y: CGFloat(rect.minY) * pixelSize.height,
            width: CGFloat(rect.maxX - rect.minX) * pixelSize.width,
            height: CGFloat(rect.maxY - rect.minY) * pixelSize.height
        )
    }
}
