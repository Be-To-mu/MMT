import SwiftUI
import Accelerate
import MMTCore

/// Step 2–3 debug screen: proves FOA capture works and points an arrow at the last
/// loud sound (clap test / axis calibration). Replaced by the bird flow later.
struct DirectionDebugView: View {
    @State private var heading = HeadingService()
    @State private var capture = SpatialCaptureService()
    @State private var levels: [Float] = [0, 0, 0, 0]
    @State private var lastEstimate: DirectionEstimate?
    @State private var targetWorld: SIMD3<Double>?
    @State private var error: String?

    private let estimator = DOAEstimator()

    var body: some View {
        VStack(spacing: 24) {
            if let error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            levelMeters

            ZStack {
                Circle().stroke(.secondary.opacity(0.3), lineWidth: 2)
                if let target = targetWorld,
                   let angle = SpatialGeometry.arrowAngle(towards: target,
                                                         deviceToWorld: heading.deviceToWorld) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 120, weight: .bold))
                        .rotationEffect(.degrees(angle))
                        .animation(.easeOut(duration: 0.15), value: angle)
                } else {
                    Text("Clap or make a sound").foregroundStyle(.secondary)
                }
            }
            .frame(width: 280, height: 280)

            if let est = lastEstimate, let target = targetWorld {
                VStack {
                    Text(String(format: "Device az %.0f°  el %.0f°", est.azimuth, est.elevation))
                    Text(String(format: "Bearing %.0f°  spread %.0f°  conf %.2f",
                                SpatialGeometry.compassBearing(target), est.spread, est.confidence))
                }
                .font(.footnote.monospaced())
            }
        }
        .padding()
        .task { await run() }
    }

    private var levelMeters: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(Array(zip(["W", "Y", "Z", "X"], levels)), id: \.0) { name, level in
                VStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.tint)
                        .frame(width: 28, height: CGFloat(min(1, level * 8)) * 100 + 2)
                    Text(name).font(.caption.monospaced())
                }
            }
        }
        .frame(height: 130, alignment: .bottom)
    }

    private func run() async {
        heading.start()
        do {
            try await capture.start()
        } catch {
            self.error = error.localizedDescription
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            let frames = Int(capture.sampleRate / 2)
            guard let window = capture.buffer.latest(frameCount: frames) else { continue }
            levels = [window.w, window.y, window.z, window.x].map { vDSP.rootMeanSquare($0) }
            // Only re-aim on clearly loud events.
            guard levels[0] > 0.02 else { continue }
            let est = await Task.detached { estimator.estimate(window, band: 300...12_000) }.value
            guard let est, est.confidence > 0.3 else { continue }
            lastEstimate = est
            targetWorld = SpatialGeometry.worldVector(foa: est.vector,
                                                      deviceToWorld: heading.deviceToWorld)
        }
        capture.stop()
        heading.stop()
    }
}
