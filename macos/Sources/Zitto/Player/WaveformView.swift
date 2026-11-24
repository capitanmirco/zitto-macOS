import AppKit
import QuartzCore
import ZittoCore

/// Waveform view: one lane per part, zoom, playhead and loop selection. A port of waveform.py.
///
/// Positions are in samples. Calls onSeek(pos) and onLoop(start, end). The lanes are drawn with
/// Core Graphics only when something in them changes; the playhead is a layer of its own, so
/// moving it draws nothing.
final class WaveformView: NSView {
    static let ruler: CGFloat = 22
    static let bar: CGFloat = 10  // the scroll bar at the bottom
    static let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    /// Top and height of a lane out of `count`, in a view this high: for the controls beside it too.
    static func lane(_ index: Int, of count: Int, height: CGFloat) -> (top: CGFloat, height: CGFloat) {
        let space = max(Int(height - ruler - bar), 1)
        let top = Int(ruler) + space * index / max(count, 1)
        return (CGFloat(top), CGFloat(Int(ruler) + space * (index + 1) / max(count, 1) - top))
    }

    var onSeek: ((Int) -> Void)?
    var onLoop: ((Int, Int) -> Void)?

    private var peaks: [[Int32]] = []
    private var colors: [NSColor] = []
    private var audible: [Bool] = []
    private var sizes: [[Int32]] = []  // of each lane, for the current view
    private var length = 1
    private var loudest: Int32 = 1
    private var first = 0.0
    private var perPoint = 1.0
    private var span = 1.0  // samples in view
    private var loop: (start: Int, end: Int)?
    private var loopOn = false
    private var drag: (x: CGFloat, fixed: Int, edge: Int?, moved: Bool)?
    private var scrolling: (x: CGFloat, first: Double)?
    private var headPos = 0
    private var headSeen = true
    private var newView = true
    private let head = CALayer()
    private let grab: CGFloat = 6

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        head.backgroundColor = NSColor.white.cgColor
        head.zPosition = 10
        head.isHidden = true
        layer?.addSublayer(head)
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private var scale: CGFloat {
        window?.backingScaleFactor ?? 2
    }

    private var width: CGFloat {
        max(bounds.width, 1)
    }

    // MARK: content

    /// Show a song: the peaks of each part and its length in samples.
    func setTracks(_ values: [[Int32]], colors: [NSColor], length: Int) {
        peaks = values
        self.colors = colors
        self.length = max(length, 1)
        audible = Array(repeating: true, count: values.count)
        loop = nil
        loopOn = false
        drag = nil
        headPos = 0
        headSeen = true
        loudest = max(1, values.map { $0.max() ?? 0 }.max() ?? 1)
        showAll()
    }

    /// Other lanes for the same song: the view and the loop stay.
    func setLanes(_ values: [[Int32]], colors: [NSColor]) {
        peaks = values
        self.colors = colors
        audible = Array(repeating: true, count: values.count)
        loudest = max(loudest, values.map { $0.max() ?? 0 }.max() ?? 1)
        newView = true
        needsDisplay = true
    }

    func setAudible(_ values: [Bool]) {
        if values != audible {
            audible = values
            needsDisplay = true
        }
    }

    func setLoop(_ value: (Int, Int)?, on: Bool) {
        let same = value?.0 == loop?.start && value?.1 == loop?.end && on == loopOn
        if !same && drag == nil {
            loop = value.map { ($0.0, $0.1) }
            loopOn = on
            needsDisplay = true
        }
    }

    /// Move the playhead; turn the page when it leaves the view while playing.
    func setHead(_ position: Int, follow: Bool) {
        var seen = 0 <= x(position) && x(position) <= width
        if follow && !seen && headSeen && drag == nil {
            setView(Double(position) - 0.08 * Double(width) * perPoint, perPoint)
            seen = true
        }
        headPos = position
        headSeen = seen
        placeHead()
    }

