//
//  Cleanup.swift — KeepMyMacHealthy
//  System junk: caches, logs, browser caches, developer junk, Mail attachments, broken preferences, Trash bins…
//  Copyright © 2026 Abhiram Upadrashta (Bubbles Aro). MIT License.
//

import SwiftUI

struct JunkSpec {
    let id, name, icon, detail: String
    let roots: [URL]
    var on = true
    var permanent = false
    var filter: ((URL) -> Bool)? = nil
    var note: ((URL) -> String)? = nil
}

enum Junk {
    static let browserCaches: [URL] = [
        FS.h("Library/Caches/com.apple.Safari"), FS.h("Library/Caches/Google/Chrome"), FS.h("Library/Caches/Microsoft Edge"),
        FS.h("Library/Caches/BraveSoftware"), FS.h("Library/Caches/Firefox"), FS.h("Library/Caches/company.thebrowser.Browser"),
        FS.h("Library/Caches/com.operasoftware.Opera"), FS.h("Library/Caches/com.vivaldi.Vivaldi"),
    ]
    static let protectedCaches: Set<String> = ["com.apple.HomeKit", "CloudKit", "com.apple.akd", "com.apple.nsurlsessiond",
                                               "FamilyCircle", "com.apple.ap.adprivacyd", "com.bubblesaro.keepmymachealthy"]

    static var specs: [JunkSpec] {
        let browserNames = Set(browserCaches.map { $0.lastPathComponent })
        return [
            JunkSpec(id: "cache", name: "User cache files", icon: "internaldrive", detail: "Temporary files apps rebuild when needed",
                     roots: [FS.h("Library/Caches")], filter: { !browserNames.contains($0.lastPathComponent) && !protectedCaches.contains($0.lastPathComponent) && $0.lastPathComponent != "Google" }),
            JunkSpec(id: "logs", name: "System & app logs", icon: "doc.text", detail: "Old logs and crash reports",
                     roots: [FS.h("Library/Logs"), URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]),
            JunkSpec(id: "browser", name: "Browser caches", icon: "globe", detail: "Safari, Chrome, Edge, Brave, Firefox, Arc, Opera",
                     roots: browserCaches.filter { FS.exists($0) }, filter: nil),
            JunkSpec(id: "xcode", name: "Xcode junk", icon: "hammer", detail: "Derived data, old device support, simulator caches",
                     roots: [FS.h("Library/Developer/Xcode/DerivedData"), FS.h("Library/Developer/Xcode/iOS DeviceSupport"),
                             FS.h("Library/Developer/Xcode/watchOS DeviceSupport"), FS.h("Library/Developer/CoreSimulator/Caches")]),
            JunkSpec(id: "dev", name: "Developer caches", icon: "chevron.left.forwardslash.chevron.right", detail: "npm, Gradle, pip, Yarn and other tool caches",
                     roots: [FS.h(".npm/_cacache"), FS.h(".gradle/caches"), FS.h(".cache"), FS.h("Library/Caches/Yarn"), FS.h(".yarn/berry/cache"),
                             FS.h("Library/Caches/pnpm"), FS.h(".bun/install/cache"), FS.h("Library/Caches/go-build"), FS.h(".cargo/registry/cache"),
                             FS.h("Library/Caches/CocoaPods"), FS.h("Library/Caches/Homebrew"), FS.h(".m2/repository")],
                     filter: { !["huggingface", "lm-studio"].contains($0.lastPathComponent) }),
            JunkSpec(id: "ai", name: "AI tool caches", icon: "brain", detail: "Caches of ChatGPT, Claude, Cursor, VS Code, Copilot and model hubs (downloaded models are kept)",
                     roots: [FS.h("Library/Caches/com.openai.chat"), FS.h("Library/Caches/com.anthropic.claudefordesktop"), FS.h("Library/Caches/claude-cli-nodejs"),
                             FS.h("Library/Application Support/Cursor/Cache"), FS.h("Library/Application Support/Cursor/CachedData"),
                             FS.h("Library/Application Support/Code/Cache"), FS.h("Library/Application Support/Code/CachedData"),
                             FS.h("Library/Application Support/Code/CachedExtensionVSIXs"), FS.h(".cache/huggingface/xet"), FS.h(".cache/pip")]),
            JunkSpec(id: "mail", name: "Mail attachments", icon: "paperclip", detail: "Copies Mail saved when you opened attachments",
                     roots: [FS.h("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")]),
            JunkSpec(id: "prefs", name: "Broken preferences", icon: "gearshape.2", detail: "Damaged settings files that can't be read",
                     roots: [FS.h("Library/Preferences")], filter: { u in
                         guard u.pathExtension == "plist", let d = try? Data(contentsOf: u) else { return false }
                         return (try? PropertyListSerialization.propertyList(from: d, format: nil)) == nil }),
            JunkSpec(id: "installers", name: "Old installers", icon: "shippingbox", detail: "Disk images and packages in Downloads older than a week",
                     roots: [FS.h("Downloads")], on: false, filter: { u in
                         ["dmg", "pkg", "mpkg", "iso", "xip"].contains(u.pathExtension.lowercased()) &&
                         (FS.date(u, .contentModificationDateKey) ?? .now) < Date().addingTimeInterval(-7 * 86400) }),
            JunkSpec(id: "ios", name: "iOS backups & updates", icon: "iphone", detail: "Old iPhone/iPad backups and software updates",
                     roots: [FS.h("Library/Application Support/MobileSync/Backup"), FS.h("Library/iTunes/iPhone Software Updates"),
                             FS.h("Library/iTunes/iPad Software Updates")], on: false,
                     note: { u in (FS.date(u, .contentModificationDateKey)).map { "Last changed " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "" }),
            JunkSpec(id: "trash", name: "Trash bins", icon: "trash", detail: "Everything already in your Trash", roots: [FS.h(".Trash")], permanent: true),
        ]
    }

    /// Scans every category. Runs off the main thread.
    static func scan(progress: @escaping (String) -> Void) -> [ItemGroup] {
        var out: [ItemGroup] = []
        for s in specs {
            progress("Scanning \(s.name.lowercased())…")
            var items: [Item] = []
            for r in s.roots where FS.exists(r) {
                for c in FS.children(r) where (s.filter?(c) ?? true) && !Ignore.contains(c) {
                    let sz = FS.size(c)
                    if sz > 0 || s.id == "prefs" { items.append(Item(url: c, size: sz, selected: s.on, note: s.note?(c) ?? "")) }
                }
            }
            items.sort { $0.size > $1.size }
            if !items.isEmpty { out.append(ItemGroup(id: s.id, name: s.name, icon: s.icon, detail: s.detail, items: items, permanent: s.permanent)) }
        }
        return out
    }

    static func clean(_ groups: [ItemGroup]) -> Int64 {
        var freed: Int64 = 0
        for g in groups {
            let urls = g.items.filter(\.selected).map(\.url)
            freed += FS.remove(urls, permanent: g.permanent).freed
        }
        return freed
    }
}

@MainActor
final class CleanupModel: ObservableObject {
    static let shared = CleanupModel()
    @Published var phase: Phase = .idle
    @Published var groups: [ItemGroup] = []

