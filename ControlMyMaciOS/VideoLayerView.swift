import AVFoundation
import SwiftUI
import UIKit

/// Hosts an `AVSampleBufferDisplayLayer` as the view's backing layer, so
/// there's no second layer to keep in sync during rotation or resize.
final class SampleBufferHostView: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer

    init(layer displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        self.layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The layer is positioned manually, so no implicit animation —
        // otherwise every rotation slides the video across the screen.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

struct VideoLayerView: UIViewRepresentable {
    let renderer: VideoRenderer

    func makeUIView(context: Context) -> SampleBufferHostView {
        SampleBufferHostView(layer: renderer.layer)
    }

    func updateUIView(_ uiView: SampleBufferHostView, context: Context) {}
}
