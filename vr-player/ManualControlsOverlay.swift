import SwiftUI

enum ManualControlPanel: Equatable {
    case display
    case style
    case threeD
    case panorama
    case playlist
}

nonisolated struct PlaybackScrubState: Equatable {
    private(set) var pendingPosition: Double?

    mutating func begin(at playbackPosition: Double, duration: Double) {
        pendingPosition = Self.clamped(playbackPosition, duration: duration)
    }

    mutating func update(to position: Double, duration: Double) {
        pendingPosition = Self.clamped(position, duration: duration)
    }

    mutating func finish() -> Double? {
        let position = pendingPosition
        pendingPosition = nil
        return position
    }

    func displayedPosition(playbackPosition: Double, duration: Double) -> Double {
        Self.clamped(pendingPosition ?? playbackPosition, duration: duration)
    }

    private static func clamped(_ position: Double, duration: Double) -> Double {
        min(max(position, 0), max(duration, 0))
    }
}

struct ManualControlsOverlay: View {
    let title: String
    let isPlaying: Bool
    let position: Double
    let duration: Double
    let playlist: [PlaylistItem]
    let currentItemID: UUID

    @Binding var preferences: VRPlayerPreferences
    @Binding var panel: ManualControlPanel?
    @State private var scrubState = PlaybackScrubState()

