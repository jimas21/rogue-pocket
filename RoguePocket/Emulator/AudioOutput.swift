import AVFoundation
import os

/// Plays the core's audio through AVAudioEngine.
///
/// The emulator (main thread) pushes interleaved stereo Int16 frames after each emulated frame, at the core's
/// current sample rate (32768, 65536, 131072 or 262144 Hz; Pokemon games switch it at runtime, see
/// src/gba/audio.c GBAAudioWriteSOUNDBIAS). The audio thread pulls from a ring buffer and resamples to the
/// hardware rate with linear interpolation. The step is nudged by up to 0.5 percent according to how full the
/// ring is, which absorbs the drift between the display clock that paces emulation and the audio clock.
/// The audio thread never calls into mGBA.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []

    // Shared with the audio thread; every access is under `lock`.
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private static let capacity = 1 << 17 // frames; power of two
    private static let mask = capacity - 1
    private let ring: UnsafeMutablePointer<Int16>
    private var head = 0 // absolute frame counters; ring index is (n & mask)
    private var tail = 0
    private var frac = 0.0
    private var inRate = 32768.0
    private var outRate = 48000.0
    private var primed = false
    private var underruns = 0
    private var muted = false

    private var wantsRunning = false

    init() {
        let newLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        newLock.initialize(to: os_unfair_lock())
        let newRing = UnsafeMutablePointer<Int16>.allocate(capacity: AudioOutput.capacity * 2)
        newRing.initialize(repeating: 0, count: AudioOutput.capacity * 2)
        lock = newLock
        ring = newRing

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // Route or hardware rate changed (headphones, Bluetooth): rebuild the graph at the new rate.
            if let self = self, self.wantsRunning { self.start() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.wantsRunning,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.start()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        engine.stop()
        lock.deallocate()
        ring.deallocate()
    }

    // MARK: control (main thread)

    /// (Re)builds the audio graph and starts it. Safe to call repeatedly.
    func start() {
        wantsRunning = true
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback ignores the silent switch on purpose: a muted phone would look like "no sound" in a test.
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            NSLog("RoguePocket audio: session setup failed: \(error)")
        }

        engine.stop()
        if let old = sourceNode {
            engine.detach(old)
            sourceNode = nil
        }
        var rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if rate < 8000 { rate = session.sampleRate }
        if rate < 8000 { rate = 48000 }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false) else {
            NSLog("RoguePocket audio: could not make a \(rate) Hz stereo format")
            return
        }
        os_unfair_lock_lock(lock)
        outRate = rate
        primed = false
        os_unfair_lock_unlock(lock)

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            self?.render(frames: Int(frameCount), list: audioBufferList)
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("RoguePocket audio: engine start failed: \(error)")
        }
    }

    func pause() {
        wantsRunning = false
        engine.pause()
    }

    func setMuted(_ value: Bool) {
        os_unfair_lock_lock(lock)
        muted = value
        os_unfair_lock_unlock(lock)
    }

    /// Drops everything buffered (after a reset, a benchmark or a pause) so playback re-primes cleanly.
    func flush() {
        os_unfair_lock_lock(lock)
        head = 0
        tail = 0
        frac = 0
        primed = false
        os_unfair_lock_unlock(lock)
    }

    /// Milliseconds of audio waiting in the ring, and how many times playback ran dry.
    func status() -> (bufferedMs: Double, underruns: Int, hardwareRate: Double) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let ms = inRate > 0 ? Double(tail - head) / inRate * 1000.0 : 0
        return (ms, underruns, outRate)
    }

    // MARK: data in (main thread)

    /// `samples` holds `frames` interleaved stereo frames at `rate` Hz.
    func push(_ samples: UnsafePointer<Int16>, frames: Int, rate: Int) {
        guard frames > 0 else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if rate > 0 { inRate = Double(rate) }
        let cap = AudioOutput.capacity
        if tail - head + frames > cap { head = tail + frames - cap } // overflow: drop the oldest
        var t = tail
        for i in 0..<frames {
            let idx = (t & AudioOutput.mask) * 2
            ring[idx] = samples[i * 2]
            ring[idx + 1] = samples[i * 2 + 1]
            t += 1
        }
        tail = t
    }

    // MARK: data out (audio thread)

    private func render(frames: Int, list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count >= 1, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let right: UnsafeMutablePointer<Float>? = buffers.count >= 2 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        let target = max(512, Int(inRate * 0.05)) // aim for about 50 ms buffered
        if !primed && tail - head >= target { primed = true }
        if !primed || muted {
            for i in 0..<frames {
                left[i] = 0
                right?[i] = 0
            }
            return
        }
        if tail - head > target * 6 { // far behind (after a stall): jump forward instead of lagging
            head = tail - target
            frac = 0
        }
        let fill = Double(tail - head - target) / Double(target) // positive when too full
        let correction = 1.0 + max(-0.005, min(0.005, fill * 0.005))
        let step = inRate / outRate * correction

        let mask = AudioOutput.mask
        for i in 0..<frames {
            if tail - head < 2 { // ran dry
                for j in i..<frames {
                    left[j] = 0
                    right?[j] = 0
                }
                underruns += 1
                primed = false
                return
            }
            let a = (head & mask) * 2
            let b = ((head + 1) & mask) * 2
            let f = Float(frac)
            let l = (Float(ring[a]) * (1 - f) + Float(ring[b]) * f) * (1.0 / 32768.0)
            let r = (Float(ring[a + 1]) * (1 - f) + Float(ring[b + 1]) * f) * (1.0 / 32768.0)
            if let right = right {
                left[i] = l
                right[i] = r
            } else {
                left[i] = (l + r) * 0.5
            }
            frac += step
            let advance = Int(frac)
            if advance > 0 {
                head += advance
                frac -= Double(advance)
            }
        }
    }
}