    private func placeHead() {
        let at = x(headPos)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        head.isHidden = peaks.isEmpty || at < 0 || at >= width
        head.frame = CGRect(x: floor(at * scale) / scale, y: 0, width: 1, height: bounds.height - Self.bar)
        CATransaction.commit()
    }

    // MARK: view

    func showAll() {
        setView(0, Double(length) / Double(width))
    }

    func showLoop() {
        guard let loop else { return }
        let margin = Double(loop.end - loop.start) * 0.06
        setView(Double(loop.start) - margin, (Double(loop.end - loop.start) + 2 * margin) / Double(width))
    }

    func zoom(_ factor: Double, at point: CGFloat) {
        let at = Double(pos(point))
        let per = clampZoom(perPoint * factor)
        setView(at - Double(point) * per, per)
    }

    func pan(_ pages: Double) {
        setView(first + pages * Double(width) * perPoint, perPoint)
    }

    private func clampZoom(_ per: Double) -> Double {
        let widest = Double(length) / Double(width)
        return min(max(per, min(Double(Peaks.hop), widest)), widest)
    }

    private func setView(_ start: Double, _ per: Double) {
        perPoint = clampZoom(per)
        span = Double(width) * perPoint
        first = min(max(start, 0), max(Double(length) - span, 0))
        newView = true
        needsDisplay = true
        placeHead()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let before = span
        super.setFrameSize(newSize)
        // The same stretch of music in the new width.
        setView(first, before / Double(width))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        newView = true
        needsDisplay = true
    }

    private func x(_ position: Int) -> CGFloat {
        CGFloat((Double(position) - first) / perPoint)
    }

    private func pos(_ x: CGFloat) -> Int {
        Int(min(max(first + Double(x) * perPoint, 0), Double(length)))
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(Theme.bg.cgColor)
        context.fill(bounds)
        guard !peaks.isEmpty else {
            return
        }
        let columns = Int(width * scale)
        if newView || sizes.count != peaks.count || sizes.first?.count != columns {
            newView = false
            sizes = peaks.map { Peaks.columns($0, first: first, perPixel: perPoint / Double(scale), width: columns) }
        }
        let ticks = self.ticks()
        drawRuler(ticks)
        let bottom = bounds.height - Self.bar

        // Where there is no sound: the loop and the time marks.
        if let loop {
            let start = min(max(x(loop.start), 0), width), end = min(max(x(loop.end), 0), width)
            context.setFillColor((loopOn ? Theme.loopOn : Theme.loopOff).cgColor)
            context.fill(CGRect(x: start, y: Self.ruler, width: end - start, height: bottom - Self.ruler))
        }
        context.setFillColor(Theme.grid.cgColor)
        for (at, _) in ticks {
            context.fill(CGRect(x: at, y: Self.ruler, width: 1 / scale, height: bottom - Self.ruler))
        }

        let pixel = 1 / scale
        for i in peaks.indices {
            let lane = Self.lane(i, of: peaks.count, height: bounds.height)
            guard lane.height >= 2 else { continue }
            let middle = lane.top + lane.height / 2
            let room = lane.height / 2 - 3
            var rects: [CGRect] = []
            rects.reserveCapacity(columns)
            for (c, size) in sizes[i].enumerated() where size > 0 {
                let half = max(CGFloat(size) * room / CGFloat(loudest), 0)
                rects.append(CGRect(x: CGFloat(c) * pixel, y: middle - half, width: pixel, height: 2 * half + pixel))
            }
            context.setFillColor((audible.indices.contains(i) && !audible[i] ? Theme.muted : colors[i]).cgColor)
            context.fill(rects)
            context.setFillColor(Theme.grid.cgColor)
            context.fill(CGRect(x: 0, y: lane.top, width: width, height: pixel))
        }
        if let loop {
            context.setFillColor((loopOn ? Theme.accent : Theme.muted).cgColor)
            for edge in [loop.start, loop.end] {
                context.fill(CGRect(x: x(edge) - 1, y: Self.ruler, width: 2, height: bottom - Self.ruler))
            }
        }
        drawScrollBar(context)
    }

