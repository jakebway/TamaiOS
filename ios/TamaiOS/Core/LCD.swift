import SwiftUI
import UIKit
import QuartzCore

/// Hands the newest screen image from the emulator thread to the LCD layer.
final class FrameSink {
    private let lock = NSLock()
    private var image: CGImage?
    private var version = 0

    func put(_ img: CGImage?) {
        lock.lock(); image = img; version &+= 1; lock.unlock()
    }

    /// The image if it changed since `seen`.
    func take(after seen: Int) -> (CGImage?, Int)? {
        lock.lock(); defer { lock.unlock() }
        return version == seen ? nil : (image, version)
    }
}

/// The toy's LCD: a plain layer updated on the display refresh, so the
/// screen animates at full speed without SwiftUI redrawing anything.
final class LCDLayerView: UIView {
    var sink: FrameSink?
    private var link: CADisplayLink?
    private var seen = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, link == nil {
            let l = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.step))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            l.add(to: .main, forMode: .common)
            link = l
        } else if window == nil {
            link?.invalidate()
            link = nil
        }
    }

    fileprivate func step() {
        guard let sink, let r = sink.take(after: seen) else { return }
        seen = r.1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = r.0
        CATransaction.commit()
    }

    private final class WeakTarget: NSObject {
        weak var view: LCDLayerView?
        init(_ v: LCDLayerView) { view = v }
        @objc func step() { view?.step() }
    }
}

struct LCDView: UIViewRepresentable {
    let sink: FrameSink
    func makeUIView(context: Context) -> LCDLayerView {
        let v = LCDLayerView()
        v.sink = sink
        return v
    }
    func updateUIView(_ v: LCDLayerView, context: Context) { v.sink = sink }
}

/// Raw touches for the toy's buttons: fires on the instant a finger lands,
/// with no gesture-recogniser delay, and several buttons can be held at once.
struct TouchPad: UIViewRepresentable {
    let down: () -> Void
    let up: () -> Void

    func makeUIView(context: Context) -> PadView {
        let v = PadView()
        v.down = down; v.up = up
        return v
    }
    func updateUIView(_ v: PadView, context: Context) { v.down = down; v.up = up }

    final class PadView: UIView {
        var down: (() -> Void)?
        var up: (() -> Void)?
        private var touching = 0
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isMultipleTouchEnabled = true
        }
        required init?(coder: NSCoder) { fatalError() }
        override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
            if touching == 0 { down?() }
            touching += t.count
        }
        override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { lift(t.count) }
        override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { lift(t.count) }
        private func lift(_ n: Int) {
            touching = max(0, touching - n)
            if touching == 0 { up?() }
        }
    }
}

enum Haptics {
    private static let gen: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        return g
    }()
    static func tap() {
        gen.impactOccurred()
        gen.prepare()
    }
}