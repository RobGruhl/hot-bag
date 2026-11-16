import Foundation
import CoreGraphics

struct ButterBreath {
    var target: Int
    var started: Double
    var source: Vector
    var destination: Vector
    var hit = false
}
struct FlyingToast {
    var position: Vector
    var velocity: Vector
    var born: Double
    var size: Double
    var spin: Double
}
struct Crumb {
    var position: Vector
    var velocity: Vector
    var born: Double
    var lifetime: Double
    var size: Double
}

extension Flock {
    var dragonMouth: Vector {
        dragon.position + Vector(x: dragon.velocity.x > 0 ? dragon.size*0.23 : -dragon.size*0.23, y:dragon.size*0.05)
    }
    func clearButterPath(from a: Vector, to b: Vector) -> Bool {
        // Sample at <=8pt spacing; the padded HUD is much wider than that.
        let steps = max(1,Int((b-a).length/8)+1)
        return (0...steps).allSatisfy { i in
            let p = a + (b-a)*(Double(i)/Double(steps))
            return desktop.contains(p) && !obstacles.contains { $0.insetBy(dx:-22,dy:-22).contains(p.point) }
        }
    }
    func updateBreakfast(_ dt: Double) {
        // All effects share simulation time, so pause freezes the entire gag.
        for i in flyingToast.indices {
            var toast = flyingToast[i]
            var force = Vector(x:0,y:65)
            let probe = Bird(position:toast.position,velocity:toast.velocity,size:toast.size,phase:0)
            // Toast escapes the desktop; only avoid the HUD, never bounce at screens.
            for box in obstacles {
                let padded = box.insetBy(dx:-toast.size*0.7-20,dy:-toast.size*0.7-20)
                let ahead = toast.position+toast.velocity*0.3
                if padded.contains(ahead.point) { force = force+(outside(ahead,rect:padded)-ahead).unit()*1100 }
            }
            toast.velocity = (probe.velocity+force*dt).limited(950)
            toast.position = toast.position+toast.velocity*dt
            for box in obstacles { toast.position = outside(toast.position,rect:box.insetBy(dx:-toast.size*0.7,dy:-toast.size*0.7)) }
            flyingToast[i] = toast
        }
        flyingToast.removeAll { toast in
            time-toast.born>18 || (time-toast.born>0.5 && !desktop.screens.contains { $0.insetBy(dx:-toast.size,dy:-toast.size).contains(toast.position.point) })
        }
        for i in crumbs.indices {
            crumbs[i].velocity.y -= 90*dt
            crumbs[i].position = crumbs[i].position+crumbs[i].velocity*dt
        }
        crumbs.removeAll { time-$0.born > $0.lifetime }
        if var puff = breath {
            guard birds.indices.contains(puff.target) else { breath = nil; return }
            puff.source = dragonMouth
            puff.destination = birds[puff.target].position+Vector(x:0,y:birds[puff.target].size*0.14)
            let age = time-puff.started
            if !puff.hit && age>=0.38 {
                if time >= birds[puff.target].toastReadyAt && (puff.destination-puff.source).length<340 && clearButterPath(from:puff.source,to:puff.destination) {
                    popToast(at:puff.target)
                    puff.hit = true
                } else { breath = nil; return }
            }
            breath = age < 0.85 ? puff : nil
        } else if antagonistEnabled && chasing && time>=nextBreathAt {
            let candidates = birds.indices.filter { time>=birds[$0].toastReadyAt && (birds[$0].position-dragonMouth).length<235 }
            if let target = candidates.min(by: { (birds[$0].position-dragonMouth).length < (birds[$1].position-dragonMouth).length }),
               clearButterPath(from:dragonMouth,to:birds[target].position) {
                // Face the recipient before exhaling, so the puff starts at the mouth.
                let sign = birds[target].position.x >= dragon.position.x ? 1.0 : -1.0
                dragon.velocity.x = sign*max(25,abs(dragon.velocity.x))
                breath = ButterBreath(target:target,started:time,source:dragonMouth,destination:birds[target].position)
                nextBreathAt = time+3.2
            }
        }
    }
    func popToast(at index: Int) {
        let bird = birds[index]
        guard time>=bird.toastReadyAt else { return }
        birds[index].toastReadyAt = time+8+Double(index%4)
        birds[index].poppedAt = time
        // Recoil is visual and a small impulse; normal collision integration follows.
        birds[index].velocity = (bird.velocity+Vector(x:0,y:-55)).limited(250)
        let direction = bird.position.x >= dragon.position.x ? 1.0 : -1.0
        let slot = bird.position+Vector(x:0,y:bird.size*0.18)
        flyingToast.append(FlyingToast(position:slot,velocity:Vector(x:direction*(200+Double(index%3)*40),y:380),born:time,size:bird.size*0.50,spin:direction*(3.5+Double(index%3))))
        for j in 0..<15 {
            let angle = Double(j)*2.39996
            let velocity = Vector(x:cos(angle)*(60+Double(j)*7),y:sin(angle)*130+80)
            crumbs.append(Crumb(position:slot,velocity:velocity,born:time,lifetime:0.6+Double(j%5)*0.12,size:Double(2+j%3)))
        }
        // At most one pop per cooldown; cleanup above bounds all transient storage.
        popCount += 1
    }
}