    let onClose: () -> Void
    let onDismiss: () -> Void
    let onActivity: () -> Void
    let onRecenter: () -> Void
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onSeek: (Double) -> Void
    let onSelectItem: (PlaylistItem) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)

                if panel == nil {
                    header

                    HStack {
                        VStack(spacing: 12) {
                            sideButton(symbol: "slider.horizontal.3", label: "显示设置", panel: .display)
                            sideButton(symbol: "wand.and.stars", label: "画面风格", panel: .style)
                        }
                        Spacer()
                        controlButton(symbol: "scope", label: "重置视角", size: 52) {
                            onActivity()
                            onRecenter()
                        }
                    }
                    .padding(.leading, 64)
                    .padding(.trailing, 20)
                    .padding(.bottom, 62)

                    VStack {
                        Spacer()
                        playbackBar
                            .frame(maxWidth: min(560, proxy.size.width * 0.62))
                            .padding(.bottom, 14)
                    }
                }

                if let panel {
                    panelView(panel)
                        .frame(width: min(340, proxy.size.width * 0.40))
                        .frame(maxHeight: max(proxy.size.height - 24, 180))
                        .position(
                            x: proxy.size.width - min(340, proxy.size.width * 0.40) / 2 - 18,
                            y: proxy.size.height / 2
                        )
                }
            }
        }
        .foregroundStyle(.white)
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack {
            HStack(spacing: 12) {
                controlButton(symbol: "xmark", label: "退出播放", size: 50) {
                    onActivity()
                    onClose()
                }

                Spacer(minLength: 20)

                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .shadow(radius: 3)
                    .frame(maxWidth: 440)

                Spacer(minLength: 20)

                HStack(spacing: 10) {
                    Button {
                        togglePanel(.threeD)
                    } label: {
                        Label("3D", systemImage: "cube.transparent")
                            .font(.callout.bold())
                            .frame(height: 48)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(ManualGlassButtonStyle(isSelected: panel == .threeD))
                    .accessibilityLabel("3D 设置")

                    Button {
                        togglePanel(.panorama)
                    } label: {
                        Text("360\u{00b0}")
                            .font(.callout.bold())
                            .frame(height: 48)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(ManualGlassButtonStyle(isSelected: panel == .panorama))
                    .accessibilityLabel("全景设置")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            Spacer()
        }
    }

    private var playbackBar: some View {
        VStack(spacing: 7) {
            Slider(
                value: seekBinding,
                in: 0...max(duration, 1),
                onEditingChanged: handleSeekEditingChanged
            )
                .tint(.white)

            HStack {
                Text(MediaTime.text(displayedSeekPosition))
                Spacer()
                Text(MediaTime.text(duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.86))

            HStack(spacing: 22) {
                controlButton(
                    symbol: "repeat",
                    label: preferences.repeatsCurrentItem ? "关闭单集循环" : "单集循环",
                    size: 38,
                    isSelected: preferences.repeatsCurrentItem
                ) {
                    updatePreference(\.repeatsCurrentItem, to: !preferences.repeatsCurrentItem)
                }

                controlButton(symbol: "list.bullet", label: "播放列表", size: 38, isSelected: panel == .playlist) {
                    togglePanel(.playlist)
                }

                controlButton(symbol: "backward.end.fill", label: "上一个", size: 38) {
                    onActivity()
                    onPrevious()
                }

                controlButton(symbol: isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "暂停" : "播放", size: 44) {
                    onActivity()
                    onPlayPause()
                }

                controlButton(symbol: "forward.end.fill", label: "下一个", size: 38) {
                    onActivity()
                    onNext()
                }

                Menu {
                    ForEach(playbackRates, id: \.self) { rate in
                        Button {
                            updatePreference(\.playbackRate, to: rate)
                        } label: {
                            if preferences.playbackRate == rate {
                                Label(rateText(rate), systemImage: "checkmark")
                            } else {
                                Text(rateText(rate))
                            }
                        }
                    }
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 18, weight: .semibold))
                        Text(rateText(preferences.playbackRate))
                            .font(.system(size: 9, weight: .bold))
                    }
                    .frame(width: 38, height: 38)
                }
                .buttonStyle(ManualGlassButtonStyle())
                .accessibilityLabel("播放速度")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func panelView(_ panel: ManualControlPanel) -> some View {
        switch panel {
        case .display:
            displayPanel
        case .style:
            stylePanel
        case .threeD:
            threeDPanel
        case .panorama:
            panoramaPanel
        case .playlist:
            playlistPanel
        }
    }

    private var displayPanel: some View {
        controlPanel(title: "显示设置") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        selectionTile(
                            symbol: "viewfinder.circle",
                            title: "鱼眼",
                            isSelected: preferences.displayMode == .fishEye
                        ) {
                            updatePreference(\.displayMode, to: .fishEye)
                        }
                        selectionTile(
                            symbol: "rectangle",
                            title: "扁平",
                            isSelected: preferences.displayMode == .flat
                        ) {
                            updatePreference(\.displayMode, to: .flat)
                        }
                    }

                    if preferences.displayMode == .fishEye {
                        sliderRow(
                            symbol: "circle",
                            title: "畸变强度",
                            value: intBinding(\.distortionStrength),
                            range: VRDistortionTuning.adjustmentRange,
                            valueText: percentageText
                        )
                        sliderRow(
                            symbol: "circle.dashed",
                            title: "边缘修正",
                            value: intBinding(\.edgeCorrection),
                            range: VRDistortionTuning.adjustmentRange,
                            valueText: percentageText
                        )

                        Button("恢复默认", systemImage: "arrow.counterclockwise") {
                            var copy = preferences
                            copy.distortionStrength = 0
                            copy.edgeCorrection = 0
                            preferences = copy
                            onActivity()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                        Divider().overlay(.white.opacity(0.15))
                    }

                    sliderRow(symbol: "eye", title: "瞳距", value: intBinding(\.pupilDistance), range: -100...100)
                    sliderRow(symbol: "arrow.left.and.right", title: "距离", value: intBinding(\.eyeDistance), range: 0...100)
                    sliderRow(symbol: "rectangle.dashed", title: "比例", value: intBinding(\.eyeAspect), range: 0...100)
                    sliderRow(symbol: "arrow.up.left.and.arrow.down.right", title: "缩放", value: intBinding(\.eyeScale), range: 0...100)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var stylePanel: some View {
        controlPanel(title: "风格化") {
            sliderRow(symbol: "sun.max", title: "亮度", value: intBinding(\.brightness), range: -100...100)
            sliderRow(symbol: "circle.lefthalf.filled", title: "对比度", value: intBinding(\.contrast), range: -100...100)
            sliderRow(symbol: "paintpalette", title: "饱和度", value: intBinding(\.saturation), range: -100...100)

            Button("恢复默认", systemImage: "arrow.counterclockwise") {
                var copy = preferences
                copy.brightness = 0
                copy.contrast = 0
                copy.saturation = 0
                preferences = copy
                onActivity()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var panoramaPanel: some View {
        controlPanel(title: "全景模式") {
            Toggle("全景模式", isOn: boolBinding(\.panoramaEnabled))
                .font(.headline)

            HStack(spacing: 8) {
                selectionTile(symbol: "globe.americas", title: "180\u{00b0}", isSelected: preferences.projection == .hemisphere180) {
                    updatePanoramaProjection(.hemisphere180)
                }
                selectionTile(symbol: "globe.americas.fill", title: "360\u{00b0}", isSelected: preferences.projection == .sphere360) {
                    updatePanoramaProjection(.sphere360)
                }
            }

            Toggle("开启 VR 眼镜模式", isOn: boolBinding(\.vrGlassesEnabled))

            VStack(spacing: 0) {
                layoutRow(symbol: "person.crop.rectangle", title: "单幅", layout: .mono)
                Divider().overlay(.white.opacity(0.15))
                layoutRow(symbol: "rectangle.split.2x1", title: "左右", layout: .sideBySide)
                Divider().overlay(.white.opacity(0.15))
                layoutRow(symbol: "rectangle.split.1x2", title: "上下", layout: .topBottom)
            }
        }
    }

    private var threeDPanel: some View {
        controlPanel(title: "3D模式") {
            Toggle("3D模式", isOn: threeDEnabledBinding)
                .font(.headline)

            VStack(spacing: 0) {
                threeDModeRow(symbol: "rectangle", title: "普通", mode: .fit)
                Divider().overlay(.white.opacity(0.15))
                threeDModeRow(symbol: "rectangle.inset.filled", title: "充满", mode: .fill)
            }
        }
    }

    private var playlistPanel: some View {
        controlPanel(title: "播放列表") {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(playlist) { item in
                        Button {
                            onActivity()
                            onSelectItem(item)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.id == currentItemID ? "speaker.wave.2.fill" : "play.fill")
                                    .frame(width: 24)
                                Text(item.name)
                                    .lineLimit(1)
                                Spacer()
                                if item.id == currentItemID {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .font(.callout)
                            .foregroundStyle(item.id == currentItemID ? Color.accentColor : .white)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(.white.opacity(0.12))
                    }
                }
            }
            .frame(maxHeight: 240)
        }
    }

    private func controlPanel<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.title3.bold())
                Spacer()
                Button {
                    onActivity()
                    panel = nil
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭面板")
            }
            content()
        }
        .padding(16)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private func sideButton(symbol: String, label: String, panel target: ManualControlPanel) -> some View {
        controlButton(symbol: symbol, label: label, size: 52, isSelected: panel == target) {
            togglePanel(target)
        }
    }

    private func controlButton(
        symbol: String,
        label: String,
        size: CGFloat,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.40, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(ManualGlassButtonStyle(isSelected: isSelected))
        .accessibilityLabel(label)
    }

    private func selectionTile(
        symbol: String,
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title2)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(ManualSelectionButtonStyle(isSelected: isSelected))
    }

    private func sliderRow(
        symbol: String,
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        valueText: @escaping (Int) -> String = { "\($0)" }
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 20)
            Text(title)
                .font(.callout)
                .frame(width: 72, alignment: .leading)
            Text(valueText(value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 42, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .tint(.blue)
            .accessibilityLabel(title)
            .accessibilityValue(valueText(value.wrappedValue))
        }
        .frame(height: 38)
    }

    private func layoutRow(symbol: String, title: String, layout: StereoLayout) -> some View {
        Button {
            updatePreference(\.stereoLayout, to: layout)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 24)
                Text(title)
                Spacer()
                if preferences.stereoLayout == layout {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func threeDModeRow(symbol: String, title: String, mode: VRThreeDMode) -> some View {
        Button {
            var copy = preferences
            copy.presentationMode = .threeD
            copy.threeDMode = mode
            preferences = copy
            onActivity()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 24)
                Text(title)
                Spacer()
                if preferences.threeDMode == mode {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var threeDEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.presentationMode == .threeD },
            set: { enabled in
                var copy = preferences
                copy.presentationMode = enabled ? .threeD : .flat
                preferences = copy
                onActivity()
            }
        )
    }

    private func updatePanoramaProjection(_ projection: VRProjection) {
        var copy = preferences
        copy.presentationMode = .panorama
        copy.projection = projection
        preferences = copy
        onActivity()
    }

    private var seekBinding: Binding<Double> {
        Binding(
            get: { displayedSeekPosition },
            set: { scrubState.update(to: $0, duration: duration) }
        )
    }

    private var displayedSeekPosition: Double {
        scrubState.displayedPosition(playbackPosition: position, duration: duration)
    }

    private func handleSeekEditingChanged(_ isEditing: Bool) {
        onActivity()
        if isEditing {
            scrubState.begin(at: position, duration: duration)
        } else if let target = scrubState.finish() {
            onSeek(target)
        }
    }

    private func intBinding(_ keyPath: WritableKeyPath<VRPlayerPreferences, Int>) -> Binding<Int> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { updatePreference(keyPath, to: $0) }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<VRPlayerPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { updatePreference(keyPath, to: $0) }
        )
    }

    private func updatePreference<Value>(
        _ keyPath: WritableKeyPath<VRPlayerPreferences, Value>,
        to value: Value
    ) {
        var copy = preferences
        copy[keyPath: keyPath] = value
        copy.normalize()
        preferences = copy
        onActivity()
    }

    private func togglePanel(_ target: ManualControlPanel) {
        onActivity()
        panel = panel == target ? nil : target
    }

    private var playbackRates: [Double] {
        [0.5, 0.75, 1, 1.25, 1.5, 2]
    }

    private func rateText(_ rate: Double) -> String {
        rate == rate.rounded() ? String(format: "%.0fx", rate) : String(format: "%.2gx", rate)
    }

    private func percentageText(_ value: Int) -> String {
        value == 0 ? "0%" : String(format: "%+d%%", value)
    }
}

private struct ManualGlassButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.blue : .white)
            .background(
                isSelected ? Color.blue.opacity(0.18) : Color.black.opacity(configuration.isPressed ? 0.88 : 0.68),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.blue : .white.opacity(0.10), lineWidth: isSelected ? 1.5 : 1)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct ManualSelectionButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.blue : .white.opacity(0.86))
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.blue : .clear, lineWidth: 1.5)
            }
    }
}