    func scan() async {
        phase = .scanning("Looking for junk…")
        let g = await Task.detached { Junk.scan { t in Task { @MainActor in CleanupModel.shared.phase = .scanning(t) } } }.value
        groups = g
        phase = .results
    }

    func clean() async {
        let sel = groups
        phase = .working("Cleaning…")
        let freed = await Task.detached { Junk.clean(sel) }.value
        Stats.shared.add(freed: freed)
        phase = .done("\(FS.fmt(freed)) of junk removed. Everything except the Trash went to the Trash, so you can still get it back.")
    }
}

struct CleanupView: View {
    @ObservedObject var m = CleanupModel.shared
    let tint = Module.cleanup.tint
    var body: some View {
        VStack(spacing: 0) {
            switch m.phase {
            case .idle:
                ModuleIntro(symbol: "sparkles", tint: tint, title: "Cleanup", subtitle: "Remove caches, logs, leftovers and other junk your Mac piles up, safely.",
                            bullets: [("internaldrive", "System & app caches"), ("globe", "Browser caches"), ("hammer", "Xcode & developer junk"), ("trash", "Trash bins & Mail attachments")])
                BigButton(title: "Scan", tint: tint) { Task { await m.scan() } }.padding(.bottom, 30)
            case .scanning(let t), .working(let t):
                ScanningView(tint: tint, text: t)
            case .results:
                ResultsHeader(title: "\(FS.fmt(m.groups.selectedTotal)) of junk found", subtitle: "Review the details or clean everything selected.", tint: tint) { m.phase = .idle }
                GroupList(groups: $m.groups, tint: tint).padding(.horizontal, 20)
                BigButton(title: "Clean", tint: tint) { Task { await m.clean() } }.padding(.vertical, 18)
            case .done(let d):
                DoneView(tint: tint, title: "All clean", detail: d) { m.phase = .idle }
            }
        }
    }
}

struct ResultsHeader: View {
    let title: String, subtitle: String, tint: Color
    let back: () -> Void
    var body: some View {
        HStack {
            Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 22, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 10)
    }
}
