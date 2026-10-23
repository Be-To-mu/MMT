import SwiftUI
import MMTCore

/// Debug screen: proves FOA capture works and points a 2D arrow at the last loud sound
/// (clap test / axis calibration).
struct DirectionDebugView: View {
    let tracker: DirectionTracker

    var body: some View {
        VStack(spacing: 24) {
            if let error = tracker.error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            levelMeters

            ZStack {
                Circle().stroke(.secondary.opacity(0.3), lineWidth: 2)
                if let target = tracker.targetWorld,
                   let angle = SpatialGeometry.arrowAngle(towards: target,
                                                         deviceToWorld: tracker.heading.deviceToWorld) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 120, weight: .bold))
                        .rotationEffect(.degrees(angle))
                        .animation(.easeOut(duration: 0.15), value: angle)
                } else {
                    Text("Clap or make a sound").foregroundStyle(.secondary)
                }
            }
            .frame(width: 280, height: 280)

            if let est = tracker.lastEstimate, let bearing = tracker.targetBearing {
                VStack {
                    Text(String(format: "Device az %.0f°  el %.0f°", est.azimuth, est.elevation))
                    Text(String(format: "Bearing %.0f°  spread %.0f°  conf %.2f",
                                bearing, est.spread, est.confidence))
                }
                .font(.footnote.monospaced())
            }
        }
        .padding()
    }

    private var levelMeters: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(Array(zip(["W", "Y", "Z", "X"], tracker.levels)), id: \.0) { name, level in
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
}
