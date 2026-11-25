import Foundation

enum SliderPathType { case catmull, bezier, linear, perfectCurve }

/// Port of com.osudroid.beatmaps.hitobjects.SliderPath. Control points are relative to the slider head.
final class SliderPath {
    let pathType: SliderPathType
    let controlPoints: [Vec2]
    let expectedDistance: Double
    private(set) var calculatedPath: [Vec2] = []
    private(set) var cumulativeLength: [Double] = []

    init(pathType: SliderPathType, controlPoints: [Vec2], expectedDistance: Double) {
        self.pathType = pathType
        self.controlPoints = controlPoints
        self.expectedDistance = expectedDistance
        calculatePath()
        calculateCumulativeLength()
    }

    func positionAt(_ progress: Double) -> Vec2 {
        let d = progressToDistance(progress)
        return interpolateVertices(indexOfDistance(d), d)
    }

    func pathToProgress(_ p0: Double, _ p1: Double) -> [Vec2] {
        let d0 = progressToDistance(p0)
        let d1 = progressToDistance(p1)
        var path: [Vec2] = []
        var i = 0
        while i < calculatedPath.count && i < cumulativeLength.count && cumulativeLength[i] < d0 { i += 1 }
        path.append(interpolateVertices(i, d0))
        while i < calculatedPath.count && i < cumulativeLength.count && cumulativeLength[i] <= d1 {
            path.append(calculatedPath[i])
            i += 1
        }
        path.append(interpolateVertices(i, d1))
        return path
    }

    private func calculatePath() {
        calculatedPath.removeAll()
        if controlPoints.isEmpty { return }
        calculatedPath.append(controlPoints[0])

        var spanStart = 0
        for i in 0..<controlPoints.count {
            if i == controlPoints.count - 1 || controlPoints[i] == controlPoints[i + 1] {
                let spanEnd = i + 1
                let span = Array(controlPoints[spanStart..<spanEnd])
                for t in calculateSubPath(span) where calculatedPath.last != t {
                    calculatedPath.append(t)
                }
                spanStart = spanEnd
            }
        }
    }

    private func calculateSubPath(_ points: [Vec2]) -> [Vec2] {
        switch pathType {
        case .linear: return PathApproximation.approximateLinear(points)
        case .perfectCurve:
            return points.count == 3 ? PathApproximation.approximateCircularArc(points)
                                     : PathApproximation.approximateBezier(points)
        case .catmull: return PathApproximation.approximateCatmull(points)
        case .bezier: return PathApproximation.approximateBezier(points)
        }
    }

    private func calculateCumulativeLength() {
        cumulativeLength = [0]
        var calculatedLength = 0.0
        if calculatedPath.count >= 2 {
            for i in 0..<(calculatedPath.count - 1) {
                calculatedLength += Double(calculatedPath[i + 1].distance(to: calculatedPath[i]))
                cumulativeLength.append(calculatedLength)
            }
        }

        if calculatedLength == expectedDistance { return }

        // osu-stable: no extension when the last two control points are equal and the path is too short.
        if controlPoints.count >= 2,
           controlPoints[controlPoints.count - 1] == controlPoints[controlPoints.count - 2],
           expectedDistance > calculatedLength {
            return
        }

        // The last length is always incorrect.
        cumulativeLength.removeLast()
        var pathEndIndex = calculatedPath.count - 1

        if calculatedLength > expectedDistance {
            while let last = cumulativeLength.last, last >= expectedDistance {
                cumulativeLength.removeLast()
                calculatedPath.remove(at: pathEndIndex)
                pathEndIndex -= 1
            }
        }

        if pathEndIndex <= 0 {
            cumulativeLength.append(0)
            return
        }

        let previousPoint = calculatedPath[pathEndIndex - 1]
        let endPoint = calculatedPath[pathEndIndex]
        let lengthSquared = endPoint.distanceSquared(to: previousPoint)
        let inverseLength: Float = lengthSquared == 0 ? 0 : 1 / lengthSquared.squareRoot()
        let extension_ = Float(expectedDistance - (cumulativeLength.last ?? 0))
        calculatedPath[pathEndIndex] = Vec2(
            previousPoint.x + (endPoint.x - previousPoint.x) * inverseLength * extension_,
            previousPoint.y + (endPoint.y - previousPoint.y) * inverseLength * extension_)
        cumulativeLength.append(expectedDistance)
    }

    private func progressToDistance(_ progress: Double) -> Double {
        min(max(progress, 0), 1) * expectedDistance
    }

    private func interpolateVertices(_ i: Int, _ d: Double) -> Vec2 {
        if calculatedPath.isEmpty { return .zero }
        if i <= 0 { return calculatedPath[0] }
        if i >= calculatedPath.count { return calculatedPath[calculatedPath.count - 1] }
        guard i < cumulativeLength.count else { return calculatedPath[calculatedPath.count - 1] }

        let p0 = calculatedPath[i - 1], p1 = calculatedPath[i]
        let d0 = cumulativeLength[i - 1], d1 = cumulativeLength[i]
        if Precision.almostEquals(d0, d1) { return p0 }

        let t = Float((d - d0) / (d1 - d0))
        return Vec2(p0.x + (p1.x - p0.x) * t, p0.y + (p1.y - p0.y) * t)
    }

    private func indexOfDistance(_ d: Double) -> Int {
        if cumulativeLength.isEmpty || d < cumulativeLength[0] { return 0 }
        if d >= cumulativeLength[cumulativeLength.count - 1] { return cumulativeLength.count }

        var l = 0
        var r = cumulativeLength.count - 2
        while l <= r {
            let pivot = l + ((r - l) >> 1)
            let length = cumulativeLength[pivot]
            if length < d { l = pivot + 1 }
            else if length > d { r = pivot - 1 }
            else { return pivot }
        }
        return l
    }
}
