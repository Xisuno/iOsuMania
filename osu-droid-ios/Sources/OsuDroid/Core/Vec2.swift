import Foundation

/// 2D float vector. Mirrors com.osudroid.math.Vector2 (Float components, exact equality).
struct Vec2: Equatable, Hashable {
    var x: Float
    var y: Float

    init(_ x: Float, _ y: Float) { self.x = x; self.y = y }
    init(_ v: Float) { self.x = v; self.y = v }

    static let zero = Vec2(0, 0)

    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    static func * (a: Vec2, s: Float) -> Vec2 { Vec2(a.x * s, a.y * s) }

    var lengthSquared: Float { x * x + y * y }
    var length: Float { lengthSquared.squareRoot() }

    func distanceSquared(to o: Vec2) -> Float { (self - o).lengthSquared }
    func distance(to o: Vec2) -> Float { (self - o).length }
}

enum Precision {
    static let floatEpsilon: Float = 1e-3
    static let doubleEpsilon: Double = 1e-7

    static func almostEquals(_ a: Float, _ b: Float, _ tolerance: Float = floatEpsilon) -> Bool {
        abs(a - b) <= tolerance
    }

    static func almostEquals(_ a: Double, _ b: Double, _ tolerance: Double = doubleEpsilon) -> Bool {
        abs(a - b) <= tolerance
    }
}
