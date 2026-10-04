import CoreVideo
import Foundation
import VideoToolbox

/// Clearer standard-definition pictures on large screens: Apple's real-time super-resolution
/// (VideoToolbox, macOS 26) doubles 480i/480p frames (720x480 -> 1440x960, ~2 ms a frame) before the
/// display scales them to the window, instead of the display stretching 480 lines four times over.
/// Media thread only.
final class SDEnhancer {
    /// Settings switch.
    var enabled = true
    /// Height of the picture on screen, in pixels (enhance only when it is well above the source).
    var displayHeight: CGFloat = 2160

    private var processor: AnyObject?         // VTFrameProcessor (macOS 26)
    private var size = (w: 0, h: 0)
    private var outPool: CVPixelBufferPool?
    private var failed = false
    /// Frames enhanced, and frames shown unenhanced because the scaler was too slow (diagnostics).
    private(set) var enhanced = 0, slow = 0

    static var available: Bool {
        if #available(macOS 26.0, *) { return VTLowLatencySuperResolutionScalerConfiguration.isSupported }
        return false
    }

    /// The enhanced frame, or nil to show the source as it is.
    func process(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        guard enabled, !failed else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard h < 720, displayHeight > CGFloat(h) * 1.4 else { return nil }
        if #available(macOS 26.0, *) { return upscale(pb, w, h) }
        return nil
    }

    @available(macOS 26.0, *)
    private func upscale(_ pb: CVPixelBuffer, _ w: Int, _ h: Int) -> CVPixelBuffer? {
        if size != (w, h) || processor == nil {
            (processor as? VTFrameProcessor)?.endSession()
            processor = nil; outPool = nil; size = (w, h)
            guard VTLowLatencySuperResolutionScalerConfiguration.isSupported,
                  VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: w, frameHeight: h).contains(2.0) else { return nil }
            let cfg = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: w, frameHeight: h, scaleFactor: 2.0)
            let p = VTFrameProcessor()
            do { try p.startSession(configuration: cfg) } catch { failed = true; return nil }
            var attrs = cfg.destinationPixelBufferAttributes
            attrs[kCVPixelBufferWidthKey as String] = w * 2
            attrs[kCVPixelBufferHeightKey as String] = h * 2
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            processor = p; outPool = pool
            if ProcessInfo.processInfo.environment["ATSC_DEBUG"] != nil {
                FileHandle.standardError.write("enhance: super-resolution \(w)x\(h) -> \(w * 2)x\(h * 2) for a \(Int(displayHeight))-pixel-high picture\n".data(using: .utf8)!)
            }
        }
        guard let p = processor as? VTFrameProcessor, let outPool else { return nil }
        var outOpt: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, outPool, &outOpt) == kCVReturnSuccess, let out = outOpt,
              let src = VTFrameProcessorFrame(buffer: pb, presentationTimeStamp: .zero),
              let dst = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: .zero) else { return nil }
        let params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: src, destinationFrame: dst)
        let done = DispatchSemaphore(value: 0)
        var ok = false
        p.process(parameters: params) { _, err in ok = err == nil; done.signal() }
        // never hold up the picture: a frame that takes too long is shown unenhanced
        guard done.wait(timeout: .now() + .milliseconds(30)) == .success, ok else { slow += 1; return nil }
        enhanced += 1
        return out
    }
}
