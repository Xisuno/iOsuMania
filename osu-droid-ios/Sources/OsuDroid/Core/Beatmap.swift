import Foundation

struct ComboColor: Equatable {
    var r: UInt8, g: UInt8, b: UInt8
    static let defaults: [ComboColor] = [
        ComboColor(r: 255, g: 192, b: 0), ComboColor(r: 0, g: 202, b: 0),
        ComboColor(r: 18, g: 124, b: 255), ComboColor(r: 242, g: 24, b: 57),
    ]
}

struct TimingPoint {
    var time: Double
    var beatLength: Double
    var uninherited: Bool
    var kiai: Bool
}

struct BreakPeriod { var start: Double; var end: Double }

struct BeatmapGeneral {
    var audioFilename = ""
    var audioLeadIn = 0.0
    var stackLeniency = 0.7
    var mode = 0
}

struct BeatmapMetadata {
    var title = "", titleUnicode = "", artist = "", artistUnicode = ""
    var creator = "", version = ""
    var beatmapID = 0, beatmapSetID = 0
}

struct BeatmapDifficulty {
    var hp: Float = 5, cs: Float = 5, od: Float = 5, ar: Float = 5
    var sliderMultiplier = 1.4
    var sliderTickRate = 1.0
}

/// One scoring element nested inside a slider (head, tick, repeat or tail).
struct SliderNestedObject {
    enum Kind { case head, tick, repeatPoint, tail }
    var kind: Kind
    var time: Double
    var position: Vec2   // osu pixel space (0...512, 0...384)
}

final class OsuSlider {
    let path: SliderPath
    let slides: Int
    let length: Double
    let velocity: Double       // osu pixels per millisecond
    let spanDuration: Double
    let startTime: Double
    let startPosition: Vec2
    private(set) var nested: [SliderNestedObject] = []

    var duration: Double { spanDuration * Double(slides) }
    var endTime: Double { startTime + duration }
    var endPosition: Vec2 { startPosition + path.positionAt(slides % 2 == 0 ? 0 : 1) }

    /// Legacy tails are judged slightly before the visual end (osu-stable behaviour).
    static let legacyLastTickOffset = 36.0

    init(path: SliderPath, slides: Int, length: Double, velocity: Double, tickDistance: Double,
         startTime: Double, startPosition: Vec2) {
        self.path = path
        self.slides = slides
        self.length = length
        self.velocity = velocity
        self.spanDuration = velocity > 0 ? length / velocity : 0
        self.startTime = startTime
        self.startPosition = startPosition
        self.nested = buildNested(tickDistance: tickDistance)
    }

    /// Progress along the path (0 at head, 1 at the far end) for the slider ball at `time`.
    func pathProgress(at time: Double) -> Double {
        guard spanDuration > 0 else { return 0 }
        let t = min(max(time - startTime, 0), duration)
        var span = Int(t / spanDuration)
        if span >= slides { span = slides - 1 }
        let local = (t - Double(span) * spanDuration) / spanDuration
        return span % 2 == 0 ? local : 1 - local
    }

    func ballPosition(at time: Double) -> Vec2 { startPosition + path.positionAt(pathProgress(at: time)) }

    private func buildNested(tickDistance: Double) -> [SliderNestedObject] {
        var result = [SliderNestedObject(kind: .head, time: startTime, position: startPosition)]
        let minDistanceFromEnd = velocity * 10

        if tickDistance > 0 && length > 0 && spanDuration > 0 {
            for span in 0..<slides {
                let spanStart = startTime + Double(span) * spanDuration
                let reversed = span % 2 == 1
                var d = tickDistance
                while d <= length {
                    if d >= length - minDistanceFromEnd { break }
                    let distanceProgress = d / length
                    let timeProgress = reversed ? 1 - distanceProgress : distanceProgress
                    let time = spanStart + timeProgress * spanDuration
                    let pathP = reversed ? timeProgress : distanceProgress
                    result.append(SliderNestedObject(kind: .tick, time: time,
                                                     position: startPosition + path.positionAt(pathP)))
                    d += tickDistance
                }
            }
        }

        if slides > 1 {
            for i in 1..<slides {
                result.append(SliderNestedObject(kind: .repeatPoint, time: startTime + Double(i) * spanDuration,
                                                 position: startPosition + path.positionAt(i % 2 == 1 ? 1 : 0)))
            }
        }

        let tailTime = max(startTime + duration / 2, endTime - OsuSlider.legacyLastTickOffset)
        result.append(SliderNestedObject(kind: .tail, time: tailTime, position: endPosition))

        // Stable sort by time: ties keep construction order (head, ticks, repeats, tail).
        return result.enumerated().sorted {
            $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset
        }.map { $0.element }
    }
}

enum HitObjectKind {
    case circle
    case slider(OsuSlider)
    case spinner
}

struct HitObject {
    var startTime: Double
    var endTime: Double
    var position: Vec2           // osu pixel space
    var kind: HitObjectKind
    var newCombo: Bool
    var colorIndex: Int
    var indexInCombo: Int        // 0-based
    var hitSound: Int
}

struct Beatmap {
    var formatVersion = 14
    var general = BeatmapGeneral()
    var metadata = BeatmapMetadata()
    var difficulty = BeatmapDifficulty()
    var backgroundFilename: String?
    var breaks: [BreakPeriod] = []
    var timingPoints: [TimingPoint] = []
    var comboColors: [ComboColor] = []
    var hitObjects: [HitObject] = []

    var effectiveComboColors: [ComboColor] { comboColors.isEmpty ? ComboColor.defaults : comboColors }
}