#if DEBUG
struct ManualControlsPreviewScreen: View {
    @State private var preferences = VRPlayerPreferences.default
    @State private var panel: ManualControlPanel?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        var initialPreferences = VRPlayerPreferences.default
        if arguments.contains("--manual-display-preview") {
            _panel = State(initialValue: .display)
        } else if arguments.contains("--manual-style-preview") {
            _panel = State(initialValue: .style)
        } else if arguments.contains("--manual-3d-preview") {
            initialPreferences.presentationMode = .threeD
            initialPreferences.threeDMode = .fill
            _panel = State(initialValue: .threeD)
        } else if arguments.contains("--manual-panorama-preview") {
            _panel = State(initialValue: .panorama)
        } else {
            _panel = State(initialValue: nil)
        }
        _preferences = State(initialValue: initialPreferences)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HStack(spacing: 28) {
                previewEye
                previewEye
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 52)

            ManualControlsOverlay(
                title: "video_[6K 全景 VR 视频] 无滤镜的冰川公路",
                isPlaying: true,
                position: 15,
                duration: 207,
                playlist: [],
                currentItemID: UUID(),
                preferences: $preferences,
                panel: $panel,
                onClose: {},
                onDismiss: {},
                onActivity: {},
                onRecenter: {},
                onPrevious: {},
                onPlayPause: {},
                onNext: {},
                onSeek: { _ in },
                onSelectItem: { _ in }
            )
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            OrientationManager.lockLandscape()
        }
    }

    private var previewEye: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color(red: 0.28, green: 0.38, blue: 0.44))
            .overlay {
                Image(systemName: "mountain.2.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.20))
                    .padding(34)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
