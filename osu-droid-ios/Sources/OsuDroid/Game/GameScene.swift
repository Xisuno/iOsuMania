import SpriteKit
import UIKit

struct PlayResult {
    var score: Int
    var maxCombo: Int
    var accuracy: Double
    var great: Int, ok: Int, meh: Int, miss: Int
}

/// SpriteKit renderer for one beatmap. The playfield is laid out in a 640x480 virtual space with the
/// 512x384 osu field offset by (64, 48), matching the 480-unit-high space the Droid circle scale is defined in.
final class GameScene: SKScene {
    private static let fieldOffset = Vec2(64, 48)
    private static let virtualSize = CGSize(width: 640, height: 480)

    private let beatmap: Beatmap
    private let engine: GameplayEngine
    private let clock: GameClock
    private let preempt: Double
    private let fadeIn: Double
    private let colors: [UIColor]
    private let lastEndTime: Double

    private var liveNodes: [Int: ObjectNodes] = [:]
    private var nextSpawn = 0
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 1
    private var started = false
    private var finished = false

    private let scoreLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let comboLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let accuracyLabel = SKLabelNode(fontNamed: "Menlo")

    var onFinish: ((PlayResult) -> Void)?

    private final class ObjectNodes {
        let root = SKNode()
        var approach: SKShapeNode?
        var ball: SKShapeNode?
        var follow: SKShapeNode?
        var fadeTargets: [SKNode] = []
    }

