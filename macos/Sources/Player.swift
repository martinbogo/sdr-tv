import AVFoundation
import CoreMedia
import CoreVideo

/// Presents decoded frames and audio with correct timing. Video goes to an
/// AVSampleBufferDisplayLayer and audio to an AVSampleBufferAudioRenderer, both driven by one
/// render synchronizer whose timeline follows the broadcast timestamps (90 kHz PTS).
final class Player {
    let layer = AVSampleBufferDisplayLayer()
    private let audio = AVSampleBufferAudioRenderer()
    private let sync = AVSampleBufferRenderSynchronizer()
    private let lock = NSLock()

    private var started = false
    // 33-bit PTS unwrapping, separately for each stream
    private var lastRaw: [Int64?] = [nil, nil]
    private var wrapBase: [Int64] = [0, 0]
    private var latestPTS: Int64 = 0
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private var audioFormat: CMAudioFormatDescription?
    private var pendingSince: Date?

    /// How far behind the live broadcast playback runs, to absorb decode and delivery jitter.
    let latency: Int64 = 45_000                 // 0.5 s in 90 kHz ticks

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor.black
        sync.addRenderer(layer.sampleBufferRenderer)
        sync.addRenderer(audio)
    }

    var volume: Float {
        get { audio.volume }
        set { audio.volume = newValue }
    }

    var muted: Bool {
        get { audio.isMuted }
        set { audio.isMuted = newValue }
    }

    /// Drop everything queued (channel change).
    func flush() {
        lock.lock(); defer { lock.unlock() }
        sync.setRate(0, time: .zero)
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        audio.flush()
        started = false
        lastRaw = [nil, nil]
        wrapBase = [0, 0]
        pendingSince = nil
    }

    /// 33-bit PTS -> monotonic 64-bit ticks (stream 0 = video, 1 = audio).
    private func unwrap(_ raw: Int64, _ stream: Int) -> Int64 {
        let period: Int64 = 1 << 33
        let r = raw & (period - 1)
        if let last = lastRaw[stream] {
            let d = r - last
            if d < -period / 2 { wrapBase[stream] += period } else if d > period / 2 { wrapBase[stream] -= period }
        } else if let other = lastRaw[1 - stream] {
            // first sample of this stream: join the other stream's wrap epoch
            let o = other + wrapBase[1 - stream]
            wrapBase[stream] = o - (o & (period - 1))
            if r + wrapBase[stream] - o > period / 2 { wrapBase[stream] -= period }
            if o - (r + wrapBase[stream]) > period / 2 { wrapBase[stream] += period }
        }
        lastRaw[stream] = r
        return r + wrapBase[stream]
    }

    private func startIfNeeded(_ pts: Int64, isAudio: Bool) {
        if started { return }
        // Start the clock on the first audio (or on video if no audio shows up within a second).
        if !isAudio {
            if pendingSince == nil { pendingSince = Date() }
            if Date().timeIntervalSince(pendingSince!) < 1.0 { return }
        }
        sync.setRate(1, time: CMTime(value: pts - latency, timescale: 90_000))
        started = true
    }

    /// Keeps the audio device clock and the broadcast clock from drifting apart over hours.
    private func checkDrift() {
        guard started else { return }
        let now = sync.currentTime()
        guard now.isValid else { return }
        let lead = latestPTS - Int64(now.seconds * 90_000)
        if lead > 4 * 90_000 || lead < -90_000 {
            sync.setRate(1, time: CMTime(value: latestPTS - latency, timescale: 90_000))
        }
    }

    // MARK: video

    func video(y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
               yStride: Int, uvStride: Int, width: Int, height: Int, sarNum: Int, sarDen: Int, pts rawPTS: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard rawPTS != Int64.min else { return }
        let pts = unwrap(rawPTS, 0)
        latestPTS = max(latestPTS, pts)
        startIfNeeded(pts, isAudio: false)
        if pool == nil || poolW != width || poolH != height {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p; poolW = width; poolH = height
        }
        guard let pool else { return }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        // luma
        let yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let yDstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for r in 0..<height { (yDst + r * yDstStride).update(from: y + r * yStride, count: width) }
        // chroma: planar U and V -> interleaved UV
        let uvDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvDstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cw = width / 2, ch = height / 2
        for r in 0..<ch {
            let d = uvDst + r * uvDstStride, su = u + r * uvStride, sv = v + r * uvStride
            for x in 0..<cw { d[2 * x] = su[x]; d[2 * x + 1] = sv[x] }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        // colour and pixel shape: BT.709 for HD, BT.601 for SD; SD pixels are not square
        let hd = height >= 720
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                              hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                              hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        if sarNum > 0, sarDen > 0, sarNum != sarDen {
            let par: [String: Any] = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: sarNum,
                                      kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: sarDen]
            CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, par as CFDictionary, .shouldPropagate)
        }
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 90_000),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb { layer.sampleBufferRenderer.enqueue(sb) }
    }

    // MARK: audio

    func audio(stereo: UnsafePointer<Float>, frames: Int, rate: Int, pts rawPTS: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard rawPTS != Int64.min, frames > 0 else { return }
        let pts = unwrap(rawPTS, 1)
        latestPTS = max(latestPTS, pts)
        startIfNeeded(pts, isAudio: true)
        checkDrift()
        if audioFormat == nil || Int(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat!)!.pointee.mSampleRate) != rate {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                mBitsPerChannel: 32, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &audioFormat)
        }
        guard let audioFormat else { return }
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        CMBlockBufferReplaceDataBytes(with: stereo, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: frames,
            presentationTimeStamp: CMTime(value: pts, timescale: 90_000), packetDescriptions: nil,
            sampleBufferOut: &sb)
        if let sb { audio.enqueue(sb) }
    }
}
