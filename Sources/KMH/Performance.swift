//
//  Performance.swift — KeepMyMacHealthy
//  Maintenance tasks, login items / background agents and heavy apps.
//  Copyright © 2026 Abhiram Upadrashta (Bubbles Aro). MIT License.
//

import SwiftUI

struct Task1: Identifiable {
    let id: String, name: String, detail: String, icon: String, cmd: String
    var admin = true
    var on = false
}

struct Agent: Identifiable {
    let id = UUID()
    let url: URL, label: String, program: String
    var enabled: Bool
    var user: Bool { url.path.hasPrefix(FS.home.path) }
}

struct Heavy: Identifiable {
    let id: Int32
    let name: String, cpu: Double, memMB: Double
}

@MainActor
final class PerformanceModel: ObservableObject {
    static let shared = PerformanceModel()
    @Published var phase: Phase = .idle
    @Published var tab = 0
    @Published var tasks: [Task1] = [
        Task1(id: "ram", name: "Free up RAM", detail: "Clears inactive memory so apps have room to breathe", icon: "memorychip", cmd: "/usr/sbin/purge", on: true),
        Task1(id: "dns", name: "Flush DNS cache", detail: "Fixes websites that won't load or load the old version", icon: "network", cmd: "dscacheutil -flushcache; killall -HUP mDNSResponder", on: true),
        Task1(id: "scripts", name: "Run maintenance scripts", detail: "Rotates system logs and tidies temporary files", icon: "terminal", cmd: "/usr/sbin/periodic daily weekly monthly", on: true),
        Task1(id: "ls", name: "Rebuild Launch Services", detail: "Fixes duplicate apps in “Open With” and wrong default apps",
              icon: "square.stack.3d.up", cmd: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user", admin: false),
        Task1(id: "spot", name: "Reindex Spotlight", detail: "Fixes search that misses files (takes a while in the background)", icon: "magnifyingglass", cmd: "mdutil -E /"),
        Task1(id: "disk", name: "Verify startup disk", detail: "Checks the file system for problems", icon: "internaldrive", cmd: "diskutil verifyVolume /"),
        Task1(id: "tm", name: "Thin Time Machine snapshots", detail: "Frees space held by local backup snapshots", icon: "clock.arrow.circlepath", cmd: "tmutil thinlocalsnapshots / 999999999999 4"),
        Task1(id: "mail", name: "Speed up Mail", detail: "Compacts Mail's database (Mail must be closed)", icon: "envelope",
              cmd: "for f in ~/Library/Mail/V*/MailData/Envelope\\ Index; do sqlite3 \"$f\" vacuum; done", admin: false),
        Task1(id: "brew", name: "Clean up Homebrew", detail: "Removes old versions and downloads Homebrew keeps around", icon: "mug",
              cmd: "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; command -v brew >/dev/null && brew cleanup -s --prune=all", admin: false),
        Task1(id: "docker", name: "Clean up Docker", detail: "Removes stopped containers, unused networks, dangling images and build cache", icon: "shippingbox",
              cmd: "export PATH=/usr/local/bin:/opt/homebrew/bin:$HOME/.docker/bin:$PATH; command -v docker >/dev/null && docker system prune -f && docker builder prune -f", admin: false),
        Task1(id: "fonts", name: "Clear font caches", detail: "Fixes garbled or missing fonts", icon: "textformat", cmd: "atsutil databases -remove"),
    ]
    @Published var agents: [Agent] = []
    @Published var heavy: [Heavy] = []

    var selectedTasks: Int { tasks.filter(\.on).count }

    func scan() async {
        phase = .scanning("Looking at what runs on your Mac…")
        let a = await Task.detached { PerformanceModel.readAgents() }.value
        let h = await Task.detached { PerformanceModel.readHeavy() }.value
        agents = a; heavy = h
        phase = .results
    }

    nonisolated static func readAgents() -> [Agent] {
        let disabled = Shell.run("launchctl print-disabled gui/\(getuid())")
        var out: [Agent] = []
        for d in Malware.launchDirs {
            for p in FS.children(d) where p.pathExtension == "plist" {
                guard let dict = NSDictionary(contentsOf: p) as? [String: Any] else { continue }
                let label = dict["Label"] as? String ?? p.deletingPathExtension().lastPathComponent
                if label.hasPrefix("com.apple.") { continue }
                let prog = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first ?? ""
                out.append(Agent(url: p, label: label, program: prog, enabled: !disabled.contains("\"\(label)\" => disabled") && !disabled.contains("\"\(label)\" => true")))
            }
        }
        return out.sorted { $0.label < $1.label }
    }

    nonisolated static func readHeavy() -> [Heavy] {
        let out = Shell.run("ps -Aceo pid=,pcpu=,rss=,comm= -r | head -25")
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), let cpu = Double(f[1]), let rss = Double(f[2]) else { return nil }
            return Heavy(id: pid, name: String(f[3]), cpu: cpu, memMB: rss / 1024)
        }
        .filter { !["kernel_task", "WindowServer", "launchd"].contains($0.name) }
    }

    func runTasks() async {
        let chosen = tasks.filter(\.on)
        guard !chosen.isEmpty else { return }
        phase = .working("Running maintenance…")
        let admin = chosen.filter(\.admin).map(\.cmd).joined(separator: "; ")
        let user = chosen.filter { !$0.admin }
        var ok = true
        if chosen.contains(where: { $0.id == "mail" }) { NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.mail" }?.terminate() }
        await Task.detached { for t in user { Shell.run(t.cmd) } }.value
        if !admin.isEmpty { ok = await Task.detached { Shell.admin(admin, prompt: "KeepMyMacHealthy needs your password to run maintenance tasks.") }.value }
        phase = .done(ok ? "\(chosen.count) task\(chosen.count == 1 ? "" : "s") finished. Your Mac should feel snappier." : "Cancelled — nothing that needs your password was run.")
    }

    func toggle(_ a: Agent) {
        guard let i = agents.firstIndex(where: { $0.id == a.id }) else { return }
        let on = !a.enabled
        if a.user {
            Shell.run(on ? "launchctl enable gui/\(getuid())/\(a.label); launchctl bootstrap gui/\(getuid()) '\(a.url.path)'"
                         : "launchctl bootout gui/\(getuid()) '\(a.url.path)'; launchctl disable gui/\(getuid())/\(a.label)")
            agents[i].enabled = on
        } else {
            let domain = a.url.path.contains("LaunchDaemons") ? "system" : "gui/\(getuid())"
            let cmd = on ? "launchctl enable \(domain)/\(a.label); launchctl bootstrap \(domain) '\(a.url.path)'"
                         : "launchctl bootout \(domain) '\(a.url.path)'; launchctl disable \(domain)/\(a.label)"
            if Shell.admin(cmd, prompt: "KeepMyMacHealthy needs your password to change a system background item.") { agents[i].enabled = on }
        }
    }

    func remove(_ a: Agent) {
        guard confirm("Remove \(a.label)?", "Its launch file goes to the Trash and it stops starting automatically.", ok: "Remove") else { return }
        if a.user { Shell.run("launchctl bootout gui/\(getuid()) '\(a.url.path)'"); FS.remove([a.url]) }
        else {
            let domain = a.url.path.contains("LaunchDaemons") ? "system" : "gui/\(getuid())"
            _ = Shell.admin("launchctl bootout \(domain) '\(a.url.path)'; mv -f '\(a.url.path)' '\(FS.h(".Trash").path)/'", prompt: "KeepMyMacHealthy needs your password to remove a system background item.")
        }
        agents.removeAll { $0.id == a.id }
    }

    func quit(_ h: Heavy) {
        if let app = NSRunningApplication(processIdentifier: h.id) { app.terminate() } else { kill(h.id, SIGTERM) }
        heavy.removeAll { $0.id == h.id }
    }
}

