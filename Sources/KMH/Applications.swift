//
//  Applications.swift — KeepMyMacHealthy
//  Uninstaller with leftovers, orphaned files from deleted apps, app reset and an updater for Sparkle / App Store apps.
//  Copyright © 2026 Abhiram Upadrashta (Bubbles Aro). MIT License.
//

import SwiftUI
import CoreServices

struct AppInfo: Identifiable {
    var id: String { url.path }
    let url: URL, name: String, bundleID: String, version: String
    var size: Int64 = 0
    var lastUsed: Date?
    var appStore: Bool
    var feed: URL?
    var newVersion: String?
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

enum Apps {
    static let leftoverDirs = ["Application Support", "Caches", "Preferences", "Containers", "Group Containers", "Saved Application State",
                               "HTTPStorages", "WebKit", "Logs", "LaunchAgents", "Cookies", "Application Scripts", "Preferences/ByHost"]

    static func list() -> [AppInfo] {
        var out: [AppInfo] = []
        var roots = [URL(fileURLWithPath: "/Applications"), FS.h("Applications")]
        roots += FS.children(URL(fileURLWithPath: "/Applications"), hidden: false).filter { FS.isDir($0) && $0.pathExtension.isEmpty }
        for r in roots {
            for a in FS.children(r, hidden: false) where a.pathExtension == "app" {
                guard let b = Bundle(url: a), let id = b.bundleIdentifier, !id.hasPrefix("com.apple.") else { continue }
                let name = (b.infoDictionary?["CFBundleDisplayName"] as? String) ?? (b.infoDictionary?["CFBundleName"] as? String) ?? a.deletingPathExtension().lastPathComponent
                let ver = (b.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
                let feed = (b.infoDictionary?["SUFeedURL"] as? String).flatMap(URL.init(string:))
                let mas = FS.exists(a.appendingPathComponent("Contents/_MASReceipt/receipt"))
                let used = (MDItemCreateWithURL(nil, a as CFURL)).flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
                out.append(AppInfo(url: a, name: name, bundleID: id, version: ver, lastUsed: used, appStore: mas, feed: feed))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func leftovers(for app: AppInfo) -> [URL] {
        let keys = [app.bundleID, app.name, app.url.deletingPathExtension().lastPathComponent].filter { $0.count > 2 }
        var out: [URL] = []
        for d in leftoverDirs {
            for c in FS.children(FS.lib.appendingPathComponent(d)) {
                let n = c.lastPathComponent
                let base = n.replacingOccurrences(of: ".plist", with: "").replacingOccurrences(of: ".savedState", with: "")
                if keys.contains(where: { base == $0 || base.hasPrefix($0 + ".") || (d == "Group Containers" && base.hasSuffix("." + app.bundleID)) }) { out.append(c) }
            }
        }
        return out
    }

    /// Support files whose app is gone (bundle-id-looking names nobody owns any more).
    static func orphans(installed: [AppInfo]) -> [Item] {
        var ids = Set(installed.map { $0.bundleID.lowercased() })
        for a in FS.children(URL(fileURLWithPath: "/System/Applications"), hidden: false) { if let i = Bundle(url: a)?.bundleIdentifier { ids.insert(i.lowercased()) } }
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        ids.formUnion(running)
        var out: [Item] = []
        for d in ["Application Support", "Caches", "Containers", "Saved Application State", "Preferences", "HTTPStorages", "WebKit"] {
            for c in FS.children(FS.lib.appendingPathComponent(d), hidden: false) {
                var base = c.lastPathComponent.lowercased()
                for s in [".plist", ".savedstate", ".binarycookies"] { base = base.replacingOccurrences(of: s, with: "") }
                let parts = base.split(separator: ".")
                guard parts.count >= 3, !base.hasPrefix("com.apple"), !base.hasPrefix("group."), !base.hasPrefix("com.bubblesaro"),
                      ["com", "org", "net", "io", "app", "co", "dev", "me"].contains(String(parts[0])) else { continue }
                if ids.contains(base) || ids.contains(where: { base.hasPrefix($0 + ".") || $0.hasPrefix(base + ".") }) { continue }
                let s = FS.size(c)
                if s > 0 { out.append(Item(url: c, size: s, selected: false, note: d)) }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Newest version in a Sparkle appcast.
    static func latest(feed: URL) async -> String? {
        guard let (d, _) = try? await URLSession.shared.data(from: feed), let xml = String(data: d, encoding: .utf8) else { return nil }
        var best: String?
        for key in ["sparkle:shortVersionString=\"", "<sparkle:shortVersionString>", "sparkle:version=\"", "<sparkle:version>"] {
            var rest = Substring(xml)
            while let r = rest.range(of: key) {
                rest = rest[r.upperBound...]
                let v = String(rest.prefix { $0 != "\"" && $0 != "<" }).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty, best == nil || newer(v, than: best!) { best = v }
            }
            if best != nil { break }
        }
        return best
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }, y = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

@MainActor
final class AppsModel: ObservableObject {
    static let shared = AppsModel()
    @Published var phase: Phase = .idle
    @Published var tab = 0          // 0 uninstaller, 1 updater, 2 leftovers
    @Published var apps: [AppInfo] = []
    @Published var picked = Set<String>()
    @Published var orphans: [ItemGroup] = []
    @Published var search = ""
    @Published var sort = 0         // 0 name, 1 size, 2 last used
    var updates: [AppInfo] { apps.filter { $0.newVersion != nil } }

    func scan() async {
        phase = .scanning("Finding your apps…")
        let found = await Task.detached { Apps.list() }.value
        phase = .scanning("Measuring app sizes…")
        let list = await Task.detached { found.map { var a = $0; a.size = FS.size(a.url); return a } }.value
        apps = list
        phase = .scanning("Checking for updates…")
        await withTaskGroup(of: (String, String?).self) { g in
            for a in list { if let f = a.feed { g.addTask { (a.id, await Apps.latest(feed: f)) } } }
            for await (id, v) in g {
                if let v, let i = apps.firstIndex(where: { $0.id == id }), Apps.newer(v, than: apps[i].version) { apps[i].newVersion = v }
            }
        }
        phase = .scanning("Looking for leftovers of deleted apps…")
        let o = await Task.detached { Apps.orphans(installed: list) }.value
        orphans = o.isEmpty ? [] : [ItemGroup(id: "orphans", name: "Leftovers", icon: "shippingbox", detail: "Files left behind by apps you already deleted", items: o)]
        phase = .results
    }

    var shown: [AppInfo] {
        let f = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
        switch sort {
        case 1: return f.sorted { $0.size > $1.size }
        case 2: return f.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        default: return f
        }
    }

    func uninstall() async {
        let chosen = apps.filter { picked.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let left = chosen.flatMap(Apps.leftovers)
        let total = chosen.reduce(0) { $0 + $1.size } + left.reduce(0) { $0 + FS.size($1) }
        guard confirm("Uninstall \(chosen.count) app\(chosen.count == 1 ? "" : "s")?",
                      "\(chosen.map(\.name).joined(separator: ", "))\n\nThe app\(chosen.count == 1 ? "" : "s") and \(left.count) leftover file\(left.count == 1 ? "" : "s") (\(FS.fmt(total))) go to the Trash.", ok: "Uninstall") else { return }
        for a in chosen { NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == a.bundleID }.forEach { $0.terminate() } }
        phase = .working("Uninstalling…")
        try? await Task.sleep(nanoseconds: 800_000_000)
        var failed: [String] = []
        for a in chosen {
            if !FS.remove([a.url]).failed.isEmpty {
                if !Shell.admin("mv -f '\(a.url.path)' '\(FS.h(".Trash").path)/'", prompt: "KeepMyMacHealthy needs your password to remove \(a.name).") { failed.append(a.name) }
            }
        }
        FS.remove(left)
        Stats.shared.add(freed: total)
        picked.removeAll()
        phase = .done(failed.isEmpty ? "\(chosen.count) app\(chosen.count == 1 ? "" : "s") and their leftovers are in the Trash (\(FS.fmt(total)))." : "Couldn't remove: \(failed.joined(separator: ", ")).")
    }

    func reset(_ a: AppInfo) {
        let files = Apps.leftovers(for: a).filter { !$0.path.contains("/Containers/") || true }
        guard confirm("Reset \(a.name)?", "Its settings, caches and saved data (\(files.count) items) go to the Trash. The app stays installed, like new.", ok: "Reset") else { return }
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == a.bundleID }.forEach { $0.terminate() }
        FS.remove(files)
    }

    func removeOrphans() async {
        let sel = orphans
        phase = .working("Removing leftovers…")
        let r = await Task.detached { FS.remove(sel.selectedURLs) }.value
        Stats.shared.add(freed: r.freed)
        phase = .done("\(FS.fmt(r.freed)) of leftovers moved to the Trash.")
    }
}

struct ApplicationsView: View {
    @ObservedObject var m = AppsModel.shared
    let tint = Module.applications.tint
    var body: some View {
        VStack(spacing: 0) {
            switch m.phase {
            case .idle:
                ModuleIntro(symbol: "square.grid.2x2.fill", tint: tint, title: "Applications", subtitle: "Uninstall apps completely, clear what deleted apps left behind and keep everything up to date.",
                            bullets: [("trash.square", "Complete uninstaller"), ("arrow.down.app", "Updater"), ("shippingbox", "Leftovers"), ("arrow.counterclockwise", "Reset apps")])
                BigButton(title: "Scan", tint: tint) { Task { await m.scan() } }.padding(.bottom, 30)
            case .scanning(let t), .working(let t):
                ScanningView(tint: tint, text: t)
            case .results:
                ResultsHeader(title: "\(m.apps.count) apps · \(m.updates.count) update\(m.updates.count == 1 ? "" : "s")", subtitle: "Select apps to uninstall, update them, or clear leftovers.", tint: tint) { m.phase = .idle }
                Picker("", selection: $m.tab) { Text("Uninstaller").tag(0); Text("Updater (\(m.updates.count))").tag(1); Text("Leftovers").tag(2) }
                    .pickerStyle(.segmented).frame(width: 400).padding(.bottom, 8)
                if m.tab == 0 { uninstaller } else if m.tab == 1 { updater } else { leftovers }
            case .done(let d):
                DoneView(tint: tint, title: "Done", detail: d) { Task { await m.scan() } }
            }
        }
    }

    private var uninstaller: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search apps", text: $m.search).textFieldStyle(.roundedBorder).frame(width: 220)
                Picker("Sort", selection: $m.sort) { Text("Name").tag(0); Text("Size").tag(1); Text("Least used").tag(2) }.frame(width: 170)
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 6)
            List(m.shown) { a in
                HStack {
                    Toggle("", isOn: Binding(get: { m.picked.contains(a.id) }, set: { v in if v { m.picked.insert(a.id) } else { m.picked.remove(a.id) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Image(nsImage: a.icon).resizable().frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(a.name).font(.system(size: 13, weight: .medium))
                        Text("v\(a.version)" + (a.lastUsed.map { " · used " + $0.formatted(.relative(presentation: .named)) } ?? " · never opened"))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(FS.fmt(a.size)).monospacedDigit().foregroundStyle(.secondary)
                    Menu { Button("Reset app…") { m.reset(a) }; Button("Show in Finder") { FS.reveal(a.url) } } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).frame(width: 30)
                }
            }
            .scrollContentBackground(.hidden).padding(.horizontal, 20)
            BigButton(title: "Uninstall", tint: tint) { Task { await m.uninstall() } }.padding(.vertical, 16).disabled(m.picked.isEmpty)
        }
    }

    private var updater: some View {
        VStack {
            if m.updates.isEmpty {
                Spacer(); Label("All apps that can be checked are up to date", systemImage: "checkmark.circle.fill").foregroundStyle(tint); Spacer()
            } else {
                List(m.updates) { a in
                    HStack {
                        Image(nsImage: a.icon).resizable().frame(width: 26, height: 26)
                        Text(a.name).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(a.version) → \(a.newVersion ?? "")").monospacedDigit().foregroundStyle(tint)
                        Button("Update") { NSWorkspace.shared.open(a.url) }.help("Opens the app so its built-in updater installs the new version")
                    }
                }.scrollContentBackground(.hidden).padding(.horizontal, 20)
            }
            Button("Check App Store updates…") { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) }.padding(.bottom, 16)
        }
    }

    private var leftovers: some View {
        VStack {
            if m.orphans.isEmpty { Spacer(); Label("No leftovers found", systemImage: "checkmark.circle.fill").foregroundStyle(tint); Spacer() }
            else {
                GroupList(groups: $m.orphans, tint: tint).padding(.horizontal, 20)
                BigButton(title: "Remove", tint: tint) { Task { await m.removeOrphans() } }.padding(.vertical, 16).disabled(m.orphans.selectedURLs.isEmpty)
            }
        }
    }
}