    init(size: CGSize, beatmap: Beatmap, audioURL: URL?, offsetMs: Double) {
        let gameClock = GameClock(audioURL: audioURL)
        gameClock.offsetMs = offsetMs
        let approachTime = DifficultyRange.preempt(ar: Double(beatmap.difficulty.ar))

        self.beatmap = beatmap
        self.engine = GameplayEngine(beatmap: beatmap)
        self.clock = gameClock
        self.preempt = approachTime
        self.fadeIn = DifficultyRange.fadeIn(preempt: approachTime)
        self.colors = beatmap.effectiveComboColors.map {
            UIColor(red: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255, blue: CGFloat($0.b) / 255, alpha: 1)
        }
        self.lastEndTime = beatmap.hitObjects.map { $0.endTime }.max() ?? 0
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = UIColor(white: 0.06, alpha: 1)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private var fieldScale: CGFloat { min(size.width / Self.virtualSize.width, size.height / Self.virtualSize.height) }
    private var fieldOrigin: CGPoint {
        CGPoint(x: (size.width - Self.virtualSize.width * fieldScale) / 2,
                y: (size.height - Self.virtualSize.height * fieldScale) / 2)
    }

    private func toScene(_ p: Vec2) -> CGPoint {
        let s = fieldScale, o = fieldOrigin
        return CGPoint(x: o.x + CGFloat(p.x + Self.fieldOffset.x) * s,
                       y: size.height - (o.y + CGFloat(p.y + Self.fieldOffset.y) * s))
    }

    private func toOsu(_ p: CGPoint) -> Vec2 {
        let s = fieldScale, o = fieldOrigin
        return Vec2(Float((p.x - o.x) / s) - Self.fieldOffset.x,
                    Float((size.height - p.y - o.y) / s) - Self.fieldOffset.y)
    }

    private var radiusPx: CGFloat { CGFloat(engine.radius) * fieldScale }

    // MARK: - Lifecycle

    override func didMove(to view: SKView) {
        view.isMultipleTouchEnabled = true
        scoreLabel.fontSize = 22; scoreLabel.horizontalAlignmentMode = .right
        scoreLabel.position = CGPoint(x: size.width - 16, y: size.height - 32)
        accuracyLabel.fontSize = 14; accuracyLabel.horizontalAlignmentMode = .right
        accuracyLabel.position = CGPoint(x: size.width - 16, y: size.height - 52)
        comboLabel.fontSize = 30; comboLabel.horizontalAlignmentMode = .left
        comboLabel.position = CGPoint(x: 16, y: 16)
        for label in [scoreLabel, comboLabel, accuracyLabel] { label.zPosition = 100_000; addChild(label) }
        clock.start()
        started = true
    }

    override func willMove(from view: SKView) {
        engine.releaseAllTouches()
        clock.stop()
    }

    func stopPlayback() {
        engine.releaseAllTouches()
        clock.stop()
        finished = true
    }

    override func update(_ currentTime: TimeInterval) {
        guard started, !finished else { return }
        let t = clock.timeMs

        handle(engine.update(time: t))

        while nextSpawn < beatmap.hitObjects.count,
              beatmap.hitObjects[nextSpawn].startTime - preempt <= t {
            spawn(nextSpawn)
            nextSpawn += 1
        }

        for (index, nodes) in liveNodes { animate(index, nodes, t) }

        scoreLabel.text = String(format: "%08d", engine.score)
        comboLabel.text = "\(engine.combo)x"
        accuracyLabel.text = String(format: "%.2f%%", engine.accuracy * 100)

        if t > lastEndTime + 1500 && engine.isFinished {
            finished = true
            clock.stop()
            onFinish?(PlayResult(score: engine.score, maxCombo: engine.maxCombo, accuracy: engine.accuracy,
                                 great: engine.countGreat, ok: engine.countOk, meh: engine.countMeh,
                                 miss: engine.countMiss))
        }
    }

    // MARK: - Object nodes

    private func spawn(_ index: Int) {
        let obj = beatmap.hitObjects[index]
        let color = colors[obj.colorIndex % colors.count]
        let nodes = ObjectNodes()
        nodes.root.zPosition = CGFloat(beatmap.hitObjects.count - index)
        nodes.root.alpha = 0

        switch obj.kind {
        case .circle:
            addCircle(to: nodes, at: obj.position, number: obj.indexInCombo + 1, color: color)
            addApproach(to: nodes, at: obj.position, color: color)
        case .slider(let slider):
            addSliderBody(to: nodes, slider: slider)
            addCircle(to: nodes, at: obj.position, number: obj.indexInCombo + 1, color: color)
            addApproach(to: nodes, at: obj.position, color: color)
            let ball = SKShapeNode(circleOfRadius: radiusPx * 0.9)
            ball.fillColor = color; ball.strokeColor = .white; ball.lineWidth = 2
            ball.position = toScene(slider.startPosition); ball.isHidden = true
            let follow = SKShapeNode(circleOfRadius: CGFloat(engine.followRadius) * fieldScale)
            follow.fillColor = UIColor(white: 1, alpha: 0.12); follow.strokeColor = .white; follow.lineWidth = 2
            follow.position = ball.position; follow.isHidden = true
            nodes.root.addChild(follow); nodes.root.addChild(ball)
            nodes.ball = ball; nodes.follow = follow
        case .spinner:
            let ring = SKShapeNode(circleOfRadius: min(size.height, size.width) * 0.38)
            ring.strokeColor = .white; ring.lineWidth = 4; ring.fillColor = .clear
            ring.position = toScene(GameplayEngine.spinnerCenter)
            nodes.root.addChild(ring)
            let hint = SKLabelNode(fontNamed: "Menlo-Bold")
            hint.text = "SPIN"; hint.fontSize = 28; hint.verticalAlignmentMode = .center
            hint.position = ring.position
            nodes.root.addChild(hint)
        }
        addChild(nodes.root)
        liveNodes[index] = nodes
    }

    private func addCircle(to nodes: ObjectNodes, at p: Vec2, number: Int, color: UIColor) {
        let circle = SKShapeNode(circleOfRadius: radiusPx)
        circle.fillColor = color; circle.strokeColor = .white; circle.lineWidth = max(2, radiusPx * 0.08)
        circle.position = toScene(p)
        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.text = "\(number)"; label.fontSize = radiusPx * 0.9
        label.verticalAlignmentMode = .center; label.horizontalAlignmentMode = .center
        circle.addChild(label)
        nodes.root.addChild(circle)
    }

    private func addApproach(to nodes: ObjectNodes, at p: Vec2, color: UIColor) {
        let ring = SKShapeNode(circleOfRadius: radiusPx)
        ring.fillColor = .clear; ring.strokeColor = color; ring.lineWidth = max(2, radiusPx * 0.07)
        ring.position = toScene(p); ring.setScale(4)
        nodes.root.addChild(ring)
        nodes.approach = ring
    }

    private func addSliderBody(to nodes: ObjectNodes, slider: OsuSlider) {
        let points = slider.path.pathToProgress(0, 1)
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: toScene(slider.startPosition + first))
        for p in points.dropFirst() { path.addLine(to: toScene(slider.startPosition + p)) }

        let border = SKShapeNode(path: path)
        border.strokeColor = .white; border.lineWidth = radiusPx * 2
        border.lineCap = .round; border.lineJoin = .round
        let body = SKShapeNode(path: path)
        body.strokeColor = UIColor(white: 0.12, alpha: 1); body.lineWidth = radiusPx * 2 - max(4, radiusPx * 0.16)
        body.lineCap = .round; body.lineJoin = .round
        nodes.root.addChild(border); nodes.root.addChild(body)
    }

