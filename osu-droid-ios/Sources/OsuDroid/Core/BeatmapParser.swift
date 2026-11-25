import Foundation

enum BeatmapParseError: Error, Equatable {
    case notAnOsuFile
}

/// Parser for the .osu file format (v3...v14). Covers the sections gameplay needs.
/// OsuSlider construction follows com.osudroid.beatmaps.parser (see PathApproximation/SliderPath ports).
enum BeatmapParser {
    static func parse(_ rawText: String, includeHitObjects: Bool = true) throws -> Beatmap {
        var beatmap = Beatmap()
        var section = ""
        var sawHeader = false
        var pendingObjectLines: [Substring] = []
        var arSpecified = false

        let text = rawText.hasPrefix("\u{FEFF}") ? String(rawText.dropFirst()) : rawText
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }

            if !sawHeader {
                guard line.hasPrefix("osu file format v") else { throw BeatmapParseError.notAnOsuFile }
                beatmap.formatVersion = Int(line.dropFirst("osu file format v".count)) ?? 14
                sawHeader = true
                continue
            }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }

            switch section {
            case "General":
                guard let (k, v) = keyValue(line) else { continue }
                switch k {
                case "AudioFilename": beatmap.general.audioFilename = v
                case "AudioLeadIn": beatmap.general.audioLeadIn = Double(v) ?? 0
                case "StackLeniency": beatmap.general.stackLeniency = Double(v) ?? 0.7
                case "Mode": beatmap.general.mode = Int(v) ?? 0
                default: break
                }
            case "Metadata":
                guard let (k, v) = keyValue(line) else { continue }
                switch k {
                case "Title": beatmap.metadata.title = v
                case "TitleUnicode": beatmap.metadata.titleUnicode = v
                case "Artist": beatmap.metadata.artist = v
                case "ArtistUnicode": beatmap.metadata.artistUnicode = v
                case "Creator": beatmap.metadata.creator = v
                case "Version": beatmap.metadata.version = v
                case "BeatmapID": beatmap.metadata.beatmapID = Int(v) ?? 0
                case "BeatmapSetID": beatmap.metadata.beatmapSetID = Int(v) ?? 0
                default: break
                }
            case "Difficulty":
                guard let (k, v) = keyValue(line) else { continue }
                switch k {
                case "HPDrainRate": beatmap.difficulty.hp = Float(v) ?? 5
                case "CircleSize": beatmap.difficulty.cs = Float(v) ?? 5
                case "OverallDifficulty": beatmap.difficulty.od = Float(v) ?? 5
                case "ApproachRate": beatmap.difficulty.ar = Float(v) ?? 5; arSpecified = true
                case "SliderMultiplier": beatmap.difficulty.sliderMultiplier = Double(v) ?? 1.4
                case "SliderTickRate": beatmap.difficulty.sliderTickRate = Double(v) ?? 1
                default: break
                }
            case "Events":
                let parts = line.split(separator: ",", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count >= 3, parts[0] == "0" {
                    beatmap.backgroundFilename = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                } else if parts.count >= 3, parts[0] == "2" || parts[0] == "Break",
                          let s = Double(parts[1]), let e = Double(parts[2]) {
                    beatmap.breaks.append(BreakPeriod(start: s, end: e))
                }
            case "TimingPoints":
                if let tp = parseTimingPoint(line) { beatmap.timingPoints.append(tp) }
            case "Colours":
                guard let (k, v) = keyValue(line), k.hasPrefix("Combo") else { continue }
                let rgb = v.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
                if rgb.count >= 3 { beatmap.comboColors.append(ComboColor(r: rgb[0], g: rgb[1], b: rgb[2])) }
            case "HitObjects":
                if includeHitObjects { pendingObjectLines.append(rawLine) }
            default:
                break
            }
        }

        guard sawHeader else { throw BeatmapParseError.notAnOsuFile }

        // Old beatmaps without ApproachRate use OD.
        if !arSpecified { beatmap.difficulty.ar = beatmap.difficulty.od }

        beatmap.timingPoints = stableSortedByTime(beatmap.timingPoints)
        if includeHitObjects {
            beatmap.hitObjects = buildHitObjects(pendingObjectLines, beatmap: beatmap)
        }
        return beatmap
    }

    // MARK: - Helpers

    private static func keyValue(_ line: String) -> (String, String)? {
        guard let idx = line.firstIndex(of: ":") else { return nil }
        let key = line[..<idx].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func parseTimingPoint(_ line: String) -> TimingPoint? {
        let p = line.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard p.count >= 2, let time = Double(p[0]), let beatLength = Double(p[1]) else { return nil }
        let uninherited = p.count > 6 ? p[6] == "1" : beatLength > 0
        let effects = p.count > 7 ? (Int(p[7]) ?? 0) : 0
        return TimingPoint(time: time, beatLength: beatLength, uninherited: uninherited, kiai: effects & 1 != 0)
    }

    private static func stableSortedByTime(_ points: [TimingPoint]) -> [TimingPoint] {
        points.enumerated().sorted {
            $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset
        }.map { $0.element }
    }

    /// Beat length (ms) and slider velocity multiplier in effect at `time`.
    static func timing(at time: Double, in points: [TimingPoint]) -> (beatLength: Double, sliderVelocity: Double) {
        var beatLength: Double?
        var sv = 1.0
        for tp in points where tp.time <= time + 5 {
            if tp.uninherited {
                beatLength = tp.beatLength
                sv = 1.0
            } else if tp.beatLength < 0 {
                sv = min(max(-100 / tp.beatLength, 0.1), 10)
            }
        }
        if beatLength == nil { beatLength = points.first(where: { $0.uninherited })?.beatLength }
        return (beatLength ?? 1000, sv)
    }

    private static func buildHitObjects(_ lines: [Substring], beatmap: Beatmap) -> [HitObject] {
        var objects: [HitObject] = []
        let colorCount = max(1, beatmap.effectiveComboColors.count)
        var colorIndex = -1
        var indexInCombo = 0
        var forceNewCombo = true

        for line in lines {
            let p = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard p.count >= 5, let x = Float(p[0]), let y = Float(p[1]),
                  let time = Double(p[2]), let type = Int(p[3]) else { continue }
            let hitSound = Int(p[4]) ?? 0
            let position = Vec2(x, y)

            let isCircle = type & 1 != 0, isSlider = type & 2 != 0, isSpinner = type & 8 != 0
            guard isCircle || isSlider || isSpinner else { continue }

            let newCombo = (type & 4 != 0) || forceNewCombo
            let offset = (type >> 4) & 7
            if newCombo {
                colorIndex = ((colorIndex + 1 + offset) % colorCount + colorCount) % colorCount
                indexInCombo = 0
            } else {
                indexInCombo += 1
            }
            forceNewCombo = isSpinner

            if isCircle {
                objects.append(HitObject(startTime: time, endTime: time, position: position, kind: .circle,
                                         newCombo: newCombo, colorIndex: colorIndex,
                                         indexInCombo: indexInCombo, hitSound: hitSound))
            } else if isSlider {
                guard p.count >= 8, let slides = Int(p[6]), slides >= 1, let length = Double(p[7]),
                      let path = parseSliderPath(p[5], head: position, length: length) else { continue }
                let (beatLength, sv) = timing(at: time, in: beatmap.timingPoints)
                let scoringDistance = 100 * beatmap.difficulty.sliderMultiplier * sv
                let velocity = beatLength > 0 ? scoringDistance / beatLength : 0
                let tickRate = beatmap.difficulty.sliderTickRate
                let tickDistance = tickRate > 0 ? scoringDistance / tickRate : 0
                let slider = OsuSlider(path: path, slides: slides, length: length, velocity: velocity,
                                    tickDistance: tickDistance, startTime: time, startPosition: position)
                objects.append(HitObject(startTime: time, endTime: slider.endTime, position: position,
                                         kind: .slider(slider), newCombo: newCombo, colorIndex: colorIndex,
                                         indexInCombo: indexInCombo, hitSound: hitSound))
            } else {
                guard p.count >= 6, let end = Double(p[5]) else { continue }
                objects.append(HitObject(startTime: time, endTime: max(end, time), position: position, kind: .spinner,
                                         newCombo: newCombo, colorIndex: colorIndex,
                                         indexInCombo: indexInCombo, hitSound: hitSound))
            }
        }
        return objects
    }

    private static func parseSliderPath(_ spec: String, head: Vec2, length: Double) -> SliderPath? {
        let tokens = spec.split(separator: "|", omittingEmptySubsequences: true)
        guard let first = tokens.first, let letter = first.first else { return nil }
        let type: SliderPathType
        switch letter {
        case "L": type = .linear
        case "C": type = .catmull
        case "P": type = .perfectCurve
        default: type = .bezier
        }
        var points: [Vec2] = [.zero]
        for token in tokens.dropFirst() {
            let xy = token.split(separator: ":")
            guard xy.count == 2, let px = Float(xy[0]), let py = Float(xy[1]) else { return nil }
            points.append(Vec2(px, py) - head)
        }
        return SliderPath(pathType: type, controlPoints: points, expectedDistance: length)
    }
}
