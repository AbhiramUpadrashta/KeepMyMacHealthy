//
//  SmartCare.swift — KeepMyMacHealthy
//  One scan that checks everything, then one click to take care of it.
//  Copyright © 2026 Abhiram Upadrashta (Bubbles Aro). MIT License.
//

import SwiftUI

@MainActor
final class Stats: ObservableObject {
    static let shared = Stats()
    @AppStorage("totalFreed") var totalFreed: Double = 0
    func add(freed: Int64) { totalFreed += Double(freed); objectWillChange.send() }
}

@MainActor
final class SmartCareModel: ObservableObject {
    static let shared = SmartCareModel()
    @Published var phase: Phase = .idle
    @Published var step = ""
    @Published var progress = 0.0

    func scan() async {
        phase = .scanning("Starting…"); progress = 0
        let steps: [(String, () async -> Void)] = [
            ("Looking for junk…", { await CleanupModel.shared.scan() }),
            ("Checking for threats…", { await ProtectionModel.shared.scan() }),
            ("Checking speed…", { await PerformanceModel.shared.scan() }),
            ("Looking at your apps…", { await AppsModel.shared.scan() }),
            ("Finding clutter…", { await ClutterModel.shared.scan() }),
        ]
        for (i, s) in steps.enumerated() {
            step = s.0; phase = .scanning(s.0)
            await s.1()
            progress = Double(i + 1) / Double(steps.count)
        }
        phase = .results
    }

    func run() async {
        phase = .working("Taking care of your Mac…")
        var lines: [String] = []
        let junk = CleanupModel.shared.groups
        let freed = await Task.detached { Junk.clean(junk) }.value
        Stats.shared.add(freed: freed)
        CleanupModel.shared.phase = .idle
        lines.append("\(FS.fmt(freed)) of junk removed")
        let threats = ProtectionModel.shared.groups.filter { $0.id == "threats" }
        if !threats.isEmpty { lines.append("\(Malware.remove(threats)) threats removed") }
        ProtectionModel.shared.phase = .idle
        Shell.run("dscacheutil -flushcache")
        phase = .done(lines.joined(separator: " · ") + ".")
    }
}

struct SmartCareView: View {
    @ObservedObject var m = SmartCareModel.shared
    @ObservedObject var clean = CleanupModel.shared
    @ObservedObject var prot = ProtectionModel.shared
    @ObservedObject var perf = PerformanceModel.shared
    @ObservedObject var apps = AppsModel.shared
    @ObservedObject var clutter = ClutterModel.shared
    @ObservedObject var health = Health.shared
    @Binding var module: Module
    let tint = Module.smartCare.tint

    var body: some View {
        VStack(spacing: 0) {
            switch m.phase {
            case .idle:
                VStack(spacing: 16) {
                    Spacer()
                    ScoreRing(score: health.score, tint: tint)
                    Text("Welcome back").font(.system(size: 30, weight: .bold))
                    Text("Start a Smart Care scan to clean junk, check for threats, speed things up and review your apps and files — all at once.")
                        .foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center).frame(maxWidth: 480)
                    if !FS.hasFullDiskAccess {
                        Button { FS.openFullDiskAccess() } label: { Label("Allow Full Disk Access for a complete scan", systemImage: "lock.open") }.buttonStyle(.bordered).tint(KM.amber)
                    }
                    Spacer()
                }
                BigButton(title: "Scan", tint: tint) { Task { await m.scan() } }.padding(.bottom, 30)
            case .scanning(let t):
                VStack(spacing: 18) {
                    Spacer()
                    ZStack {
                        Circle().stroke(tint.opacity(0.15), lineWidth: 12)
                        Circle().trim(from: 0, to: max(0.03, m.progress)).stroke(KM.brand, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.5), value: m.progress)
                        Text("\(Int(m.progress * 100))%").font(.system(size: 30, weight: .bold)).monospacedDigit()
                    }.frame(width: 170, height: 170)
                    Text(m.step).font(.system(size: 15, weight: .semibold))
                    Text(t == m.step ? " " : t).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
            case .results:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Here's what we found").font(.system(size: 26, weight: .bold))
                    Text("Run takes care of the safe stuff. Review any tile to decide yourself.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 22)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    tile(.cleanup, "Cleanup", FS.fmt(clean.groups.selectedTotal), "of junk to remove")
                    tile(.protection, "Protection", prot.threatCount == 0 ? "Safe" : "\(prot.threatCount)", prot.threatCount == 0 ? "no threats found" : "threats to remove")
                    tile(.performance, "Performance", "\(perf.selectedTasks)", "tasks to speed things up")
                    tile(.applications, "Applications", "\(apps.updates.count)", "app updates available")
                    tile(.clutter, "My Clutter", FS.fmt(clutter.groups.reduce(0) { $0 + $1.total }), "of files to review")
                    tile(.health, "Health", "\(health.score)", "health score")
                }
                .padding(28)
                Spacer()
                BigButton(title: "Run", tint: tint) { Task { await m.run() } }.padding(.bottom, 30)
            case .working(let t):
                ScanningView(tint: tint, text: t)
            case .done(let d):
                DoneView(tint: tint, title: "Your Mac is healthy", detail: d) { m.phase = .idle }
            }
        }
    }

    private func tile(_ mod: Module, _ title: String, _ big: String, _ small: String) -> some View {
        Button { module = mod } label: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: mod.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32).background(Circle().fill(mod.tint.gradient))
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(big).font(.system(size: 24, weight: .bold)).monospacedDigit()
                    Text(small).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ScoreRing: View {
    let score: Int; let tint: Color
    @State private var shown = 0.0
    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.12)).frame(width: 190, height: 190)
            Circle().stroke(.white.opacity(0.08), lineWidth: 12).frame(width: 160, height: 160)
            Circle().trim(from: 0, to: shown).stroke(KM.brand, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90)).frame(width: 160, height: 160)
                .shadow(color: KM.pink.opacity(0.5), radius: 10)
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: 44, weight: .bold)).monospacedDigit()
                Text("Health score").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 1.2)) { shown = Double(score) / 100 } }
        .onChange(of: score) { _, v in withAnimation { shown = Double(v) / 100 } }
    }
}
