# osu!droid for iOS (port, first playable slice)

Native Swift/SpriteKit port of the gameplay core of [osu!droid](https://github.com/osudroid/osu-droid).
It is **not** a recompile of the Android app: that app is built on AndEngine, Android Fragments, BASS-for-Android
and Room, none of which exist on iOS. The algorithms below were ported from the Android sources (Apache-2.0, see LICENSE.md).

Target: iOS 16.0+ (runs on 16.6), iPhone and iPad, landscape. Swift 5.9, Xcode 15.

## Build (GitHub Actions, no local Xcode needed)
Push this folder to a repository. `.github/workflows/ios.yml` (macos-14) will:
1. generate the Xcode project with XcodeGen from `project.yml` (ZIPFoundation 0.9.19 via SwiftPM),
2. run the unit tests in `Tests/OsuDroidTests` on an iPhone simulator,
3. build an **unsigned** `OsuDroidiOS-unsigned.ipa` and upload it as an artifact (sign/sideload it yourself).

Local equivalent on a Mac: `brew install xcodegen && xcodegen generate && open OsuDroidiOS.xcodeproj`.

## Using it
Tap **Import .osz**, pick beatmap archives, choose a difficulty, tap the circles. Songs are stored in the app's
Documents/Songs folder (file sharing is enabled, so they are visible in the Files app).

## What is ported (and from where)
| Swift file | Source in the Android project |
|---|---|
| Core/PathApproximation.swift | com/osudroid/utils/PathApproximation.kt (bezier, circular arc, catmull) |
| Core/SliderPath.swift | com/osudroid/beatmaps/hitobjects/SliderPath.kt |
| Core/HitWindow.swift | DroidHitWindow.kt, BeatmapDifficulty.difficultyRange, HitObject.applyDefaults, CircleSizeCalculator.kt (Droid scale) |
| Core/BeatmapParser.swift, Beatmap.swift | .osu parsing written against the file format; slider timing per osu! rules |
| Game/GameplayEngine.swift | simplified judgement/scoring (see below) |

## Known gaps (not implemented)
- No hit sounds, storyboard, background image, skins, multiplayer, online, replays, mods, pp/star rating, results saving.
- No object stacking, no HP drain/fail, no precise-mode hit windows.
- Scoring is ScoreV1-style with the difficulty multiplier fixed at 1; spinner requirement uses the lazer formula.
  These values are **uncalibrated** against osu!droid.
- Slider tick generation follows the osu!lazer algorithm; not yet compared with Slider.kt in the Android sources.
- Audio offset is a manual slider; no latency calibration.
- Renderer is SpriteKit (Metal-backed), chosen because it could not be tested here; a custom Metal renderer is a later step.

## Status of this delivery
Nothing here has been compiled or run: the authoring environment had no Swift toolchain. The first CI run is the first
compile, so expect to fix a few compiler errors; the CI log (`test-log` artifact) is the starting point.
