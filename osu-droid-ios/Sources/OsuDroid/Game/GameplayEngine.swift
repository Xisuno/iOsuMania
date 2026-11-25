import Foundation

enum HitResult: Int {
    case miss = 0, meh = 50, ok = 100, great = 300
}

enum GameplayEvent {
    case judged(index: Int, result: HitResult, position: Vec2, time: Double)
    case sliderPart(index: Int, kind: SliderNestedObject.Kind, hit: Bool, position: Vec2, time: Double)
}

/// Judgement and scoring for the Droid game mode. Pure logic: no rendering, no clock.
/// Coordinates are osu pixels (0...512 x 0...384, y down); times are milliseconds.
///
/// UNCALIBRATED / simplified versus osu!droid: ScoreV1 difficulty multiplier is fixed at 1, spinner
/// requirements follow the lazer formula, no HP drain/fail, no precise-mode windows, no stacking.
final class GameplayEngine {
    let beatmap: Beatmap
    let hitWindow: DroidHitWindow
    let radius: Float
    let followRadius: Float

    private(set) var combo = 0
    private(set) var maxCombo = 0
    private(set) var score = 0
    private(set) var countGreat = 0
    private(set) var countOk = 0
    private(set) var countMeh = 0
    private(set) var countMiss = 0

    static let spinnerCenter = Vec2(256, 192)
    private static let sliderPartScore: [SliderNestedObject.Kind: Int] =
        [.head: 30, .tick: 10, .repeatPoint: 30, .tail: 30]

    private struct State {
        var done = false
        var headDone = false
        var nestedCursor = 0
        var nestedHits = 0
        var spinRotations = 0.0
        var spinRequired = 1.0
    }

    private var states: [State]
    private var touches: [Int: Vec2] = [:]
    private var lastSpinAngle: [Int: Double] = [:]
    private var cursor = 0

    var objects: [HitObject] { beatmap.hitObjects }
    var isFinished: Bool { cursor >= beatmap.hitObjects.count }

    var accuracy: Double {
        let total = countGreat + countOk + countMeh + countMiss
        if total == 0 { return 1 }
        return Double(300 * countGreat + 100 * countOk + 50 * countMeh) / Double(300 * total)
    }

    init(beatmap: Beatmap) {
        self.beatmap = beatmap
        self.hitWindow = DroidHitWindow(overallDifficulty: Double(beatmap.difficulty.od))
        self.radius = CircleSize.objectRadius * CircleSize.droidCSToDroidScale(beatmap.difficulty.cs)
        self.followRadius = radius * 2.4
        self.states = Array(repeating: State(), count: beatmap.hitObjects.count)

        let rps = DifficultyRange.range(Double(beatmap.difficulty.od), 1.5, 2.5, 3.5)
        for (i, obj) in beatmap.hitObjects.enumerated() {
            if case .spinner = obj.kind {
                states[i].spinRequired = max(1, ((obj.endTime - obj.startTime) / 1000 * rps).rounded(.towardZero))
            }
        }
    }

    // MARK: - Input

    func touchDown(id: Int, at position: Vec2, time: Double) -> [GameplayEvent] {
        touches[id] = position
        lastSpinAngle[id] = angle(of: position)

        guard let i = firstHittableIndex() else { return [] }
        let obj = objects[i]
        let dt = time - obj.startTime
        if dt < -hitWindow.meh { return [] }                       // too early: ignored
        if position.distance(to: obj.position) > radius { return [] } // not on the object

        let result: HitResult
        let adt = abs(dt)
        if adt <= hitWindow.great { result = .great }
        else if adt <= hitWindow.ok { result = .ok }
        else if adt <= hitWindow.meh { result = .meh }
        else { return [] }                                          // late: update() will register the miss

        var events: [GameplayEvent] = []
        switch obj.kind {
        case .circle:
            judge(i, result, affectsCombo: true, time: time, position: obj.position, &events)
        case .slider(let slider):
            states[i].headDone = true
            states[i].nestedHits += 1
            registerSliderPart(i, SliderNestedObject(kind: .head, time: slider.startTime, position: slider.startPosition),
                               hit: true, time: time, &events)
        case .spinner:
            break
        }
        return events
    }

    func touchMoved(id: Int, to position: Vec2, time: Double) {
        touches[id] = position
        let a = angle(of: position)
        defer { lastSpinAngle[id] = a }
        guard let last = lastSpinAngle[id], let i = activeSpinnerIndex(at: time) else { return }
        var delta = a - last
        while delta > Double.pi { delta -= 2 * Double.pi }
        while delta < -Double.pi { delta += 2 * Double.pi }
        states[i].spinRotations += abs(delta) / (2 * Double.pi)
    }

