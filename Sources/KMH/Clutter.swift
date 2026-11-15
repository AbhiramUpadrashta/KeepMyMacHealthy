//
//  Clutter.swift — KeepMyMacHealthy
//  Large & old files, duplicates, similar images and an old Downloads sweep. Plus the Shredder.
//  Copyright © 2026 Abhiram Upadrashta (Bubbles Aro). MIT License.
//

import SwiftUI
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum Clutter {
    static let skip: Set<String> = ["Library", ".Trash", "Applications", ".git", "node_modules", "Pictures/Photos Library.photoslibrary"]

    static func walk(_ root: URL, minSize: Int64, _ visit: (URL, Int64, Date?) -> Void) {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentAccessDateKey, .isPackageKey]
        guard let e = FS.fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { return }
        for case let u as URL in e {
            if skip.contains(u.lastPathComponent) || u.pathExtension == "photoslibrary" || Ignore.contains(u) { e.skipDescendants(); continue }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let s = Int64(v.fileSize ?? 0)
            if s >= minSize { visit(u, s, v.contentAccessDate) }
        }
    }

    static func large(progress: (String) -> Void) -> [ItemGroup] {
        progress("Finding large and old files…")
        var huge: [Item] = [], big: [Item] = [], old: [Item] = []
        let year = Date().addingTimeInterval(-365 * 86400)
        walk(FS.home, minSize: 50 << 20) { u, s, used in
            let note = used.map { "Last opened " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
            let it = Item(url: u, size: s, selected: false, note: note)
            if let used, used < year { old.append(it) } else if s >= 1 << 30 { huge.append(it) } else { big.append(it) }
        }
        var g: [ItemGroup] = []
        if !huge.isEmpty { g.append(ItemGroup(id: "huge", name: "Over 1 GB", icon: "externaldrive.fill", detail: "Your biggest files", items: huge.sorted { $0.size > $1.size })) }
        if !big.isEmpty { g.append(ItemGroup(id: "big", name: "50 MB – 1 GB", icon: "doc.fill", detail: "Large files", items: big.sorted { $0.size > $1.size })) }
        if !old.isEmpty { g.append(ItemGroup(id: "old", name: "Not opened in a year", icon: "clock", detail: "Large files you haven't touched", items: old.sorted { $0.size > $1.size })) }
        progress("Checking Downloads…")
        let month = Date().addingTimeInterval(-30 * 86400)
        let dl = FS.children(FS.h("Downloads"), hidden: false).filter { (FS.date($0, .contentModificationDateKey) ?? .now) < month }
            .map { Item(url: $0, size: FS.size($0), selected: false, note: "Added " + (FS.date($0, .contentModificationDateKey)?.formatted(date: .abbreviated, time: .omitted) ?? "")) }
        if !dl.isEmpty { g.append(ItemGroup(id: "downloads", name: "Old downloads", icon: "arrow.down.circle", detail: "In Downloads for more than 30 days", items: dl.sorted { $0.size > $1.size })) }
        return g
    }

    /// Rebuildable project folders (node_modules, build output, virtualenvs…) in projects untouched for a month.
    static func artifacts(progress: (String) -> Void) -> [ItemGroup] {
        progress("Looking for old project build files…")
        let rules: [String: [String]] = [
            "node_modules": ["package.json"], "target": ["Cargo.toml", "pom.xml"], ".build": ["Package.swift"], "build": ["build.gradle", "build.gradle.kts", "package.json", "CMakeLists.txt"],
            "dist": ["package.json", "setup.py", "pyproject.toml"], ".venv": [], "venv": [], "Pods": ["Podfile"], "DerivedData": [], ".gradle": ["settings.gradle", "build.gradle"],
            ".next": ["package.json"], ".nuxt": ["package.json"], "__pycache__": [], ".dart_tool": ["pubspec.yaml"], ".turbo": [], ".parcel-cache": [],
        ]
        let month = Date().addingTimeInterval(-30 * 86400)
        var items: [Item] = []
        guard let e = FS.fm.enumerator(at: FS.home, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return [] }
        for case let u as URL in e {
            let n = u.lastPathComponent
            if ["Library", ".Trash", "Applications", ".git", ".npm", ".cache", ".cargo", ".rustup", ".m2"].contains(n) || Ignore.contains(u) || e.level > 7 { e.skipDescendants(); continue }
            guard let need = rules[n], FS.isDir(u) else { continue }
            e.skipDescendants()
            let parent = u.deletingLastPathComponent()
            if n.contains("venv") && !FS.exists(u.appendingPathComponent("pyvenv.cfg")) { continue }
            if !need.isEmpty && !need.contains(where: { FS.exists(parent.appendingPathComponent($0)) }) { continue }
            let touched = FS.date(parent, .contentModificationDateKey) ?? .now
            let s = FS.size(u)
            guard s > 1 << 20 else { continue }
            items.append(Item(url: u, size: s, selected: touched < month, note: "\(parent.lastPathComponent) · project changed \(touched.formatted(.relative(presentation: .named)))"))
        }
        return items.isEmpty ? [] : [ItemGroup(id: "artifacts", name: "Project build files", icon: "hammer.circle",
                                               detail: "node_modules, build output, virtualenvs… they rebuild on the next install or build", items: items.sorted { $0.size > $1.size })]
    }

    static func hash(_ u: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while let d = try? h.read(upToCount: 1 << 20), !d.isEmpty { sha.update(data: d) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func duplicates(progress: (String) -> Void) -> [ItemGroup] {
        progress("Comparing files for duplicates…")
        var bySize: [Int64: [URL]] = [:]
        walk(FS.home, minSize: 512 << 10) { u, s, _ in bySize[s, default: []].append(u) }
        var groups: [Item] = []
        var sets = 0
        for (s, urls) in bySize where urls.count > 1 {
            var byHash: [String: [URL]] = [:]
            for u in urls { if let h = hash(u) { byHash[h, default: []].append(u) } }
            for (_, same) in byHash where same.count > 1 {
                sets += 1
                // keep the oldest copy, select the rest
                let sorted = same.sorted { (FS.date($0, .creationDateKey) ?? .now) < (FS.date($1, .creationDateKey) ?? .now) }
                for (i, u) in sorted.enumerated() {
                    groups.append(Item(url: u, size: s, selected: i > 0, note: i == 0 ? "Original — kept" : "Copy of \(sorted[0].deletingLastPathComponent().lastPathComponent)/\(sorted[0].lastPathComponent)"))
                }
            }
        }
        return groups.isEmpty ? [] : [ItemGroup(id: "dupes", name: "Duplicates", icon: "doc.on.doc", detail: "\(sets) sets of identical files — the oldest copy is kept", items: groups)]
    }

    /// 64-bit difference hash of a small grayscale thumbnail.
    static func dhash(_ u: URL) -> UInt64? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary)
        else { return nil }
        var px = [UInt8](repeating: 0, count: 9 * 8)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard ok else { return nil }
        var h: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 { h = (h << 1) | (px[y * 9 + x] > px[y * 9 + x + 1] ? 1 : 0) } }
        return h
    }

    static func similarImages(progress: (String) -> Void) -> [ItemGroup] {
        progress("Looking for similar photos…")
        var imgs: [(URL, UInt64, Int64)] = []
        for r in ["Pictures", "Desktop", "Downloads", "Documents"].map(FS.h) {
            walk(r, minSize: 50 << 10) { u, s, _ in
                guard let t = UTType(filenameExtension: u.pathExtension), t.conforms(to: .image), let h = dhash(u) else { return }
                imgs.append((u, h, s))
            }
        }
        var used = Set<Int>(), items: [Item] = [], sets = 0
        for i in imgs.indices where !used.contains(i) {
            var set = [i]
            for j in (i + 1)..<imgs.count where !used.contains(j) && (imgs[i].1 ^ imgs[j].1).nonzeroBitCount <= 4 { set.append(j) }
            guard set.count > 1 else { continue }
            sets += 1
            set.forEach { used.insert($0) }
            let best = set.max { imgs[$0].2 < imgs[$1].2 }!
            for k in set { items.append(Item(url: imgs[k].0, size: imgs[k].2, selected: k != best, note: k == best ? "Best (largest) — kept" : "Similar to \(imgs[best].0.lastPathComponent)")) }
        }
        return items.isEmpty ? [] : [ItemGroup(id: "similar", name: "Similar images", icon: "photo.on.rectangle", detail: "\(sets) sets of near-identical photos and screenshots", items: items)]
    }
}

