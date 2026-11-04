import SwiftUI

/// The singles of Tama ♥ Party, wandering around town: they walk to places, stop to look around,
/// and when two of them meet they stop and chat in speech bubbles.
final class WanderSim {
    struct Actor {
        var id: UUID
        var name: String
        var x: Double           // 0...1 across the scene
        var lane: Double        // 0...1 down the scene (further down = closer)
        var tx: Double          // where it is walking to
        var tlane: Double
        var speed: Double
        var state: State = .idle
        var until: Double = 0   // when the current state ends
        var facing: Double = 1  // 1 = right
        var phase: Double
        var line: String = ""
        var lineUntil: Double = 0
        var partner: Int = -1
        var script: [(Double, String)] = []   // (time to say it, what)
    }
    enum State { case idle, walk, talk }

    private(set) var actors: [Actor] = []
    private var last: Double = 0
    private var cooldown: [String: Double] = [:]

    private static let greet = ["Hi, %@!", "Oh, hello %@!", "%@! Nice to see you!", "Hey %@!"]
    private static let answer = ["Hello, %@!", "Hi %@! How are you?", "%@! What a surprise!", "Hey there, %@!"]
    private static let talk = ["Lovely weather today.", "Have you tried the Arcade?", "I'm looking for someone special.",
                               "I heard there's a party!", "I love the castle.", "Want to take a walk?",
                               "I made a new friend today!", "Tama ♥ Party is so fun.", "I could use a snack.", "The sky is so pretty."]
    private static let reply = ["Me too!", "That sounds lovely.", "Oh, I'd like that!", "Ha ha, so true!", "Let's go together sometime.",
                                "Really? Tell me more!", "I think so too.", "Maybe later!"]
    private static let solo = ["La la la~", "Hmm...", "So sunny!", "What a nice day.", "I wonder who is here."]

    /// Make the actors match the singles shown (keeps positions when they stay).
    func sync(_ suitors: [Suitor], now: Double) {
        let ids = suitors.map(\.id)
        if ids == actors.map(\.id) { return }
        var next: [Actor] = []
        for (i, s) in suitors.enumerated() {
            if let old = actors.first(where: { $0.id == s.id }) { next.append(old); continue }
            let x = Double.random(in: 0.08...0.92)
            let lane = 0.76 + Double(i % 3) * 0.06
            next.append(Actor(id: s.id, name: s.name, x: x, lane: lane, tx: x, tlane: lane,
                              speed: Double.random(in: 0.045...0.075), state: .idle,
                              until: now + Double.random(in: 0.2...2.5), phase: Double.random(in: 0...6.3)))
        }
        actors = next
    }

    func step(now: Double) {
        let dt = min(0.1, max(0, now - last))
        last = now
        guard dt > 0 else { return }
        // conversations first
        for i in actors.indices {
            guard actors[i].state == .talk else { continue }
            if let n = actors[i].script.first, now >= n.0 {
                actors[i].line = n.1; actors[i].lineUntil = now + 2.3
                actors[i].script.removeFirst()
            }
            if now >= actors[i].until { actors[i].state = .idle; actors[i].until = now; actors[i].partner = -1; actors[i].line = "" }
            else if actors[i].line != "", now > actors[i].lineUntil { actors[i].line = "" }
        }
        for i in actors.indices where actors[i].state != .talk {
            switch actors[i].state {
            case .idle:
                if actors[i].line != "", now > actors[i].lineUntil { actors[i].line = "" }
                if now >= actors[i].until { chooseWalk(i, now) }
            case .walk:
                let dx = actors[i].tx - actors[i].x, dl = actors[i].tlane - actors[i].lane
                let dist = (dx * dx + dl * dl * 0.6).squareRoot()
                if dist < 0.012 {
                    actors[i].state = .idle
                    actors[i].until = now + Double.random(in: 1.5...5)
                    if Int.random(in: 0..<5) == 0 { actors[i].line = WanderSim.solo.randomElement()!; actors[i].lineUntil = now + 2.2 }
                } else {
                    let step = min(dist, actors[i].speed * dt)
                    actors[i].x += dx / dist * step
                    actors[i].lane += dl / dist * step * 0.8
                    if abs(dx) > 0.004 { actors[i].facing = dx > 0 ? 1 : -1 }
                }
            case .talk: break
            }
        }
        // two who are close and free stop to chat
        for i in actors.indices {
            for j in actors.indices where j > i {
                guard actors[i].state != .talk, actors[j].state != .talk else { continue }
                let key = actors[i].name + "+" + actors[j].name
                if let c = cooldown[key], now < c { continue }
                if abs(actors[i].x - actors[j].x) < 0.11 && abs(actors[i].lane - actors[j].lane) < 0.07 {
                    startChat(i, j, now)
                    cooldown[key] = now + Double.random(in: 14...25)
                }
            }
        }
    }

    private func chooseWalk(_ i: Int, _ now: Double) {
        // sometimes go and say hello to someone, otherwise wander to a new spot
        if actors.count > 1, Int.random(in: 0..<3) == 0, let other = actors.indices.filter({ $0 != i }).randomElement(), actors[other].state != .talk {
            let side: Double = actors[i].x < actors[other].x ? -1 : 1
            actors[i].tx = min(0.94, max(0.06, actors[other].x + side * 0.09))
            actors[i].tlane = actors[other].lane
        } else {
            actors[i].tx = Double.random(in: 0.06...0.94)
            actors[i].tlane = Double.random(in: 0.74...0.90)
        }
        actors[i].state = .walk
    }

    private func startChat(_ i: Int, _ j: Int, _ now: Double) {
        let a = actors[i], b = actors[j]
        let lines = Int.random(in: 3...4)
        var sa: [(Double, String)] = [], sb: [(Double, String)] = []
        var t = now + 0.3
        for k in 0..<lines {
            let first = k % 2 == 0
            let text: String
            switch k {
            case 0: text = String(format: WanderSim.greet.randomElement()!, b.name.capitalized)
            case 1: text = String(format: WanderSim.answer.randomElement()!, a.name.capitalized)
            case 2: text = WanderSim.talk.randomElement()!
            default: text = WanderSim.reply.randomElement()!
            }
            if first { sa.append((t, text)) } else { sb.append((t, text)) }
            t += 2.5
        }
        let end = t + 0.2
        actors[i].state = .talk; actors[j].state = .talk
        actors[i].until = end; actors[j].until = end
        actors[i].partner = j; actors[j].partner = i
        actors[i].script = sa; actors[j].script = sb
        actors[i].line = ""; actors[j].line = ""
        actors[i].facing = actors[j].x >= actors[i].x ? 1 : -1
        actors[j].facing = -actors[i].facing
    }
}

/// A speech bubble above a sprite.
struct SpeechBubble: View {
    let text: String
    let size: CGFloat
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding(.horizontal, size * 0.7).padding(.vertical, size * 0.45)
            .background(
                RoundedRectangle(cornerRadius: size * 0.9, style: .continuous).fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.9, style: .continuous).stroke(Color.black.opacity(0.35), lineWidth: 1))
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: size * 11)
    }
}
