import Foundation
import CoreGraphics

struct Vector {
    var x: Double, y: Double
    static let zero = Vector(x: 0, y: 0)
    static func + (a: Vector, b: Vector) -> Vector { Vector(x: a.x+b.x, y: a.y+b.y) }
    static func - (a: Vector, b: Vector) -> Vector { Vector(x: a.x-b.x, y: a.y-b.y) }
    static func * (a: Vector, b: Double) -> Vector { Vector(x: a.x*b, y: a.y*b) }
    var length: Double { hypot(x, y) }
    var point: CGPoint { CGPoint(x: x, y: y) }
    func limited(_ maximum: Double) -> Vector { length > maximum ? self * (maximum / length) : self }
    func unit() -> Vector { length > 0.001 ? self * (1 / length) : .zero }
}
struct Bird {
    var position: Vector
    var velocity: Vector
    var size: Double
    var phase: Double
    var toastReadyAt = 0.0
    var poppedAt = -1000.0
}
struct Desktop {
    var screens: [CGRect]
    var bounds: CGRect { screens.dropFirst().reduce(screens[0]) { $0.union($1) } }
    func contains(_ p: Vector) -> Bool { screens.contains { $0.contains(p.point) } }
    func nearest(_ p: Vector) -> Vector {
        screens.map { r in Vector(x: min(r.maxX-1, max(r.minX+1, p.x)), y: min(r.maxY-1, max(r.minY+1, p.y))) }
            .min { ($0-p).length < ($1-p).length } ?? p
    }
    func index(_ p: Vector) -> Int {
        screens.firstIndex { $0.contains(p.point) } ?? screens.indices.min { a, b in
            hypot(screens[a].midX-p.x, screens[a].midY-p.y) < hypot(screens[b].midX-p.x, screens[b].midY-p.y)
        } ?? 0
    }
    // Shared-edge portals preserve the user's staggered/stacked monitor layout.
    func portal(_ a: Int, _ b: Int) -> Vector? {
        let r = screens[a], s = screens[b]
        let loY = max(r.minY,s.minY), hiY = min(r.maxY,s.maxY)
        let loX = max(r.minX,s.minX), hiX = min(r.maxX,s.maxX)
        if hiY-loY > 2 && (abs(r.maxX-s.minX)<2 || abs(s.maxX-r.minX)<2) {
            return Vector(x: abs(r.maxX-s.minX)<2 ? r.maxX : r.minX, y: (loY+hiY)/2)
        }
        if hiX-loX > 2 && (abs(r.maxY-s.minY)<2 || abs(s.maxY-r.minY)<2) {
            return Vector(x: (loX+hiX)/2, y: abs(r.maxY-s.minY)<2 ? r.maxY : r.minY)
        }
        return nil
    }
    func waypoint(from p: Vector, to target: Int) -> Vector {
        let start = index(p), goal = screens[target]
        if start == target { return Vector(x: goal.midX, y: goal.midY) }
        var queue = [start], paths = [start: [Int]()]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for next in screens.indices where paths[next] == nil && portal(current,next) != nil {
                let path = paths[current]! + [next]
                paths[next] = path; queue.append(next)
                if next == target, let hop = path.first, let seam = portal(start,hop) {
                    let r = screens[hop]
                    return seam + (Vector(x:r.midX,y:r.midY)-seam).unit() * 130
                }
            }
        }
        // Disconnected display islands cannot be crossed without invisible travel.
        let r = screens[start]; return Vector(x:r.midX,y:r.midY)
    }
}
final class Flock {
    var birds: [Bird] = []
    var desktop: Desktop
    var bounds: CGRect { desktop.bounds }
    var time = 0.0
    var paused = false
    var obstacles: [CGRect] = []
    var dragon: Bird
    var breath: ButterBreath?
    var flyingToast: [FlyingToast] = []
    var crumbs: [Crumb] = []
    var nextBreathAt = 0.0
    var popCount = 0
    var antagonistEnabled = true
    var chasing: Bool { time.truncatingRemainder(dividingBy: 18) < 11 }
    convenience init(bounds: CGRect) { self.init(screens: [bounds]) }
    init(screens: [CGRect]) {
        desktop = Desktop(screens: screens)
        dragon = Bird(position: Vector(x:screens[0].midX,y:screens[0].midY),velocity:Vector(x:80,y:40),size:140,phase:0)
        let area = screens.reduce(0.0) { $0 + $1.width*$1.height }
        let count = min(56, max(16, Int(area/120000)))
        for i in 0..<count {
            let r = screens[i % screens.count]
            birds.append(Bird(position: Vector(x: Double.random(in:r.minX...r.maxX), y:Double.random(in:r.minY...r.maxY)),velocity:Vector(x:Double.random(in:-100...100),y:Double.random(in:-80...80)),size:Double([100,120,144,112][i%4]),phase:Double.random(in:0..<8)))
        }
    }
    func setScreens(_ screens: [CGRect]) {
        desktop = Desktop(screens:screens)
        for i in birds.indices { birds[i].position = desktop.nearest(birds[i].position) }
        dragon.position = desktop.nearest(dragon.position)
    }
    // Nearest exit from a padded HUD. Predictive steering handles normal flight;
    // this also guarantees a moving panel never covers a sprite on contact.
    func outside(_ p: Vector, rect: CGRect) -> Vector {
        guard rect.contains(p.point) else { return p }
        let options = [Vector(x:rect.minX-1,y:p.y),Vector(x:rect.maxX+1,y:p.y),Vector(x:p.x,y:rect.minY-1),Vector(x:p.x,y:rect.maxY+1)]
        return options.filter { desktop.contains($0) }.min { ($0-p).length < ($1-p).length } ?? options.min { ($0-p).length < ($1-p).length }!
    }
    func avoidance(_ b: Bird) -> Vector {
        let ahead = b.position + b.velocity * 0.85
        var force = Vector.zero
        if !desktop.contains(ahead) { force = force + (desktop.nearest(ahead)-ahead)*4 }
        for rect in obstacles {
            let padded = rect.insetBy(dx:-b.size*0.7-24,dy:-b.size*0.7-24)
            for p in [b.position,ahead] where padded.contains(p.point) {
                force = force + (outside(p,rect:padded)-p).unit()*420
            }
        }
        return force
    }
    func integrate(_ bird: Bird, force: Vector, speed: Double, dt: Double) -> Bird {
        var b = bird
        b.velocity = (b.velocity + force.limited(300)*dt).limited(speed)
        b.position = b.position + b.velocity*dt
        if !desktop.contains(b.position) {
            let safe = desktop.nearest(b.position)
            if abs(safe.x-b.position.x)>0.01 { b.velocity.x *= -0.55 }
            if abs(safe.y-b.position.y)>0.01 { b.velocity.y *= -0.55 }
            b.position = safe
        }
        for rect in obstacles {
            let padded = rect.insetBy(dx:-b.size*0.7,dy:-b.size*0.7)
            let safe = outside(b.position,rect:padded)
            if (safe-b.position).length > 0 {
                if abs(safe.x-b.position.x)>0.01 { b.velocity.x = (safe.x>b.position.x ? 1 : -1)*max(45,abs(b.velocity.x)*0.5) }
                if abs(safe.y-b.position.y)>0.01 { b.velocity.y = (safe.y>b.position.y ? 1 : -1)*max(45,abs(b.velocity.y)*0.5) }
                b.position = safe
            }
        }
        return b
    }
    func update(_ dt: Double) {
        guard !paused, dt>0 else { return }
        time += dt
        let previous = birds
        if antagonistEnabled && !birds.isEmpty {
            // Chase a new individual, then take a leisurely looping breather.
            let loaded = birds.indices.filter { time >= birds[$0].toastReadyAt }
            let targetIndex = breath?.target ?? loaded.min { (birds[$0].position-dragon.position).length < (birds[$1].position-dragon.position).length } ?? (Int(time/6)*7+3)%birds.count
            let target = birds[targetIndex]
            let targetScreen = desktop.index(target.position)
            var goal = desktop.waypoint(from:dragon.position,to:targetScreen)
            if desktop.index(dragon.position) == targetScreen {
                goal = chasing ? target.position + target.velocity*0.7 : dragon.position + Vector(x:cos(time*0.7)*180,y:sin(time*0.7)*180)
            }
            let desired = (goal-dragon.position).unit() * (chasing ? 205 : 95)
            dragon = integrate(dragon,force:(desired-dragon.velocity)*1.6+avoidance(dragon),speed:chasing ? 205 : 105,dt:dt)
        }
        for i in birds.indices {
            let b = previous[i]
            let nearby = previous.indices.filter { $0 != i && (previous[$0].position-b.position).length<240 }
                .sorted { (previous[$0].position-b.position).length < (previous[$1].position-b.position).length }.prefix(6)
            var separation = Vector.zero, alignment = Vector.zero, cohesion = Vector.zero
            for j in nearby {
                let offset = previous[j].position-b.position, d = max(1,offset.length)
                alignment = alignment + previous[j].velocity
                cohesion = cohesion + offset
                if d < (b.size+previous[j].size)*0.6 { separation = separation-offset*(150/(d*d)) }
            }
            let away = b.position - (dragon.position + dragon.velocity*0.35)
            let panic = antagonistEnabled ? max(0,1-away.length/390) : 0
            var force = separation*190
            if !nearby.isEmpty {
                force = force + (alignment*(1/Double(nearby.count))-b.velocity)*0.35*(1-panic)
                force = force + cohesion*(0.055/Double(nearby.count))*(1-panic)
            }
            let destination = (Int(time/24)+i%3)%desktop.screens.count
            var goal = desktop.waypoint(from:b.position,to:destination)
            if desktop.index(b.position)==destination {
                let r = desktop.screens[destination], angle = time*(0.11+Double(i%3)*0.025)+b.phase
                goal = Vector(x:r.midX+cos(angle)*r.width*0.36,y:r.midY+sin(angle*1.3)*r.height*0.34)
            }
            let cruising = 105+Double(i%5)*9
            force = force + ((goal-b.position).unit()*cruising-b.velocity)*0.48
            // Individual handedness splits a chased group into curling streams.
            let side = Vector(x:-away.y,y:away.x).unit()*(i%2==0 ? 1 : -1)
            force = force + away.unit()*(panic*460) + side*(panic*150)
            force = force + Vector(x:cos(time*0.8+b.phase),y:sin(time*0.65+b.phase))*18
            force = force + avoidance(b)
            birds[i] = integrate(b,force:force,speed:cruising+panic*150,dt:dt)
        }
        updateBreakfast(dt)
    }
}
