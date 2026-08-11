import CoreMotion
import Foundation
import simd

nonisolated final class MotionHeadTracker: @unchecked Sendable {
    static let shared = MotionHeadTracker()

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "cxc.vr-player.motion"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let lock = NSLock()
    private var latestAttitude = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var referenceAttitude: simd_quatf?

    private init() {}

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        lock.lock()
        referenceAttitude = nil
        lock.unlock()
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        manager.startDeviceMotionUpdates(
            using: .xArbitraryCorrectedZVertical,
            to: queue
        ) { [weak self] motion, _ in
            guard let self, let quaternion = motion?.attitude.quaternion else { return }
            let attitude = simd_quatf(
                ix: Float(quaternion.x),
                iy: Float(quaternion.y),
                iz: Float(quaternion.z),
                r: Float(quaternion.w)
            )
            self.lock.lock()
            self.latestAttitude = attitude
            if self.referenceAttitude == nil {
                self.referenceAttitude = attitude
            }
            self.lock.unlock()
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    func recenter() {
        lock.lock()
        referenceAttitude = latestAttitude
        lock.unlock()
    }

    func viewMatrix() -> simd_float4x4 {
        lock.lock()
        let attitude = latestAttitude
        let reference = referenceAttitude ?? attitude
        lock.unlock()

        return Self.viewMatrix(attitude: attitude, reference: reference)
    }

    static func viewMatrix(
        attitude: simd_quatf,
        reference: simd_quatf
    ) -> simd_float4x4 {
        let relative = attitude * reference.inverse
        return simd_float4x4(relative.inverse)
    }
}
