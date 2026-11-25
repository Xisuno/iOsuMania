import Foundation

/// Port of com.osudroid.beatmaps.DroidHitWindow (src/com/osudroid/beatmaps/DroidHitWindow.kt).
struct DroidHitWindow {
    static let missWindow = 400.0
    var overallDifficulty: Double

    var great: Double { 75 + 5 * (5 - overallDifficulty) }
    var ok: Double { 150 + 10 * (5 - overallDifficulty) }
    var meh: Double { 250 + 10 * (5 - overallDifficulty) }
}

/// Port of BeatmapDifficulty.difficultyRange and the preempt/fade-in logic in HitObject.applyDefaults.
enum DifficultyRange {
    static let preemptMax = 1800.0, preemptMid = 1200.0, preemptMin = 450.0

    static func range(_ difficulty: Double, _ min: Double, _ mid: Double, _ max: Double) -> Double {
        if difficulty > 5 { return mid + (max - mid) * (difficulty - 5) / 5 }
        if difficulty < 5 { return mid + (mid - min) * (difficulty - 5) / 5 }
        return mid
    }

    static func preempt(ar: Double) -> Double {
        range(ar, preemptMax, preemptMid, preemptMin).rounded(.towardZero)
    }

    static func fadeIn(preempt: Double) -> Double { 400 * min(1, preempt / preemptMin) }
}

/// Port of CircleSizeCalculator for the Droid game mode (src/com/osudroid/utils/CircleSizeCalculator.kt).
enum CircleSize {
    static let objectRadius: Float = 64
    private static let brokenGamefieldRoundingAllowance: Float = 1.00041
    private static let droidStandardCSOffset: Float = 6.855634

    static func standardCSToStandardScale(_ cs: Float, applyFudge: Bool = false) -> Float {
        (1 - 0.7 * (cs - 5) / 5) / 2 * (applyFudge ? brokenGamefieldRoundingAllowance : 1)
    }

    /// Scale in a 480-unit-high playfield (see HitObject.screenSpaceGameplayScale = scale * height / 480).
    static func droidCSToDroidScale(_ cs: Float) -> Float {
        max(1e-3, standardCSToStandardScale(cs - droidStandardCSOffset, applyFudge: true))
    }
}
