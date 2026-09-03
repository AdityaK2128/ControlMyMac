import AVFoundation
import CoreMedia
import UIKit

/// Owns the `AVSampleBufferDisplayLayer` and feeds it decoded-on-arrival
/// frames.
///
/// No `VTDecompressionSession` here — the layer decodes internally.
final class VideoRenderer {

    let layer = AVSampleBufferDisplayLayer()

    /// Raised when the layer wedges and needs a fresh IDR to recover: a
    /// flush discards the reference frame, so nothing decodes until the
    /// next keyframe.
    var onNeedsKeyframe: (() -> Void)?

    private(set) var framesEnqueued = 0
    private(set) var framesDropped = 0
    private(set) var recoveries = 0

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    // MARK: - Health
    //
    // On iOS 17+ frames go into `layer.sampleBufferRenderer`, which
    // carries its own status. Checking `layer.status` instead — as this
    // used to — means a failure on the path actually in use is never
    // seen, so the recovery below never runs and the picture stays black
    // for the rest of the session.

    private var isFailed: Bool {
        if #available(iOS 17.0, *) {
            return layer.sampleBufferRenderer.status == .failed
        }
        return layer.status == .failed
    }

    private var failureDescription: String {
        let error: Error?
        if #available(iOS 17.0, *) {
            error = layer.sampleBufferRenderer.error
        } else {
            error = layer.error
        }
        return error?.localizedDescription ?? "unknown"
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // Without a control timebase the layer would hold frames until
        // its clock reached their PTS — which never happens, so nothing
        // would ever appear. For a remote desktop the newest frame is
        // always the one we want, so show each on arrival.
        setDisplayImmediately(sampleBuffer)

        if isFailed {
            recover(because: "renderer failed: \(failureDescription)")
            return
        }

        // Set after the app returns from the background, where the
        // decoder's session is torn down. Enqueuing into it without a
        // flush renders nothing, silently.
        if layer.requiresFlushToResumeDecoding {
            recover(because: "decoder needs a flush after backgrounding")
            return
        }

        if #available(iOS 17.0, *) {
            layer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            layer.enqueue(sampleBuffer)
        }
        framesEnqueued += 1
    }

    /// The stream's format changed — new resolution, new parameter sets.
    ///
    /// The layer has to be flushed across that boundary. Feeding it
    /// buffers with a new format description while it still holds the
    /// old one is a reliable way to wedge it permanently.
    func prepareForFormatChange() {
        flush()
        onNeedsKeyframe?()
    }

    func reset() {
        flush()
        framesEnqueued = 0
        framesDropped = 0
        recoveries = 0
    }

    private func recover(because reason: String) {
        Log.warn("display layer: \(reason) — flushing")
        framesDropped += 1
        recoveries += 1
        flush()
        // A flush drops the reference frame, so nothing decodes until
        // the next IDR. Ask for one rather than waiting for the GOP.
        onNeedsKeyframe?()
    }

    private func flush() {
        if #available(iOS 17.0, *) {
            layer.sampleBufferRenderer.flush()
        } else {
            layer.flushAndRemoveImage()
        }
    }

    private func setDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0 else { return }

        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}