struct PerformanceView: View {
    @ObservedObject var m = PerformanceModel.shared
    let tint = Module.performance.tint
    var body: some View {
        VStack(spacing: 0) {
            switch m.phase {
            case .idle:
                ModuleIntro(symbol: "bolt.fill", tint: tint, title: "Performance", subtitle: "Run maintenance tasks, control what starts with your Mac and quit apps that slow it down.",
                            bullets: [("wrench.and.screwdriver", "Maintenance tasks"), ("power", "Login & background items"), ("flame", "Heavy consumers"), ("memorychip", "Free up RAM")])
                BigButton(title: "Scan", tint: tint) { Task { await m.scan() } }.padding(.bottom, 30)
            case .scanning(let t), .working(let t):
                ScanningView(tint: tint, text: t)
            case .results:
                ResultsHeader(title: "\(m.selectedTasks) tasks recommended", subtitle: "Pick what to run. Background items and heavy apps are on the other tabs.", tint: tint) { m.phase = .idle }
                Picker("", selection: $m.tab) { Text("Maintenance").tag(0); Text("Background items (\(m.agents.count))").tag(1); Text("Heavy consumers").tag(2) }
                    .pickerStyle(.segmented).frame(width: 470).padding(.bottom, 8)
                Group {
                    if m.tab == 0 { tasksList } else if m.tab == 1 { agentsList } else { heavyList }
                }
                .padding(.horizontal, 20)
                if m.tab == 0 { BigButton(title: "Run", tint: tint) { Task { await m.runTasks() } }.padding(.vertical, 18) }
                else { Spacer(minLength: 12) }
            case .done(let d):
                DoneView(tint: tint, title: "Done", detail: d) { m.phase = .idle }
            }
        }
    }

    private var tasksList: some View {
        List {
            ForEach($m.tasks) { $t in
                HStack(spacing: 10) {
                    Toggle("", isOn: $t.on).toggleStyle(.checkbox).labelsHidden()
                    Image(systemName: t.icon).foregroundStyle(tint).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name).font(.system(size: 13, weight: .semibold))
                        Text(t.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if t.admin { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Asks for your password") }
                }.padding(.vertical, 3)
            }
        }.scrollContentBackground(.hidden)
    }

    private var agentsList: some View {
        VStack(alignment: .leading) {
            List(m.agents) { a in
                HStack {
                    Image(systemName: a.user ? "person.crop.circle" : "lock.shield").foregroundStyle(tint).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Text(a.program).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { a.enabled }, set: { _ in m.toggle(a) })).toggleStyle(.switch).labelsHidden()
                    Button { m.remove(a) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }.scrollContentBackground(.hidden)
            Button("Open Login Items in System Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            }.padding(.bottom, 8)
        }
    }

    private var heavyList: some View {
        List(m.heavy) { h in
            HStack {
                if let app = NSRunningApplication(processIdentifier: h.id), let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                } else { Image(systemName: "gearshape").frame(width: 20) }
                Text(h.name).lineLimit(1)
                Spacer()
                Text(String(format: "%.0f%% CPU", h.cpu)).monospacedDigit().foregroundStyle(h.cpu > 50 ? KM.red : .secondary).frame(width: 80, alignment: .trailing)
                Text(String(format: "%.0f MB", h.memMB)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                Button("Quit") { m.quit(h) }.controlSize(.small)
            }
        }.scrollContentBackground(.hidden)
    }
}
