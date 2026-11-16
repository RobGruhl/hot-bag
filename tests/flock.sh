#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hot-bag-flock.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation
import CoreGraphics
func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(),message) }
// The user's actual stacked and staggered three-screen layout, in AppKit points.
let screens = [CGRect(x:0,y:0,width:1512,height:982),CGRect(x:-1823,y:982,width:2560,height:1440),CGRect(x:737,y:982,width:2560,height:1440)]
let desktop = Desktop(screens:screens)
check(desktop.portal(0,1)!.x == 368.5,"Left upper seam must use overlap")
check(desktop.portal(0,2)!.x == 1124.5,"Right upper seam must use overlap")
check(desktop.portal(1,2)!.x == 737,"Upper side-by-side seam")
let flock = Flock(screens:screens)
flock.antagonistEnabled = false
flock.birds = [Bird(position:Vector(x:400,y:981),velocity:Vector(x:0,y:100),size:100,phase:0)]
flock.update(0.03)
check(flock.birds[0].position.y>982 && flock.birds[0].position.y<990,"Cross shared vertical seam continuously")
check(desktop.index(flock.birds[0].position)==1,"Arrive on actual upper-left display")
flock.birds = [Bird(position:Vector(x:738,y:1500),velocity:Vector(x:-100,y:0),size:100,phase:0)]
flock.update(0.03)
check(desktop.index(flock.birds[0].position)==1,"Cross upper horizontal seam")
let stopped = flock.birds[0].position
flock.paused = true; flock.update(1)
check(flock.birds[0].position.x==stopped.x,"Pause")
flock.paused = false
flock.birds = [Bird(position:Vector(x:200,y:400),velocity:Vector(x:-60,y:0),size:100,phase:0),Bird(position:Vector(x:210,y:400),velocity:Vector(x:-60,y:0),size:100,phase:0)]
flock.update(0.1)
check(flock.birds[1].position.x-flock.birds[0].position.x>10,"Separate close neighbors")
let calm = Flock(bounds:CGRect(x:0,y:0,width:2000,height:1600)), scared = Flock(bounds:CGRect(x:0,y:0,width:2000,height:1600))
let bird = Bird(position:Vector(x:1000,y:800),velocity:.zero,size:100,phase:0)
calm.birds=[bird]; scared.birds=[bird]; calm.antagonistEnabled=false
scared.dragon.position=Vector(x:900,y:800); scared.dragon.velocity = .zero
calm.update(0.1); scared.update(0.1)
check(scared.birds[0].velocity.x>calm.birds[0].velocity.x+10,"Flee approaching dragon")
// Test on a known distribution, including monitor seams, with the moving HUD.
let live = Flock(screens:screens)
live.birds = (0..<24).map { i in
    let r = screens[i%3]
    return Bird(position:Vector(x:r.minX+100+Double(i*173%1000),y:r.minY+180+Double(i*113%600)),velocity:Vector(x:80,y:30),size:100,phase:Double(i%8))
}
var visited = Set<Int>()
for step in 0..<12000 {
    let box = CGRect(x:300+sin(Double(step)/1000)*160,y:350,width:560,height:142)
    live.obstacles=[box]
    live.update(1.0/30)
    for b in live.birds+[live.dragon] {
        check(b.position.x.isFinite && b.position.y.isFinite,"Finite positions")
        check(desktop.contains(b.position),"Stay on real displays, not empty bounding-box corners")
        check(b.velocity.length<=292,"Bounded flight speed")
        check(!box.insetBy(dx:-b.size*0.7,dy:-b.size*0.7).contains(b.position.point),"Do not overlap HUD")
    }
    visited.insert(desktop.index(live.birds[0].position))
}
check(visited.count==3,"Individual toaster should visit all three displays")
live.setScreens([screens[0]])
check(live.birds.allSatisfy { screens[0].contains($0.position.point) },"Hot unplug relocates flock")
// A real close-range encounter must emit, hit once, eject and refill.
let breakfast = Flock(bounds:CGRect(x:0,y:0,width:2000,height:1600))
breakfast.birds = [Bird(position:Vector(x:1100,y:800),velocity:.zero,size:120,phase:0)]
breakfast.dragon.position=Vector(x:1000,y:800)
breakfast.dragon.velocity=Vector(x:70,y:0)
breakfast.update(0.01)
check(breakfast.breath != nil,"Close dragon starts butter breath")
check(breakfast.flyingToast.isEmpty,"Breath must travel before toast pops")
for _ in 0..<12 { breakfast.update(0.04) }
check(breakfast.popCount==1 && breakfast.flyingToast.count==1,"One hit ejects one slice")
check(breakfast.birds[0].toastReadyAt>breakfast.time+6,"Empty toaster enters cooldown")
check(!breakfast.crumbs.isEmpty,"Pop emits crumbs")
let frozen = breakfast.flyingToast[0].position, frozenTime=breakfast.time
breakfast.paused=true; breakfast.update(5)
check(breakfast.time==frozenTime && breakfast.flyingToast[0].position.x==frozen.x,"Pause freezes breath, cooldown and flying toast")
breakfast.paused=false
for _ in 0..<20 { breakfast.update(0.04) }
check(breakfast.popCount==1,"Same breath cannot eject twice")
breakfast.antagonistEnabled=false
for _ in 0..<400 { breakfast.update(0.04) }
check(breakfast.time>=breakfast.birds[0].toastReadyAt,"Fresh toast returns after cooldown")
check(breakfast.flyingToast.isEmpty && breakfast.crumbs.isEmpty && breakfast.breath==nil,"Transient effects clean up after flight")
breakfast.obstacles=[CGRect(x:950,y:600,width:100,height:400)]
check(!breakfast.clearButterPath(from:Vector(x:900,y:800),to:Vector(x:1100,y:800)),"Butter cannot pass through HUD")
check(live.popCount>0,"Normal flock simulation produces butter attacks")
check(live.flyingToast.count<=6 && live.crumbs.count<=30,"Transient effect storage remains bounded")
print("PASS: 3-screen topology, crossings, HUD avoidance, 400-second roaming, hot unplug; butter breath travel, one-hit ejection, crumbs, pause, refill, offscreen cleanup and bounded effects")
SWIFT
# precondition remains active with -O (plain Swift assert does not).
swiftc -O -module-cache-path "$TMP/cache" "$ROOT/screensaver/Flock.swift" "$ROOT/screensaver/Breakfast.swift" "$TMP/main.swift" -o "$TMP/check"
"$TMP/check"