@MainActor
final class ClutterModel: ObservableObject {
    static let shared = ClutterModel()
    @Published var phase: Phase = .idle
    @Published var groups: [ItemGroup] = []

    func scan() async {
        phase = .scanning("Finding clutter…")
        let report: (String) -> Void = { t in Task { @MainActor in ClutterModel.shared.phase = .scanning(t) } }
        let g = await Task.detached { Clutter.large(progress: report) + Clutter.artifacts(progress: report) + Clutter.duplicates(progress: report) + Clutter.similarImages(progress: report) }.value
        groups = g
        phase = .results
    }

    func remove() async {
        let sel = groups
        guard confirm("Move \(sel.selectedURLs.count) files to the Trash?", "\(FS.fmt(sel.selectedTotal)) will be freed when you empty the Trash.", ok: "Move to Trash") else { return }
        phase = .working("Removing…")
        let r = await Task.detached { FS.remove(sel.selectedURLs) }.value
        Stats.shared.add(freed: r.freed)
        phase = .done("\(FS.fmt(r.freed)) moved to the Trash.")
    }
}

struct ClutterView: View {
    @ObservedObject var m = ClutterModel.shared
    let tint = Module.clutter.tint
    var body: some View {
        VStack(spacing: 0) {
            switch m.phase {
            case .idle:
                ModuleIntro(symbol: "folder.fill", tint: tint, title: "My Clutter", subtitle: "Find big forgotten files, exact duplicates and near-identical photos in your folders.",
                            bullets: [("externaldrive", "Large & old files"), ("hammer.circle", "Old project build files"), ("doc.on.doc", "Duplicates"), ("photo.on.rectangle", "Similar images")])
                BigButton(title: "Scan", tint: tint) { Task { await m.scan() } }.padding(.bottom, 30)
            case .scanning(let t), .working(let t):
                ScanningView(tint: tint, text: t)
            case .results:
                ResultsHeader(title: m.groups.isEmpty ? "No clutter found" : "\(FS.fmt(m.groups.reduce(0) { $0 + $1.total })) of clutter found",
                              subtitle: "Nothing is selected unless it's a copy. Pick what you don't need.", tint: tint) { m.phase = .idle }
                if !m.groups.isEmpty { GroupList(groups: $m.groups, tint: tint).padding(.horizontal, 20) } else { Spacer() }
                BigButton(title: "Remove", tint: tint) { Task { await m.remove() } }.padding(.vertical, 18).disabled(m.groups.selectedURLs.isEmpty)
            case .done(let d):
                DoneView(tint: tint, title: "Tidied up", detail: d) { m.phase = .idle }
            }
        }
    }
}

