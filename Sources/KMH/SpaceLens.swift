//
//  SpaceLens.swift — KeepMyMacHealthy
//  A sunburst map of what fills your disk. Click a slice to dive in.
//  Copyright © 2026 Abhiram Upadrashta (Bubbles Aro). MIT License.
//

import SwiftUI

struct Node: Identifiable {
    var id: String { url.path }
    let url: URL; let size: Int64; let dir: Bool
}

@MainActor
final class LensModel: ObservableObject {
    static let shared = LensModel()
    @Published var path: [URL] = []
    @Published var nodes: [Node] = []
    @Published var loading = false
    @Published var hovered: String?
    private var cache: [String: [Node]] = [:]

    var current: URL? { path.last }
    var total: Int64 { nodes.reduce(0) { $0 + $1.size } }

    func open(_ u: URL) async {
        if let i = path.firstIndex(of: u) { path = Array(path.prefix(i + 1)) } else { path.append(u) }
        if let c = cache[u.path] { nodes = c; return }
        loading = true; nodes = []
        let list = await Task.detached { () -> [Node] in
            let kids = FS.children(u)
            return await withTaskGroup(of: Node.self) { g in
                for k in kids { g.addTask { Node(url: k, size: FS.size(k), dir: FS.isDir(k) && k.pathExtension != "app") } }
                var out: [Node] = []
                for await n in g { out.append(n) }
                return out.filter { $0.size > 0 }.sorted { $0.size > $1.size }
            }
        }.value
        cache[u.path] = list
        if current == u { nodes = list }
        loading = false
    }

    func up() { guard path.count > 1 else { return }; path.removeLast(); if let u = path.last { nodes = cache[u.path] ?? [] } }
    func trash(_ n: Node) {
        guard confirm("Move \(n.url.lastPathComponent) to the Trash?", FS.fmt(n.size), ok: "Move to Trash") else { return }
        if FS.remove([n.url]).failed.isEmpty {
            nodes.removeAll { $0.id == n.id }
            if let c = current { cache[c.path] = nodes }
            for p in path.dropLast() { cache[p.path] = nil }
            Stats.shared.add(freed: n.size)
        }
    }
}

struct SpaceLensView: View {
    @ObservedObject var m = LensModel.shared
    let tint = Module.lens.tint
    static let palette: [Color] = [KM.blue, KM.pink, KM.mint, KM.amber, Color(red: 0.7, green: 0.55, blue: 1), Color(red: 0.35, green: 0.85, blue: 1), KM.red]

    var body: some View {
        if m.path.isEmpty {
            VStack(spacing: 0) {
                ModuleIntro(symbol: "circle.hexagongrid.fill", tint: tint, title: "Space Lens", subtitle: "See what's taking up your storage as an interactive map and clear the biggest folders in a click.")
                HStack(spacing: 20) {
                    BigButton(title: "Home", tint: tint) { Task { await m.open(FS.home) } }
                    BigButton(title: "Disk", tint: tint.opacity(0.8)) { Task { await m.open(URL(fileURLWithPath: "/")) } }
                }.padding(.bottom, 30)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button { m.up() } label: { Image(systemName: "chevron.left") }.disabled(m.path.count < 2).buttonStyle(.borderless)
                    ForEach(m.path, id: \.self) { p in
                        Button(p.path == "/" ? "Macintosh HD" : p.lastPathComponent) { Task { await m.open(p) } }.buttonStyle(.borderless)
                        if p != m.path.last { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Close") { m.path = [] }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 24).padding(.top, 18)
                HStack(spacing: 20) {
                    ZStack {
                        if m.loading { ProgressView().controlSize(.large) } else { Sunburst(nodes: Array(m.nodes.prefix(24)), total: m.total, hovered: $m.hovered) { n in if n.dir { Task { await m.open(n.url) } } } }
                        VStack(spacing: 2) {
                            Text(FS.fmt(m.nodes.first { $0.id == m.hovered }?.size ?? m.total)).font(.system(size: 20, weight: .bold)).monospacedDigit()
                            Text(m.nodes.first { $0.id == m.hovered }?.url.lastPathComponent ?? (m.current?.lastPathComponent ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 120)
                        }
                    }
                    .frame(width: 330, height: 330)
                    List(m.nodes) { n in
                        HStack {
                            Circle().fill(Self.palette[(m.nodes.firstIndex { $0.id == n.id } ?? 0) % Self.palette.count]).frame(width: 8, height: 8)
                            Image(nsImage: NSWorkspace.shared.icon(forFile: n.url.path)).resizable().frame(width: 18, height: 18)
                            Text(n.url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Text(FS.fmt(n.size)).monospacedDigit().foregroundStyle(.secondary)
                            Button { m.trash(n) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if n.dir { Task { await m.open(n.url) } } }
                        .onHover { h in m.hovered = h ? n.id : nil }
                    }
                    .scrollContentBackground(.hidden)
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
            }
        }
    }
}

struct Sunburst: View {
    let nodes: [Node]; let total: Int64
    @Binding var hovered: String?
    let tap: (Node) -> Void
    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let slices = layout()
            ZStack {
                ForEach(slices, id: \.0.id) { s in
                    ArcSlice(start: s.1, end: s.2, inner: r * 0.45, outer: r * (s.0.id == hovered ? 1 : 0.94))
                        .fill(SpaceLensView.palette[s.3 % SpaceLensView.palette.count].gradient.opacity(s.0.id == hovered ? 1 : 0.8))
                        .overlay(ArcSlice(start: s.1, end: s.2, inner: r * 0.45, outer: r * 0.94).stroke(Color.black.opacity(0.35), lineWidth: 1))
                        .animation(.spring(response: 0.3), value: hovered)
                }
            }
            .contentShape(Circle())
            .onContinuousHover { p in
                if case .active(let pt) = p { hovered = hit(pt, c, r, slices)?.id } else { hovered = nil }
            }
            .onTapGesture { pt in if let n = hit(pt, c, r, slices) { tap(n) } }
        }
    }
    private func layout() -> [(Node, Double, Double, Int)] {
        let t = Double(max(total, 1)); var a = -Double.pi / 2; var out: [(Node, Double, Double, Int)] = []
        for (i, n) in nodes.enumerated() {
            let sweep = max(0.01, Double(n.size) / t * 2 * .pi)
            out.append((n, a, a + sweep, i)); a += sweep
        }
        return out
    }
    private func hit(_ p: CGPoint, _ c: CGPoint, _ r: CGFloat, _ s: [(Node, Double, Double, Int)]) -> Node? {
        let dx = p.x - c.x, dy = p.y - c.y, d = sqrt(dx * dx + dy * dy)
        guard d > r * 0.45, d < r else { return nil }
        var ang = atan2(dy, dx); if ang < -Double.pi / 2 { ang += 2 * .pi }
        return s.first { ang >= $0.1 && ang < $0.2 }?.0
    }
}

struct ArcSlice: Shape {
    var start: Double, end: Double, inner: CGFloat, outer: CGFloat
    var animatableData: CGFloat { get { outer } set { outer = newValue } }
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        p.closeSubpath()
        return p
    }
}