    private func animate(_ index: Int, _ nodes: ObjectNodes, _ t: Double) {
        let obj = beatmap.hitObjects[index]
        let appear = obj.startTime - preempt
        let fade = min(max((t - appear) / fadeIn, 0), 1)
        if nodes.root.action(forKey: "out") == nil { nodes.root.alpha = CGFloat(fade) }

        if let approach = nodes.approach {
            let progress = min(max((t - appear) / preempt, 0), 1)
            approach.setScale(CGFloat(1 + 3 * (1 - progress)))
            approach.isHidden = t >= obj.startTime
        }
        if case .slider(let slider) = obj.kind, let ball = nodes.ball, let follow = nodes.follow {
            let active = t >= slider.startTime && t <= slider.endTime
            ball.isHidden = !active; follow.isHidden = !active
            if active {
                let p = toScene(slider.ballPosition(at: t))
                ball.position = p; follow.position = p
            }
        }
    }

    // MARK: - Events

    private func handle(_ events: [GameplayEvent]) {
        for event in events {
            switch event {
            case .judged(let index, let result, let position, _):
                popup(result, at: position)
                if let nodes = liveNodes.removeValue(forKey: index) {
                    nodes.root.run(.sequence([.fadeOut(withDuration: 0.15), .removeFromParent()]), withKey: "out")
                }
            case .sliderPart(_, let kind, let hit, let position, _):
                if !hit && kind != .tick { popup(.miss, at: position) }
            }
        }
    }

    private func popup(_ result: HitResult, at position: Vec2) {
        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        switch result {
        case .great: label.text = "300"; label.fontColor = .cyan
        case .ok: label.text = "100"; label.fontColor = .green
        case .meh: label.text = "50"; label.fontColor = .yellow
        case .miss: label.text = "X"; label.fontColor = .red
        }
        label.fontSize = 20
        label.position = toScene(position)
        label.zPosition = 90_000
        addChild(label)
        label.run(.sequence([.group([.moveBy(x: 0, y: 14, duration: 0.4), .fadeOut(withDuration: 0.4)]), .removeFromParent()]))
    }

    // MARK: - Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard started, !finished else { return }
        for touch in touches {
            let id = nextTouchID; nextTouchID += 1
            touchIDs[ObjectIdentifier(touch)] = id
            handle(engine.touchDown(id: id, at: toOsu(touch.location(in: self)), time: clock.timeMs))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard started, !finished else { return }
        for touch in touches {
            guard let id = touchIDs[ObjectIdentifier(touch)] else { continue }
            engine.touchMoved(id: id, to: toOsu(touch.location(in: self)), time: clock.timeMs)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches {
            if let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) { engine.touchUp(id: id) }
        }
    }
}
