import AVFoundation
import CoreMedia
import CoreImage
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
    private var latestAudioPTS: Int64 = 0
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private var audioFormat: CMAudioFormatDescription?
    private var pendingSince: Date?

    /// Display aspect ratio (width / height) of the picture, reported once it has been stable
    /// for ~15 frames so a stray frame cannot make the picture jump. Called on the main thread.
    var onAspect: ((CGFloat) -> Void)?

    /// The first picture after a channel change is on screen (main thread).
    var onFirstPicture: (() -> Void)?

    /// Caption screens (JSON) queued with their video time; shown when playback reaches them.
    var onCaption: ((String) -> Void)?
    private var captionQueue: [(pts: Int64, json: String)] = []
    private var captionTimer: Timer?
    private var shownAspect: CGFloat = 16.0 / 9.0
    private var candidateAspect: CGFloat = 0
    private var candidateCount = 0
    private var fmtDesc: CMVideoFormatDescription?
    /// How far behind the live broadcast playback runs, to absorb decode and delivery jitter. Starts
    /// small so a channel change plays quickly; grows (up to 1 s) if audio ever arrives too late.
    private(set) var latency: Int64 = 36_000     // 0.4 s in 90 kHz ticks
    private var stillShown = false
    private var firstFrameOnScreen = false
    // AVFoundation is never called while `lock` is held (the main thread takes the lock on every
    // channel change and for captions): clock changes and samples are collected under the lock and
    // applied after it is released.
    private var pendingClock: (rate: Float, time: CMTime)?
    private var pendingVideo: [CMSampleBuffer] = []
    private var pendingAudio: CMSampleBuffer?
    private var clockNow = CMTime.invalid           // the synchronizer's time, read before locking
    private var epoch = 0                           // bumped by flush()

    /// Call with `lock` held: releases it, then applies what was collected.
    private func unlockAndApply() {
        let c = pendingClock, v = pendingVideo, a = pendingAudio, e = epoch
        pendingClock = nil; pendingVideo.removeAll(); pendingAudio = nil
        lock.unlock()
        guard e == epoch else { return }             // a channel change came in between: drop all of it
        if let c { sync.setRate(c.rate, time: c.time) }
        for sb in v { layer.sampleBufferRenderer.enqueue(sb) }
        if let a { audio.enqueue(a) }
    }
    private var flushedAt = Date()
    private let debug = ProcessInfo.processInfo.environment["ATSC_DEBUG"] != nil
    private func note(_ what: String) {
        if debug { FileHandle.standardError.write(String(format: "player: %@ %.0f ms after the channel change\n", what, Date().timeIntervalSince(flushedAt) * 1000).data(using: .utf8)!) }
    }

    init() {
        layer.videoGravity = .resize             // the view sizes the layer to the right shape
        layer.backgroundColor = CGColor.black
        sync.addRenderer(layer.sampleBufferRenderer)
        sync.addRenderer(audio)
    }

    // MARK: observation (diagnostics and tests)

    /// The playback clock in 90 kHz ticks, or nil while it is not running.
    var clockTicks: Int64? {
        let t = sync.currentTime()
        return t.isValid && sync.rate != 0 ? Int64(t.seconds * 90_000) : nil
    }
    /// How far playback runs behind live (90 kHz ticks).
    var bufferTicks: Int64 { lock.lock(); defer { lock.unlock() }; return latency }
    /// Video frames handed over since the last flush, and how many of them were already past due.
    var videoFrameCounts: (total: Int, late: Int) { lock.lock(); defer { lock.unlock() }; return (framesSinceFlush, lateSinceFlush) }
    private var framesSinceFlush = 0, lateSinceFlush = 0
    private var newestPicture: CVPixelBuffer?
    /// Super-resolution for standard definition on large screens (media thread).
    let enhancer = SDEnhancer()
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// A small copy (up to 960 wide, square pixels at `aspect`) of the newest picture, for showing
    /// dimmed while the channel is tuned next time.
    func snapshot(aspect: CGFloat) -> CGImage? {
        lock.lock(); let pb = newestPicture; lock.unlock()
        guard let pb else { return nil }
        let img = CIImage(cvPixelBuffer: pb)
        let w = min(960, CGFloat(CVPixelBufferGetWidth(pb) * 2)), h = (w / max(aspect, 0.5)).rounded()
        let scaled = img.transformed(by: CGAffineTransform(scaleX: w / img.extent.width, y: h / img.extent.height))
        return Self.ciContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: w, height: h))
    }
    /// Video frames that were far ahead of the clock (would sit off screen) since the last flush.
    var farAheadFrames: Int { lock.lock(); defer { lock.unlock() }; return farAheadSinceFlush }
    private var farAheadSinceFlush = 0
    // Video timestamps can jump on their own (an inserted ad restarts the encoder's clock). The clock
    // follows audio, so such frames would never come due: the picture freezes while sound plays on.
    private var videoShift: Int64 = 0              // added to video timestamps after such a jump
    private var strayRun = 0                       // consecutive video frames far from the clock

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
        lock.lock()
        epoch += 1
        latestPTS = 0; latestAudioPTS = 0          // stations' clocks are unrelated: nothing carries over
        latency = 36_000                           // each channel earns its own buffer
        framesSinceFlush = 0; lateSinceFlush = 0; farAheadSinceFlush = 0
        newestPicture = nil
        videoShift = 0; strayRun = 0
        pendingClock = nil; pendingVideo.removeAll(); pendingAudio = nil
        started = false
        stillShown = false
        firstFrameOnScreen = false
        flushedAt = Date()
        lastRaw = [nil, nil]
        wrapBase = [0, 0]
        candidateCount = 0
        fmtDesc = nil
        captionQueue.removeAll()
        DispatchQueue.main.async { [weak self] in self?.onCaption?("{\"regions\":[]}") }
        pendingSince = nil
        lock.unlock()
        sync.setRate(0, time: .zero)
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        audio.flush()
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
            if !stillShown {
                // show the first picture right away as a still: the clock (paused) is put at its time
                stillShown = true
                pendingClock = (0, CMTime(value: pts, timescale: 90_000))
            }
            if pendingSince == nil { pendingSince = Date() }
            if Date().timeIntervalSince(pendingSince!) < 1.0 { return }
        }
        pendingClock = (1, CMTime(value: pts - latency, timescale: 90_000))
        started = true
        note(isAudio ? "playing (sound)" : "playing (no sound)")
    }

    /// Keeps the audio device clock and the broadcast clock from drifting apart over hours.
    private func checkDrift() {
        guard started, pendingClock == nil else { return }   // the clock is being set right now
        let now = clockNow
        guard now.isValid else { return }
        // audio's own timeline: video is sent up to ~1.5 s ahead of its time and must not pull the clock
        guard latestAudioPTS > 0 else { return }
        let lead = latestAudioPTS - Int64(now.seconds * 90_000)
        if lead > 4 * 90_000 || lead < -90_000 {
            pendingClock = (1, CMTime(value: latestAudioPTS - latency, timescale: 90_000))
            if debug { FileHandle.standardError.write("player: clock re-anchored to audio (was \(lead / 90) ms off)\n".data(using: .utf8)!) }
        }
    }

    // MARK: captions

    /// Called on the media thread with the video PTS of the frame the caption change belongs to.
    func caption(json: String, pts raw: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard raw != Int64.min else { return }
        // map into the video stream's unwrapped timeline without disturbing its wrap state
        let period: Int64 = 1 << 33
        var t = (raw & (period - 1)) + wrapBase[0]
        if let last = lastRaw[0] {
            let lastT = last + wrapBase[0]
            if t - lastT > period / 2 { t -= period } else if lastT - t > period / 2 { t += period }
        }
        captionQueue.append((t, json))
        if captionQueue.count > 400 { captionQueue.removeFirst(captionQueue.count - 400) }
        if captionTimer == nil {
            DispatchQueue.main.async { [weak self] in self?.startCaptionClock() }
        }
    }

    private func startCaptionClock() {
        guard captionTimer == nil else { return }
        captionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.releaseCaptions() }
    }

    private func releaseCaptions() {
        let t = sync.currentTime()                      // outside the lock
        lock.lock()
        guard started, t.isValid else { lock.unlock(); return }
        let now = Int64(t.seconds * 90_000)
        var due: String?
        while let first = captionQueue.first, first.pts <= now {
            due = first.json
            captionQueue.removeFirst()
        }
        lock.unlock()
        if let due { onCaption?(due) }
    }

    // MARK: video

    func video(y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
               yStride: Int, uvStride: Int, width: Int, height: Int, sarNum: Int, sarDen: Int, pts rawPTS: Int64) {
        guard rawPTS != Int64.min else { return }
        // the picture (pools and buffers belong to the media thread: no lock needed)
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
        // standard definition on a large screen: Apple's super-resolution, 2x (nil: show as is)
        let shown = enhancer.process(pb) ?? pb
        let t = sync.currentTime()
        lock.lock(); defer { unlockAndApply() }
        clockNow = t
        var pts = unwrap(rawPTS, 0) + videoShift
        if started, clockNow.isValid {
            // video normally runs 0-2 s ahead of the clock; persistently far outside that, it has
            // jumped: shift it back into line with the audio-driven clock (half a second ahead)
            let lead = pts - Int64(clockNow.seconds * 90_000)
            if lead > 6 * 90_000 { farAheadSinceFlush += 1 }
            if lead > 6 * 90_000 || lead < -2 * 90_000 { strayRun += 1 } else { strayRun = 0 }
            if strayRun >= 15 {
                let fix = Int64(clockNow.seconds * 90_000) + 45_000 - pts
                videoShift += fix; pts += fix; strayRun = 0
                if debug { FileHandle.standardError.write("player: video timestamps jumped \(-fix / 90) ms; realigned\n".data(using: .utf8)!) }
            }
        }
        latestPTS = max(latestPTS, pts)
        startIfNeeded(pts, isAudio: false)
        // colour and pixel shape: BT.709 for HD, BT.601 for SD; SD pixels are not square
        let hd = height >= 720
        CVBufferSetAttachment(shown, kCVImageBufferYCbCrMatrixKey,
                              hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(shown, kCVImageBufferColorPrimariesKey,
                              hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        CVBufferSetAttachment(shown, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        // display shape = frame size x pixel aspect; applied by sizing the layer, not by buffer tags
        let par = sarNum > 0 && sarDen > 0 ? CGFloat(sarNum) / CGFloat(sarDen) : 1
        let aspect = (CGFloat(width) * par / CGFloat(height) * 1000).rounded() / 1000
        if aspect == candidateAspect { candidateCount += 1 } else { candidateAspect = aspect; candidateCount = 1 }
        if candidateCount == 15, aspect != shownAspect {
            shownAspect = aspect
            DispatchQueue.main.async { [weak self] in self?.onAspect?(aspect) }
        }
        if fmtDesc == nil || !CMVideoFormatDescriptionMatchesImageBuffer(fmtDesc!, imageBuffer: shown) {
            fmtDesc = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: shown, formatDescriptionOut: &fmtDesc)
        }
        guard let fmt = fmtDesc else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 90_000),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: shown, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        if !firstFrameOnScreen, let fmt = fmtDesc {
            // the first picture after a channel change goes up now, not when the clock reaches it:
            // a copy timed at the clock's current position, then the frame itself at its own time
            firstFrameOnScreen = true
            let now = clockNow
            if started, now.isValid, pts > Int64(now.seconds * 90_000) + 4_500 {
                var t = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
                var early: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: shown, formatDescription: fmt,
                                                         sampleTiming: &t, sampleBufferOut: &early)
                if let early { pendingVideo.append(early) }
            }
            note("first picture on screen")
            DispatchQueue.main.async { [weak self] in self?.onFirstPicture?() }
        }
        if let sb { pendingVideo.append(sb); newestPicture = shown }
        if started, clockNow.isValid {
            framesSinceFlush += 1
            if pts < Int64(clockNow.seconds * 90_000) { lateSinceFlush += 1 }
        }
        if debug, started {
            let now = clockNow
            if now.isValid {
                let lead = Double(pts - Int64(now.seconds * 90_000)) / 90
                leadMin = min(leadMin, lead); if lead < 0 { lateFrames += 1 }; leadFrames += 1
                if Date().timeIntervalSince(leadReport) > 2 {
                    FileHandle.standardError.write(String(format: "player: video lead min %.0f ms, %d of %d frames late, buffer %lld ms\n", leadMin, lateFrames, leadFrames, latency / 90).data(using: .utf8)!)
                    leadMin = 1e9; lateFrames = 0; leadFrames = 0; leadReport = Date()
                }
            }
        }
    }
    private var leadMin = 1e9, lateFrames = 0, leadFrames = 0, leadReport = Date()

    // MARK: audio

    func audio(stereo: UnsafePointer<Float>, frames: Int, rate: Int, pts rawPTS: Int64) {
        let t = sync.currentTime()
        lock.lock(); defer { unlockAndApply() }
        clockNow = t
        guard rawPTS != Int64.min, frames > 0 else { return }
        let pts = unwrap(rawPTS, 1)
        latestPTS = max(latestPTS, pts)
        latestAudioPTS = pts
        startIfNeeded(pts, isAudio: true)
        checkDrift()
        // audio arriving with less than 40 ms to spare will underrun: run further behind live
        if started, latency < 90_000 {
            let now = clockNow
            if now.isValid, pts - Int64(now.seconds * 90_000) < 3_600 {
                latency = min(90_000, latency + 18_000)
                if debug { FileHandle.standardError.write("player: audio nearly late, buffer now \(latency * 1000 / 90_000) ms\n".data(using: .utf8)!) }
                pendingClock = (1, CMTime(value: pts - latency, timescale: 90_000))   // audio's own time: video runs ahead
            }
        }
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
        if let sb { pendingAudio = sb }
    }
}
