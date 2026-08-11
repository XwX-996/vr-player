import AVFAudio
import MediaPlayer
import Observation
import SwiftUI

@MainActor
@Observable
final class SystemVolumeController: NSObject {
    private(set) var volume: Double
    @ObservationIgnored private let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    @ObservationIgnored private var observation: NSKeyValueObservation?

    override init() {
        volume = Double(AVAudioSession.sharedInstance().outputVolume)
        super.init()
        volumeView.alpha = 0.001
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.initial, .new]) { [weak self] session, _ in
            Task { @MainActor [weak self] in
                self?.volume = Double(session.outputVolume)
            }
        }
    }

    func setVolume(_ value: Double) {
        let clamped = Float(min(max(value, 0), 1))
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.setValue(clamped, animated: false)
        slider.sendActions(for: .valueChanged)
        volume = Double(clamped)
    }

    fileprivate func hostedView() -> MPVolumeView {
        volumeView
    }
}

@MainActor
@Observable
final class ScreenBrightnessController {
    private(set) var brightness: Double = 0.5
    @ObservationIgnored private weak var screen: UIScreen?

    func attach(to screen: UIScreen?) {
        guard let screen else { return }
        self.screen = screen
        brightness = Double(screen.brightness)
    }

    func setBrightness(_ value: Double) {
        guard let screen else { return }
        let clamped = min(max(value, 0), 1)
        screen.brightness = CGFloat(clamped)
        brightness = clamped
    }
}

private final class ScreenBrightnessHostUIView: UIView {
    weak var controller: ScreenBrightnessController?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        controller?.attach(to: window?.windowScene?.screen)
    }
}

struct ScreenBrightnessHostView: UIViewRepresentable {
    let controller: ScreenBrightnessController

    func makeUIView(context: Context) -> UIView {
        let view = ScreenBrightnessHostUIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.controller = controller
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.attach(to: uiView.window?.windowScene?.screen)
    }
}

struct SystemVolumeHostView: UIViewRepresentable {
    let controller: SystemVolumeController

    func makeUIView(context: Context) -> MPVolumeView {
        controller.hostedView()
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
