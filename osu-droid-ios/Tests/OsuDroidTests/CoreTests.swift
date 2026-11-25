import XCTest
@testable import OsuDroidiOS

private let sampleMap = """
osu file format v14

[General]
AudioFilename: audio.mp3
Mode: 0

[Metadata]
Title:Test
Artist:Someone
Creator:Me
Version:Easy

[Difficulty]
HPDrainRate:5
CircleSize:4
OverallDifficulty:5
ApproachRate:9
SliderMultiplier:1.4
SliderTickRate:1

[Events]
0,0,"bg.jpg",0,0
2,1000,2000

[TimingPoints]
0,500,4,1,0,100,1,0
2000,-50,4,1,0,100,0,0

[Colours]
Combo1 : 255,0,0
Combo2 : 0,255,0

[HitObjects]
256,192,1000,5,0
100,100,1500,2,0,L|200:100,1,100
256,192,3000,12,0,4000
"""

final class ParserTests: XCTestCase {
    func testParsesSections() throws {
        let map = try BeatmapParser.parse(sampleMap)
        XCTAssertEqual(map.metadata.title, "Test")
        XCTAssertEqual(map.general.audioFilename, "audio.mp3")
        XCTAssertEqual(map.difficulty.ar, 9)
        XCTAssertEqual(map.backgroundFilename, "bg.jpg")
        XCTAssertEqual(map.breaks.count, 1)
        XCTAssertEqual(map.comboColors.count, 2)
        XCTAssertEqual(map.timingPoints.count, 2)
        XCTAssertEqual(map.hitObjects.count, 3)
    }

    func testComboAndSliderTiming() throws {
        let map = try BeatmapParser.parse(sampleMap)
        XCTAssertEqual(map.hitObjects[0].colorIndex, 0)
        XCTAssertEqual(map.hitObjects[1].indexInCombo, 1)
        XCTAssertEqual(map.hitObjects[2].colorIndex, 1)
        XCTAssertEqual(map.hitObjects[2].endTime, 4000)
        guard case .slider(let s) = map.hitObjects[1].kind else { return XCTFail("expected slider") }
        // velocity = 100 * 1.4 * sv(1) / 500 = 0.28 px/ms; length 100 -> 357.142857 ms
        XCTAssertEqual(s.velocity, 0.28, accuracy: 1e-9)
        XCTAssertEqual(s.spanDuration, 100 / 0.28, accuracy: 1e-6)
        XCTAssertEqual(s.nested.count, 2) // head + tail, tick distance 140 > length 100
        XCTAssertEqual(s.nested.last?.kind, .tail)
    }

    func testParsesWindowsLineEndings() throws {
        let crlf = sampleMap.replacingOccurrences(of: "\n", with: "\r\n")
        let map = try BeatmapParser.parse(crlf)
        XCTAssertEqual(map.metadata.title, "Test")
        XCTAssertEqual(map.hitObjects.count, 3)
    }

    func testRejectsNonOsuFile() {
        XCTAssertThrowsError(try BeatmapParser.parse("hello"))
    }

    func testMissingApproachRateFallsBackToOD() throws {
        let text = "osu file format v7\n\n[Difficulty]\nOverallDifficulty:8\n"
        XCTAssertEqual(try BeatmapParser.parse(text).difficulty.ar, 8)
    }
}

final class SliderPathTests: XCTestCase {
    func testLinearPath() {
        let p = SliderPath(pathType: .linear, controlPoints: [Vec2(0, 0), Vec2(100, 0)], expectedDistance: 100)
        XCTAssertEqual(p.positionAt(0.5).x, 50, accuracy: 1e-4)
        XCTAssertEqual(p.positionAt(1).x, 100, accuracy: 1e-4)
    }

    func testPathExtendedToExpectedDistance() {
        let p = SliderPath(pathType: .linear, controlPoints: [Vec2(0, 0), Vec2(100, 0)], expectedDistance: 150)
        XCTAssertEqual(p.positionAt(1).x, 150, accuracy: 1e-3)
    }

    func testPathTruncatedToExpectedDistance() {
        let p = SliderPath(pathType: .linear, controlPoints: [Vec2(0, 0), Vec2(100, 0)], expectedDistance: 50)
        XCTAssertEqual(p.positionAt(1).x, 50, accuracy: 1e-3)
    }