    /// Positions and labels of the time marks in view.
    private func ticks() -> [(CGFloat, String)] {
        let rate = Double(sampleRate)
        let step = Self.steps.first { $0 * rate / perPoint >= 90 } ?? Self.steps.last!
        var t = (first / rate / step).rounded(.up) * step
        var found: [(CGFloat, String)] = []
        while true {
            let at = x(Int((t * rate).rounded()))
            if at >= width || found.count > 200 {
                break
            }
            found.append((at, Peaks.clock(Int((t * rate).rounded()), decimals: step < 1 ? 1 : 0)))
            t += step
        }
        return found
    }

    private func drawRuler(_ ticks: [(CGFloat, String)]) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: Theme.dim]
        for (at, text) in ticks {
            (text as NSString).draw(at: NSPoint(x: at + 4, y: 4), withAttributes: attributes)
        }
    }

    private var thumb: CGRect {
        let start = CGFloat(first / Double(length)) * width
        let size = max(CGFloat(span / Double(length)) * width, 20)
        return CGRect(x: min(start, width - size), y: bounds.height - Self.bar + 2, width: size, height: Self.bar - 4)
    }

    private func drawScrollBar(_ context: CGContext) {
        guard span < Double(length) else { return }
        context.setFillColor((scrolling == nil ? Theme.button : Theme.hover).cgColor)
        context.addPath(CGPath(roundedRect: thumb, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()
    }

    // MARK: mouse

    private func edgeAt(_ point: CGFloat) -> Int? {
        guard let loop else { return nil }
        let distances = [abs(x(loop.start) - point), abs(x(loop.end) - point)]
        let nearest = distances[1] < distances[0] ? 1 : 0
        return distances[nearest] <= grab ? nearest : nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < bounds.height - Self.bar && edgeAt(point.x) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)  // the keyboard goes back to the player
        guard !peaks.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.y >= bounds.height - Self.bar {
            if !thumb.contains(point) {  // a click beside the thumb: a page that way
                pan(point.x < thumb.minX ? -0.9 : 0.9)
            }
            scrolling = (point.x, first)
            needsDisplay = true
            return
        }
        let edge = edgeAt(point.x)
        let fixed = edge.flatMap { e in loop.map { e == 0 ? $0.end : $0.start } } ?? pos(point.x)
        drag = (point.x, fixed, edge, false)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let scrolling {
            setView(scrolling.first + Double(point.x - scrolling.x) / Double(width) * Double(length), perPoint)
            return
        }
        guard var drag else { return }
        if abs(point.x - drag.x) > 3 {
            drag.moved = true
        }
        self.drag = drag
        if drag.moved {
            let at = pos(min(max(point.x, 0), width))
            loop = (min(drag.fixed, at), max(drag.fixed, at))
            loopOn = true
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if scrolling != nil {
            scrolling = nil
            needsDisplay = true
            return
        }
        guard let drag else { return }
        self.drag = nil
        let point = convert(event.locationInWindow, from: nil)
        if drag.moved, let loop {
            onLoop?(loop.start, loop.end)
        } else if drag.edge == nil {
            onSeek?(pos(point.x))
        }
    }

    /// Wheel: zoom; Shift+wheel, or sideways on a trackpad: move.
    override func scrollWheel(with event: NSEvent) {
        guard !peaks.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        if event.hasPreciseScrollingDeltas {
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                setView(first - Double(event.scrollingDeltaX) * perPoint, perPoint)
            } else if event.scrollingDeltaY != 0 {
                zoom(exp(-Double(event.scrollingDeltaY) * 0.01), at: point.x)
            }
        } else if event.modifierFlags.contains(.shift) || event.deltaX != 0 {
            let delta = event.deltaX != 0 ? event.deltaX : event.deltaY
            pan(-Double(delta) * 0.15)
        } else if event.deltaY != 0 {
            zoom(event.deltaY > 0 ? 0.8 : 1.25, at: point.x)
        }
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        zoom(1 / max(1 + Double(event.magnification), 0.1), at: point.x)
    }
}
