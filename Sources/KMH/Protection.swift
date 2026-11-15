//
//  Protection.swift — KeepMyMacHealthy
//  Malware & adware check (launch agents, daemons, unsigned apps, known adware names) and privacy cleanup.
//  Copyright © 2026 Abhiram Upadrashta (Bubbles Aro). MIT License.
//

import SwiftUI
import Security

enum CodeSign {
    /// nil = signed & valid; otherwise a short reason.
    static func problem(_ u: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(u as CFURL, [], &code) == errSecSuccess, let c = code else { return "Can't be checked" }
        let r = SecStaticCodeCheckValidity(c, SecCSFlags(rawValue: 0), nil)
        if r == errSecSuccess { return nil }
        if r == errSecCSUnsigned { return "Not signed by any developer" }
        return "Signature is broken or was changed"
    }
    static func team(_ u: URL) -> String? {
        var code: SecStaticCode?; var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(u as CFURL, [], &code) == errSecSuccess, let c = code,
              SecCodeCopySigningInformation(c, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        return d[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

enum Malware {
    /// Families of well-known Mac adware / PUPs (matched against labels, paths and app names).
    static let known = ["genieo", "vsearch", "pirrit", "bundlore", "shlayer", "adload", "mughthesec", "searchmine", "crossrider",
                        "installcore", "spigot", "chumsearch", "safefinder", "advancedmaccleaner", "macsearch", "searchbaron",
                        "mykotlerino", "conduit", "operatorsearch", "searchpulse", "amc", "mackeeper", "cleanup-mac", "zeoticus",
                        "silverSparrow", "xcsset", "cimpli", "geneio", "weknow", "anysearch", "searchmarquis", "pcvark", "tarmac",
                        "ondeviceinstall", "updater.helper", "mmsearch", "searchrange", "smartsearch", "launchupdater"]
        .map { $0.lowercased() }

    static func matchesKnown(_ s: String) -> Bool {
        let l = s.lowercased()
        return known.contains { k in k.count > 3 && l.contains(k) }
    }

    static let launchDirs: [URL] = [FS.h("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")]

    static func scan(progress: (String) -> Void) -> [ItemGroup] {
        var threats: [Item] = [], review: [Item] = []
        for d in launchDirs {
            progress("Checking \(d.path)…")
            for p in FS.children(d) where p.pathExtension == "plist" {
                guard let dict = NSDictionary(contentsOf: p) as? [String: Any] else { continue }
                let label = dict["Label"] as? String ?? p.lastPathComponent
                let prog = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first ?? ""
                if label.hasPrefix("com.apple.") { continue }
                let exe = URL(fileURLWithPath: prog)
                if matchesKnown(label) || matchesKnown(prog) {
                    threats.append(Item(url: p, size: FS.size(p), selected: true, note: "Known adware: \(label)"))
                } else if prog.hasPrefix("/tmp") || prog.hasPrefix("/private/tmp") || prog.contains("/.") {
                    threats.append(Item(url: p, size: FS.size(p), selected: true, note: "Runs a hidden or temporary program: \(prog)"))
                } else if !prog.isEmpty && !FS.exists(exe) && !prog.hasPrefix("/usr/") && !prog.hasPrefix("/bin/") {
                    review.append(Item(url: p, size: FS.size(p), selected: true, note: "Broken: its program no longer exists"))
                } else if !prog.isEmpty, FS.exists(exe), !prog.hasPrefix("/usr/"), !prog.hasPrefix("/bin/"), !prog.hasPrefix("/System/"),
                          let why = CodeSign.problem(exe) {
                    review.append(Item(url: p, size: FS.size(p), selected: false, note: "\(why) — \(prog)"))
                }
            }
        }
        progress("Checking apps…")
        for root in [URL(fileURLWithPath: "/Applications"), FS.h("Applications")] {
            for a in FS.children(root, hidden: false) where a.pathExtension == "app" {
                if matchesKnown(a.deletingPathExtension().lastPathComponent) {
                    threats.append(Item(url: a, size: FS.size(a), selected: true, note: "Known unwanted app"))
                } else if let why = CodeSign.problem(a), why != "Can't be checked" {
                    review.append(Item(url: a, size: FS.size(a), selected: false, note: why))
                }
            }
        }
        progress("Checking Downloads…")
        for f in FS.children(FS.h("Downloads"), hidden: false) where ["app", "pkg", "dmg", "command", "sh"].contains(f.pathExtension.lowercased()) {
            if matchesKnown(f.lastPathComponent) { threats.append(Item(url: f, size: FS.size(f), selected: true, note: "Known adware installer")) }
        }
        var g: [ItemGroup] = []
        if !threats.isEmpty { g.append(ItemGroup(id: "threats", name: "Threats", icon: "exclamationmark.shield.fill", detail: "Adware and suspicious background programs", items: threats)) }
        if !review.isEmpty { g.append(ItemGroup(id: "review", name: "Worth a look", icon: "questionmark.diamond", detail: "Broken or unsigned items — remove only if you don't know them", items: review)) }
        let ext = browserExtensions()
        if !ext.isEmpty { g.append(ItemGroup(id: "ext", name: "Browser extensions", icon: "puzzlepiece.extension", detail: "Chrome, Edge and Brave extensions — remove the ones you don't use", items: ext)) }
        return g
    }

    static func browserExtensions() -> [Item] {
        let roots = ["Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser"].map { FS.h("Library/Application Support/\($0)/Default/Extensions") }
        var out: [Item] = []
        for r in roots {
            for e in FS.children(r, hidden: false) {
                guard let ver = FS.children(e, hidden: false).first,
                      let d = try? Data(contentsOf: ver.appendingPathComponent("manifest.json")),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      var name = j["name"] as? String else { continue }
                if name.hasPrefix("__MSG_") { name = "Extension \(e.lastPathComponent.prefix(8))" }
                let browser = r.pathComponents.dropLast(2).last ?? ""
                out.append(Item(url: e, size: FS.size(e), selected: matchesKnown(name), note: "\(name) · \(browser)"))
            }
        }
        return out
    }

    /// Removes the selected items, unloading launch agents first. Items in /Library need the admin password.
    static func remove(_ groups: [ItemGroup]) -> Int {
        let urls = groups.selectedURLs
        var adminPaths: [String] = []
        var n = 0
        for u in urls {
            if u.pathExtension == "plist", u.path.contains("/LaunchAgents/") || u.path.contains("/LaunchDaemons/") {
                if u.path.hasPrefix(FS.home.path) { Shell.run("launchctl bootout gui/\(getuid()) '\(u.path)' 2>/dev/null") }
            }
            if FS.remove([u]).failed.isEmpty { n += 1 } else { adminPaths.append(u.path) }
        }
        if !adminPaths.isEmpty {
            let trash = FS.h(".Trash").path
            let cmd = adminPaths.map { p in
                (p.contains("/LaunchDaemons/") ? "launchctl bootout system '\(p)' 2>/dev/null; " : "") + "mv -f '\(p)' '\(trash)/' "
            }.joined(separator: "; ")
            if Shell.admin(cmd, prompt: "KeepMyMacHealthy needs your password to remove protected items.") { n += adminPaths.count }
        }
        return n
    }
}

enum Privacy {
    struct Browser { let name: String; let bundle: String; let files: [URL] }
    static func chromium(_ path: String) -> [URL] {
        let base = FS.h("Library/Application Support/\(path)")
        let profiles = FS.children(base, hidden: false).filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
        return profiles.flatMap { p in ["History", "History-journal", "Cookies", "Cookies-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts"].map { p.appendingPathComponent($0) } }
    }
    static var browsers: [Browser] {
        [
            Browser(name: "Safari", bundle: "com.apple.Safari", files: ["History.db", "History.db-shm", "History.db-wal", "LastSession.plist", "RecentlyClosedTabs.plist"].map { FS.h("Library/Safari/\($0)") }
                    + [FS.h("Library/Cookies/Cookies.binarycookies"), FS.h("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")]),
            Browser(name: "Google Chrome", bundle: "com.google.Chrome", files: chromium("Google/Chrome")),
            Browser(name: "Microsoft Edge", bundle: "com.microsoft.edgemac", files: chromium("Microsoft Edge")),
            Browser(name: "Brave", bundle: "com.brave.Browser", files: chromium("BraveSoftware/Brave-Browser")),
            Browser(name: "Firefox", bundle: "org.mozilla.firefox", files: FS.children(FS.h("Library/Application Support/Firefox/Profiles")).flatMap { p in
                ["places.sqlite", "places.sqlite-wal", "cookies.sqlite", "cookies.sqlite-wal", "formhistory.sqlite", "sessionstore.jsonlz4"].map { p.appendingPathComponent($0) } }),
        ]
    }

    static func scan() -> [ItemGroup] {
        var g: [ItemGroup] = []
        for b in browsers {
            let items = b.files.filter { FS.exists($0) }.map { Item(url: $0, size: FS.size($0), selected: true, note: b.name) }
            if !items.isEmpty { g.append(ItemGroup(id: b.bundle, name: b.name, icon: "globe", detail: "Browsing history, cookies, top sites and recent tabs. Passwords are never touched.", items: items)) }
        }
        let recents = FS.children(FS.h("Library/Application Support/com.apple.sharedfilelist"))
            .flatMap { FS.isDir($0) ? FS.children($0) : [$0] }.filter { $0.lastPathComponent.contains("RecentDocuments") || $0.lastPathComponent.contains("RecentApplications") || $0.lastPathComponent.contains("RecentServers") }
        if !recents.isEmpty { g.append(ItemGroup(id: "recent", name: "Recent items", icon: "clock.arrow.circlepath", detail: "Lists of recently opened documents, apps and servers", items: recents.map { Item(url: $0, size: FS.size($0), selected: true) })) }
        return g
    }

    static func running(_ groups: [ItemGroup]) -> [NSRunningApplication] {
        let ids = Set(groups.filter { $0.selectedCount > 0 }.map(\.id))
        return NSWorkspace.shared.runningApplications.filter { ids.contains($0.bundleIdentifier ?? "") }
    }
}

@MainActor
final class ProtectionModel: ObservableObject {
    static let shared = ProtectionModel()
    @Published var phase: Phase = .idle
    @Published var tab = 0             // 0 malware, 1 privacy
    @Published var groups: [ItemGroup] = []
    @Published var privacy: [ItemGroup] = []
    var threatCount: Int { groups.first { $0.id == "threats" }?.items.count ?? 0 }

    func scan() async {
        phase = .scanning("Checking for malware…")
        let g = await Task.detached { Malware.scan { t in Task { @MainActor in ProtectionModel.shared.phase = .scanning(t) } } }.value
        let p = await Task.detached { Privacy.scan() }.value
        groups = g; privacy = p
        phase = .results
    }

    func removeThreats() async {
        let sel = groups
        phase = .working("Removing…")
        let n = Malware.remove(sel)
        phase = .done(n == 0 ? "Nothing was removed." : "\(n) item\(n == 1 ? "" : "s") moved to the Trash. Restart your Mac to make sure nothing keeps running.")
    }

    func cleanPrivacy() async {
        let open = Privacy.running(privacy)
        if !open.isEmpty {
            guard confirm("Quit browsers first?", "\(open.compactMap(\.localizedName).joined(separator: ", ")) must be closed to clear its history and cookies.", ok: "Quit & Clean") else { return }
            open.forEach { $0.terminate() }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        let sel = privacy
        phase = .working("Clearing traces…")
        let r = await Task.detached { FS.remove(sel.selectedURLs) }.value
        phase = .done("Privacy traces cleared" + (r.failed.isEmpty ? "." : ". Some items need Full Disk Access (Settings → Privacy & Security)."))
    }
}

struct ProtectionView: View {
    @ObservedObject var m = ProtectionModel.shared
    let tint = Module.protection.tint
    var body: some View {
        VStack(spacing: 0) {
            switch m.phase {
            case .idle:
                ModuleIntro(symbol: "hand.raised.fill", tint: tint, title: "Protection", subtitle: "Find adware, suspicious background programs and broken apps, and wipe your browsing traces.",
                            bullets: [("ant.fill", "Adware & malware"), ("gearshape.arrow.triangle.2.circlepath", "Launch agents & daemons"), ("checkmark.seal", "App signatures"), ("eye.slash", "Browser privacy")])
                BigButton(title: "Scan", tint: tint) { Task { await m.scan() } }.padding(.bottom, 30)
            case .scanning(let t), .working(let t):
                ScanningView(tint: tint, text: t)
            case .results:
                ResultsHeader(title: m.threatCount > 0 ? "\(m.threatCount) threat\(m.threatCount == 1 ? "" : "s") found" : "No threats found",
                              subtitle: m.threatCount > 0 ? "Remove them now. Items under “Worth a look” are only suggestions." : "Your Mac looks safe. You can still review items and clear privacy traces.", tint: tint) { m.phase = .idle }
                Picker("", selection: $m.tab) { Text("Malware").tag(0); Text("Privacy").tag(1) }.pickerStyle(.segmented).frame(width: 260).padding(.bottom, 8)
                if m.tab == 0 {
                    if m.groups.isEmpty { Spacer(); Label("Nothing suspicious found", systemImage: "checkmark.shield.fill").foregroundStyle(tint).font(.title3); Spacer() }
                    else { GroupList(groups: $m.groups, tint: tint).padding(.horizontal, 20) }
                    BigButton(title: "Remove", tint: tint) { Task { await m.removeThreats() } }.padding(.vertical, 18).disabled(m.groups.selectedURLs.isEmpty)
                } else {
                    GroupList(groups: $m.privacy, tint: tint).padding(.horizontal, 20)
                    BigButton(title: "Clear", tint: tint) { Task { await m.cleanPrivacy() } }.padding(.vertical, 18)
                }
            case .done(let d):
                DoneView(tint: tint, title: "Protected", detail: d) { m.phase = .idle }
            }
        }
    }
}