// MARK: - Shredder

struct ShredderView: View {
    @State private var files: [URL] = []
    @State private var target = false
    @State private var status = ""
    let tint = Module.shredder.tint
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            HeroIcon(symbol: "scissors", tint: tint)
            Text("Shredder").font(.system(size: 30, weight: .bold))
            Text("Erase sensitive files for good. They're overwritten with random data before deletion and can't be recovered.")
                .foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center).frame(maxWidth: 460)
            RoundedRectangle(cornerRadius: 18).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                .foregroundStyle(target ? tint : .white.opacity(0.25))
                .frame(width: 440, height: 130)
                .overlay {
                    if files.isEmpty { Text("Drop files or folders here").foregroundStyle(.secondary) }
                    else {
                        ScrollView { VStack(alignment: .leading) { ForEach(files, id: \.self) { f in Label(f.lastPathComponent, systemImage: FS.isDir(f) ? "folder" : "doc") } }.frame(maxWidth: .infinity, alignment: .leading).padding() }
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $target) { ps in
                    for p in ps { _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { if !files.contains(u) { files.append(u) } } } } }
                    return true
                }
            HStack {
                Button("Choose…") {
                    let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = true
                    if p.runModal() == .OK { files += p.urls }
                }
                if !files.isEmpty { Button("Clear") { files.removeAll() } }
            }
            if !status.isEmpty { Text(status).foregroundStyle(tint) }
            Spacer()
            BigButton(title: "Shred", tint: tint) { shred() }.padding(.bottom, 30).disabled(files.isEmpty)
        }
    }
    private func shred() {
        guard confirm("Shred \(files.count) item\(files.count == 1 ? "" : "s") permanently?", "This can't be undone. The files won't go to the Trash.", ok: "Shred") else { return }
        let list = files
        Task.detached {
            var n = 0
            for u in list {
                let all: [URL] = FS.isDir(u) ? ((FS.fm.enumerator(at: u, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []) : [u]
                for f in all where !FS.isDir(f) {
                    if let h = try? FileHandle(forWritingTo: f), let size = try? FS.fm.attributesOfItem(atPath: f.path)[.size] as? Int {
                        var left = size
                        while left > 0 { let c = min(left, 1 << 20); try? h.write(contentsOf: Data((0..<c).map { _ in UInt8.random(in: 0...255) })); left -= c }
                        try? h.synchronize(); try? h.close()
                    }
                }
                if (try? FS.fm.removeItem(at: u)) != nil { n += 1 }
            }
            let done = n
            await MainActor.run { files.removeAll(); status = "\(done) item\(done == 1 ? "" : "s") shredded." }
        }
    }
}