    func testCircularArcStaysOnCircle() {
        let pts = PathApproximation.approximateCircularArc([Vec2(0, 0), Vec2(50, 50), Vec2(100, 0)])
        XCTAssertGreaterThan(pts.count, 4)
        for q in pts { XCTAssertEqual(q.distance(to: Vec2(50, 0)), 50, accuracy: 0.05) }
        XCTAssertEqual(pts.first!.x, 0, accuracy: 0.05)
        XCTAssertEqual(pts.last!.x, 100, accuracy: 0.05)
    }

    func testBezierContainsCurveMidpoint() {
        let pts = PathApproximation.approximateBezier([Vec2(0, 0), Vec2(0, 100), Vec2(100, 100), Vec2(100, 0)])
        XCTAssertEqual(pts.first, Vec2(0, 0))
        XCTAssertEqual(pts.last, Vec2(100, 0))
        XCTAssertTrue(pts.contains { $0.distance(to: Vec2(50, 75)) < 0.01 })
    }

    func testSingleControlPointBezierDoesNotCrash() {
        XCTAssertEqual(PathApproximation.approximateBezier([Vec2(5, 5)]).count, 2)
    }
}

final class TimingTests: XCTestCase {
    func testDroidHitWindows() {
        let od5 = DroidHitWindow(overallDifficulty: 5)
        XCTAssertEqual(od5.great, 75); XCTAssertEqual(od5.ok, 150); XCTAssertEqual(od5.meh, 250)
        let od0 = DroidHitWindow(overallDifficulty: 0)
        XCTAssertEqual(od0.great, 100); XCTAssertEqual(od0.ok, 200); XCTAssertEqual(od0.meh, 300)
    }

    func testPreempt() {
        XCTAssertEqual(DifficultyRange.preempt(ar: 5), 1200)
        XCTAssertEqual(DifficultyRange.preempt(ar: 10), 450)
        XCTAssertEqual(DifficultyRange.preempt(ar: 0), 1800)
        XCTAssertEqual(DifficultyRange.preempt(ar: 9), 600)
    }
}

final class EngineTests: XCTestCase {
    private func makeEngine() throws -> GameplayEngine {
        let text = """
        osu file format v14

        [Difficulty]
        CircleSize:4
        OverallDifficulty:5
        ApproachRate:9
        SliderMultiplier:1.4
        SliderTickRate:1

        [TimingPoints]
        0,500,4,1,0,100,1,0

        [HitObjects]
        256,192,1000,1,0
        256,192,2000,1,0
        """
        return GameplayEngine(beatmap: try BeatmapParser.parse(text))
    }

    func testPerfectTapIsGreatAndScores() throws {
        let e = try makeEngine()
        let events = e.touchDown(id: 1, at: Vec2(256, 192), time: 1000)
        guard case .judged(_, let r, _, _)? = events.first else { return XCTFail("no judgement") }
        XCTAssertEqual(r, .great)
        XCTAssertEqual(e.combo, 1)
        XCTAssertEqual(e.score, 300)
    }

    func testTapTooEarlyOrOffTargetIsIgnored() throws {
        let e = try makeEngine()
        XCTAssertTrue(e.touchDown(id: 1, at: Vec2(256, 192), time: 700).isEmpty)   // dt = -300 < -250
        XCTAssertTrue(e.touchDown(id: 2, at: Vec2(0, 0), time: 1000).isEmpty)      // far from object
    }

    func testLateCircleBecomesMissAndBreaksCombo() throws {
        let e = try makeEngine()
        _ = e.touchDown(id: 1, at: Vec2(256, 192), time: 1000)
        e.touchUp(id: 1)
        let events = e.update(time: 2251)   // OD5 meh window is 250 ms
        guard case .judged(_, let r, _, _)? = events.first else { return XCTFail("no judgement") }
        XCTAssertEqual(r, .miss)
        XCTAssertEqual(e.combo, 0)
        XCTAssertEqual(e.countMiss, 1)
        XCTAssertTrue(e.isFinished)
    }
}
