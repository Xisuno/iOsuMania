import Foundation

/// Port of com.osudroid.utils.PathApproximation (src/com/osudroid/utils/PathApproximation.kt).
enum PathApproximation {
    static let catmullDetail = 50
    private static let bezierTolerance: Float = 0.25
    private static let circularArcTolerance: Float = 0.1
    private static let bezierToleranceThreshold: Float = bezierTolerance * bezierTolerance * 4

    static func approximateLinear(_ controlPoints: [Vec2]) -> [Vec2] { controlPoints }

    static func approximateBezier(_ controlPoints: [Vec2]) -> [Vec2] {
        var output: [Vec2] = []
        let count = controlPoints.count - 1
        if count < 0 { return output }

        var toFlatten: [[Vec2]] = [controlPoints]
        var freeBuffers: [[Vec2]] = []
        var buffer1 = [Vec2](repeating: .zero, count: count + 1)
        var buffer2 = [Vec2](repeating: .zero, count: count * 2 + 1)

        while let popped = toFlatten.popLast() {
            var parent = popped
            if bezierIsFlatEnough(parent) {
                bezierApproximate(parent, &output, &buffer1, &buffer2, count + 1)
                freeBuffers.append(parent)
                continue
            }
            var rightChild = freeBuffers.popLast() ?? [Vec2](repeating: .zero, count: count + 1)
            var scratch = [Vec2](repeating: .zero, count: count + 1)
            bezierSubdivide(parent, &buffer2, &rightChild, &scratch, count + 1)
            for i in 0...count { parent[i] = buffer2[i] }
            toFlatten.append(rightChild)
            toFlatten.append(parent)
        }

        output.append(controlPoints[count])
        return output
    }

    static func approximateCatmull(_ controlPoints: [Vec2]) -> [Vec2] {
        var result: [Vec2] = []
        let inverseDetail = 1 / Float(catmullDetail)
        if controlPoints.count < 2 { return result }

        for i in 0..<(controlPoints.count - 1) {
            let v1 = i > 0 ? controlPoints[i - 1] : controlPoints[i]
            let v2 = controlPoints[i]
            let v3 = i < controlPoints.count - 1 ? controlPoints[i + 1] : Vec2(2 * v2.x - v1.x, 2 * v2.y - v1.y)
            let v4 = i < controlPoints.count - 2 ? controlPoints[i + 2] : Vec2(2 * v3.x - v2.x, 2 * v3.y - v2.y)
            for c in 0..<catmullDetail {
                result.append(catmullFindPoint(v1, v2, v3, v4, Float(c) * inverseDetail))
                result.append(catmullFindPoint(v1, v2, v3, v4, Float(c + 1) * inverseDetail))
            }
        }
        return result
    }

    static func approximateCircularArc(_ controlPoints: [Vec2]) -> [Vec2] {
        if controlPoints.count != 3 { return approximateBezier(controlPoints) }

        let a = controlPoints[0], b = controlPoints[1], c = controlPoints[2]

        // Collinear points cannot form a circle.
        if Precision.almostEquals(0, (b.y - a.y) * (c.x - a.x) - (b.x - a.x) * (c.y - a.y)) {
            return approximateBezier(controlPoints)
        }

        let d = 2 * (a.x * (b.y - a.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        let aSq = a.lengthSquared, bSq = b.lengthSquared, cSq = c.lengthSquared

        let centerX = (aSq * (b.y - c.y) + bSq * (c.y - a.y) + cSq * (a.y - b.y)) / d
        let centerY = (aSq * (c.x - b.x) + bSq * (a.x - c.x) + cSq * (b.x - a.x)) / d

        let radius = ((a.x - centerX) * (a.x - centerX) + (a.y - centerY) * (a.y - centerY)).squareRoot()

        let thetaStart = atan2(Double(a.y - centerY), Double(a.x - centerX))
        var thetaEnd = atan2(Double(c.y - centerY), Double(c.x - centerX))
        while thetaEnd < thetaStart { thetaEnd += 2 * Double.pi }

        var direction = 1.0
        var thetaRange = thetaEnd - thetaStart

        let orthoX = c.y - a.y
        let orthoY = -(c.x - a.x)
        if orthoX * (b.x - a.x) + orthoY * (b.y - a.y) < 0 {
            direction = -direction
            thetaRange = 2 * Double.pi - thetaRange
        }

        let amountPoints: Int
        if 2 * radius <= circularArcTolerance {
            amountPoints = 2
        } else {
            let denom = Double(2 * acos(1 - circularArcTolerance / radius))
            amountPoints = max(2, Int((thetaRange / denom).rounded(.up)))
        }

        var output: [Vec2] = []
        output.reserveCapacity(amountPoints)
        for i in 0..<amountPoints {
            let fraction = Double(i) / Double(amountPoints - 1)
            let theta = thetaStart + direction * fraction * thetaRange
            output.append(Vec2(centerX + Float(cos(theta)) * radius, centerY + Float(sin(theta)) * radius))
        }
        return output
    }

    // MARK: - Bezier helpers

    private static func bezierIsFlatEnough(_ cp: [Vec2]) -> Bool {
        if cp.count < 3 { return true }
        for i in 1..<(cp.count - 1) {
            let prev = cp[i - 1], current = cp[i], next = cp[i + 1]
            let dx = prev.x - current.x * 2 + next.x
            let dy = prev.y - current.y * 2 + next.y
            if dx * dx + dy * dy > bezierToleranceThreshold { return false }
        }
        return true
    }

    /// `buffer1` receives the right half, `buffer2` the left half followed by the right half minus its first point.
    private static func bezierApproximate(_ cp: [Vec2], _ output: inout [Vec2],
                                          _ buffer1: inout [Vec2], _ buffer2: inout [Vec2], _ count: Int) {
        var scratch = [Vec2](repeating: .zero, count: count)
        bezierSubdivide(cp, &buffer2, &buffer1, &scratch, count)
        if count > 1 {
            for k in 0..<(count - 1) { buffer2[count + k] = buffer1[1 + k] }
        }
        output.append(cp[0])
        for i in stride(from: 1, to: count - 1, by: 1) {
            let index = 2 * i
            let prev = buffer2[index - 1], current = buffer2[index], next = buffer2[index + 1]
            output.append(Vec2(0.25 * (prev.x + current.x * 2 + next.x),
                               0.25 * (prev.y + current.y * 2 + next.y)))
        }
    }

    private static func bezierSubdivide(_ cp: [Vec2], _ l: inout [Vec2], _ r: inout [Vec2],
                                        _ buffer: inout [Vec2], _ count: Int) {
        for i in 0..<count { buffer[i] = cp[i] }
        for i in 0..<count {
            l[i] = buffer[0]
            r[count - i - 1] = buffer[count - i - 1]
            for j in 0..<(count - i - 1) {
                let left = buffer[j], right = buffer[j + 1]
                buffer[j] = Vec2((left.x + right.x) * 0.5, (left.y + right.y) * 0.5)
            }
        }
    }

    private static func catmullFindPoint(_ v1: Vec2, _ v2: Vec2, _ v3: Vec2, _ v4: Vec2, _ t: Float) -> Vec2 {
        let t2 = t * t
        let t3 = t2 * t
        func axis(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
            0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return Vec2(axis(v1.x, v2.x, v3.x, v4.x), axis(v1.y, v2.y, v3.y, v4.y))
    }
}
