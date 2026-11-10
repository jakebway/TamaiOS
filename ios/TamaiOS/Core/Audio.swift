import AVFoundation
import UIKit
import os

/// Plays the toy's buzzer. The emulator thread pushes 44.1 kHz samples into a
/// ring buffer; the audio thread pulls them. A small cushion is kept against
/// dropouts, and extra delay is trimmed so beeps stay in time with the screen.
final class AudioOut {
    static let rate = 44100.0
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode!
    private let cap = 44100 * 2
    private var ring: UnsafeMutablePointer<Float>
    private var head = 0, count = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var priming = true
    var muted = false
    private var foregroundAudible = false
    var minFill = 0.05
    var maxFill = 0.12
    private(set) var underruns = 0
    private(set) var started = false
    var backgroundMode = true

    init() {
        ring = .allocate(capacity: cap)
        ring.initialize(repeating: 0, count: cap)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        foregroundAudible = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setForegroundAudible(false) }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.setForegroundAudible(false) }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setForegroundAudible(true) }

        let fmt = AVAudioFormat(standardFormatWithSampleRate: AudioOut.rate, channels: 1)!
        node = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frames, abl -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = bufs[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.pull(out, Int(frames))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let type = AVAudioSession.InterruptionType(rawValue: raw)
            if type == .ended { self.restart() }
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        }
    }

    private func setForegroundAudible(_ active: Bool) {
        os_unfair_lock_lock(lock)
        foregroundAudible = active; head = 0; count = 0; priming = true
        os_unfair_lock_unlock(lock)
    }
    var foregroundPlaybackAllowed: Bool {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return foregroundAudible && !muted
    }

    private func pull(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        os_unfair_lock_lock(lock)
        if priming && Double(count) >= minFill * AudioOut.rate { priming = false }
        var i = 0
        if !priming {
            while i < n && count > 0 {
                out[i] = ForegroundPlaybackPolicy.allowed(soundEnabled: !muted, foreground: foregroundAudible) ? ring[head] : 0
                head = (head + 1) % cap
                count -= 1
                i += 1
            }
            if i < n { priming = true; underruns += 1 }
        }
        os_unfair_lock_unlock(lock)
        while i < n { out[i] = 0; i += 1 }
    }

    func push(_ s: UnsafePointer<Int16>, _ n: Int) {
        guard n > 0 else { return }
        os_unfair_lock_lock(lock)
        // Background output is silent: skip conversion and speaker-buffer writes.
        guard foregroundAudible else {
            os_unfair_lock_unlock(lock)
            return
        }
        for k in 0..<n {
            if count == cap { head = (head + 1) % cap; count -= 1 }
            ring[(head + count) % cap] = Float(s[k]) / 32768.0
            count += 1
        }
        let high = Int(maxFill * AudioOut.rate), low = Int(minFill * AudioOut.rate)
        if count > high {
            let drop = count - low
            head = (head + drop) % cap
            count -= drop
        }
        os_unfair_lock_unlock(lock)
    }

    /// Drop whatever is waiting to be played.
    func flush() {
        os_unfair_lock_lock(lock)
        head = 0; count = 0; priming = true
        os_unfair_lock_unlock(lock)
    }

    var queued: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return count
    }

    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("TamaiOS audio session configuration failed: %@", error.localizedDescription)
        }
    }

    func start() {
        configureSession()
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start(); started = true } catch { started = false }
        }
    }

    func stop() {
        engine.pause()
        started = false
    }

    func restart() {
        engine.stop()
        start()
    }

    var isRunning: Bool { engine.isRunning }

    /// A short test beep (console: "beep").
    func beep() {
        var buf = [Int16](repeating: 0, count: 8820)
        for i in 0..<buf.count { buf[i] = (i / 20) % 2 == 0 ? 8000 : -8000 }
        buf.withUnsafeBufferPointer { push($0.baseAddress!, $0.count) }
    }
}