    func touchUp(id: Int) {
        touches[id] = nil
        lastSpinAngle[id] = nil
    }

    /// Releases all input state (focus loss, pause, scene teardown).
    func releaseAllTouches() {
        touches.removeAll()
        lastSpinAngle.removeAll()
    }

    // MARK: - Time

    func update(time: Double) -> [GameplayEvent] {
        var events: [GameplayEvent] = []
        var i = cursor
        while i < objects.count {
            let obj = objects[i]
            if obj.startTime > time { break }
            if !states[i].done { process(i, obj, time, &events) }
            i += 1
        }
        while cursor < objects.count && states[cursor].done { cursor += 1 }
        return events
    }

    // MARK: - Internals

    private func firstHittableIndex() -> Int? {
        var i = cursor
        while i < objects.count {
            switch objects[i].kind {
            case .circle: if !states[i].done { return i }
            case .slider: if !states[i].headDone && !states[i].done { return i }
            case .spinner: break
            }
            i += 1
        }
        return nil
    }

    private func activeSpinnerIndex(at time: Double) -> Int? {
        var i = cursor
        while i < objects.count {
            let obj = objects[i]
            if obj.startTime > time { break }
            if case .spinner = obj.kind, !states[i].done, time <= obj.endTime { return i }
            i += 1
        }
        return nil
    }

    private func angle(of p: Vec2) -> Double {
        atan2(Double(p.y - Self.spinnerCenter.y), Double(p.x - Self.spinnerCenter.x))
    }

    private func process(_ i: Int, _ obj: HitObject, _ time: Double, _ events: inout [GameplayEvent]) {
        switch obj.kind {
        case .circle:
            if time > obj.startTime + hitWindow.meh {
                judge(i, .miss, affectsCombo: true, time: time, position: obj.position, &events)
            }
        case .slider(let slider):
            if !states[i].headDone && time > slider.startTime + hitWindow.meh {
                states[i].headDone = true
                registerSliderPart(i, SliderNestedObject(kind: .head, time: slider.startTime, position: slider.startPosition),
                                   hit: false, time: time, &events)
            }
            while states[i].nestedCursor < slider.nested.count {
                let part = slider.nested[states[i].nestedCursor]
                if part.kind == .head { states[i].nestedCursor += 1; continue }
                if time < part.time { break }
                let tracking = touches.values.contains { $0.distance(to: part.position) <= followRadius }
                if tracking { states[i].nestedHits += 1 }
                registerSliderPart(i, part, hit: tracking, time: time, &events)
                states[i].nestedCursor += 1
            }
            if states[i].headDone && states[i].nestedCursor >= slider.nested.count {
                let total = slider.nested.count
                let hits = states[i].nestedHits
                let result: HitResult = hits == total ? .great : (hits * 2 >= total ? .ok : (hits > 0 ? .meh : .miss))
                judge(i, result, affectsCombo: false, time: time, position: slider.endPosition, &events)
            }
        case .spinner:
            if time > obj.endTime {
                let ratio = states[i].spinRotations / states[i].spinRequired
                let result: HitResult = ratio >= 1 ? .great : (ratio >= 0.9 ? .ok : (ratio >= 0.75 ? .meh : .miss))
                judge(i, result, affectsCombo: true, time: time, position: Self.spinnerCenter, &events)
            }
        }
    }

    private func registerSliderPart(_ i: Int, _ part: SliderNestedObject, hit: Bool, time: Double,
                                    _ events: inout [GameplayEvent]) {
        if hit {
            score += Self.sliderPartScore[part.kind] ?? 0
            combo += 1
            maxCombo = max(maxCombo, combo)
        } else {
            combo = 0
        }
        events.append(.sliderPart(index: i, kind: part.kind, hit: hit, position: part.position, time: time))
    }

    private func judge(_ i: Int, _ result: HitResult, affectsCombo: Bool, time: Double, position: Vec2,
                       _ events: inout [GameplayEvent]) {
        states[i].done = true
        switch result {
        case .great: countGreat += 1
        case .ok: countOk += 1
        case .meh: countMeh += 1
        case .miss: countMiss += 1
        }

        let base = Double(result.rawValue)
        score += Int((base + base * Double(combo) / 25).rounded(.towardZero))

        if affectsCombo {
            if result == .miss { combo = 0 } else { combo += 1; maxCombo = max(maxCombo, combo) }
        }
        events.append(.judged(index: i, result: result, position: position, time: time))
    }
}
