//
//  Core.swift — KeepMyMacHealthy
//  File-system helpers, scan result models and the shared look of the app.
//  Copyright © 2026 Abhiram Upadrashta (Bubbles Aro). MIT License.
//

import SwiftUI
import AppKit

// MARK: - Files

/// Folders the user never wants touched (Settings → Ignore list).
enum Ignore {
    static var paths: [String] {
        (UserDefaults.standard.string(forKey: "ignore") ?? "").split(separator: "\n").map { ($0 as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func contains(_ u: URL) -> Bool { let p = u.path; return paths.contains { p == $0 || p.hasPrefix($0 + "/") } }
}

enum FS {
    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser
    static func h(_ p: String) -> URL { home.appendingPathComponent(p) }
    static let lib = h("Library")

    static func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    static func children(_ u: URL, hidden: Bool = true) -> [URL] {
        (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey],
                                     options: hidden ? [] : [.skipsHiddenFiles])) ?? []
    }

    static func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
    static func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }

    /// Allocated size on disk, recursively.
    static func size(_ u: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        if let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true {
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        guard let e = fm.enumerator(at: u, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    static func date(_ u: URL, _ k: URLResourceKey) -> Date? {
        let v = try? u.resourceValues(forKeys: [k])
        switch k {
        case .contentAccessDateKey: return v?.contentAccessDate
        case .contentModificationDateKey: return v?.contentModificationDate
        case .creationDateKey: return v?.creationDate
        default: return nil
        }
    }

    /// Moves to the Trash (recoverable). `permanent` is only used for things already in the Trash.
    @discardableResult
    static func remove(_ urls: [URL], permanent: Bool = false) -> (freed: Int64, failed: [URL]) {
        var freed: Int64 = 0, failed: [URL] = []
        for u in urls where !Ignore.contains(u) {
            let s = size(u)
            do {
                if permanent { try fm.removeItem(at: u) } else { try fm.trashItem(at: u, resultingItemURL: nil) }
                freed += s
            } catch { failed.append(u) }
        }
        return (freed, failed)
    }

    static var diskFree: Int64 {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }
    static var diskTotal: Int64 {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(v?.volumeTotalCapacity ?? 1)
    }

    /// Full Disk Access is needed for Mail, Safari and some app containers.
    static var hasFullDiskAccess: Bool {
        let probe = h("Library/Safari/Bookmarks.plist")
        if !exists(probe) { return (try? fm.contentsOfDirectory(atPath: h("Library/Containers/com.apple.stocks").path)) != nil || !exists(h("Library/Safari")) }
        return fm.isReadableFile(atPath: probe.path) && (try? Data(contentsOf: probe)) != nil
    }
    static func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    static func reveal(_ u: URL) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
}

/// Runs a shell command, optionally with an administrator password prompt (macOS asks, never us).
enum Shell {
    @discardableResult
    static func run(_ cmd: String) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", cmd]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
    /// Returns false if the user cancelled.
    static func admin(_ cmd: String, prompt: String) -> Bool {
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(esc)\" with prompt \"\(prompt)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        return err == nil
    }
}

// MARK: - Scan results

struct Item: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var size: Int64
    var selected: Bool
    var note: String = ""
    var name: String { url.lastPathComponent }
}

struct ItemGroup: Identifiable {
    let id: String
    let name: String
    let icon: String
    let detail: String
    var items: [Item]
    var permanent = false          // Trash contents are removed for good
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedTotal: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }
    var selectedCount: Int { items.filter(\.selected).count }
}

enum Phase: Equatable { case idle, scanning(String), results, working(String), done(String) }

// MARK: - Look

enum KM {
    static let blue = Color(red: 0.49, green: 0.61, blue: 1)
    static let pink = Color(red: 1, green: 0.56, blue: 0.69)
    static let mint = Color(red: 0.49, green: 0.94, blue: 0.78)
    static let amber = Color(red: 1, green: 0.74, blue: 0.36)
    static let red = Color(red: 1, green: 0.42, blue: 0.45)
    static let brand = LinearGradient(colors: [blue, pink, mint], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Each module has its own tint; the window background follows it.
struct ModuleBackground: View {
    var tint: Color
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.09)
            RadialGradient(colors: [tint.opacity(0.35), .clear], center: .topTrailing, startRadius: 10, endRadius: 600)
            RadialGradient(colors: [KM.blue.opacity(0.18), .clear], center: .bottomLeading, startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: tint)
    }
}

struct Card<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        content.padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.09)))
    }
}

/// The big round action button at the bottom of every module.
struct BigButton: View {
    let title: String
    var tint: Color = KM.blue
    var busy = false
    var progress: Double? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: tint.opacity(hover ? 0.8 : 0.5), radius: hover ? 22 : 14)
                Circle().stroke(.white.opacity(0.35), lineWidth: 1).padding(3)
                if busy {
                    Circle().trim(from: 0, to: progress ?? 0.25)
                        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90)).padding(-6)
                        .modifier(Spin(active: progress == nil))
                }
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 92, height: 92)
            .scaleEffect(hover ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.3)) { hover = h } }
        .disabled(busy)
    }
}

struct Spin: ViewModifier {
    var active: Bool
    @State private var a = 0.0
    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(a)).onAppear {
            guard active else { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { a = 360 }
        }
    }
}

/// Glowing module icon used on the intro screens.
struct HeroIcon: View {
    let symbol: String; let tint: Color
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.18)).frame(width: 170, height: 170).scaleEffect(pulse ? 1.08 : 0.95)
            Circle().fill(LinearGradient(colors: [tint, tint.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 124, height: 124).shadow(color: tint.opacity(0.6), radius: 30)
            Image(systemName: symbol).font(.system(size: 52, weight: .semibold)).foregroundStyle(.white)
        }
        .onAppear { withAnimation(.easeInOut(duration: 2).repeatForever()) { pulse = true } }
    }
}

/// Standard intro → scanning → results → done layout every module uses.
struct ModuleIntro: View {
    let symbol: String, tint: Color, title: String, subtitle: String
    var bullets: [(String, String)] = []
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            HeroIcon(symbol: symbol, tint: tint)
            Text(title).font(.system(size: 30, weight: .bold))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center).frame(maxWidth: 480)
            if !bullets.isEmpty {
                HStack(alignment: .top, spacing: 22) {
                    ForEach(bullets, id: \.0) { b in
                        VStack(spacing: 6) {
                            Image(systemName: b.0).font(.system(size: 18)).foregroundStyle(tint)
                            Text(b.1).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                        }.frame(width: 120)
                    }
                }.padding(.top, 6)
            }
            Spacer()
        }
    }
}

struct ScanningView: View {
    let tint: Color; let text: String
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 10).frame(width: 150, height: 150)
                Circle().trim(from: 0, to: 0.3).stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round)).frame(width: 150, height: 150).modifier(Spin(active: true))
                Image(systemName: "magnifyingglass").font(.system(size: 40, weight: .semibold))
            }
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 460)
            Spacer()
        }
    }
}

struct DoneView: View {
    let tint: Color; let title: String; let detail: String; let again: () -> Void
    @State private var show = false
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(tint.opacity(0.2)).frame(width: 150, height: 150).scaleEffect(show ? 1 : 0.4)
                Image(systemName: "checkmark").font(.system(size: 58, weight: .bold)).foregroundStyle(tint).scaleEffect(show ? 1 : 0.2)
            }
            Text(title).font(.system(size: 26, weight: .bold))
            Text(detail).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button("Start Over", action: again).buttonStyle(.bordered).padding(.top, 6)
            Spacer()
        }
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { show = true } }
    }
}

/// Expandable list of groups with per-item checkboxes.
struct GroupList: View {
    @Binding var groups: [ItemGroup]
    var tint: Color
    @State private var open: String?
    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { open }, set: { open = $0 })) {
                ForEach($groups) { $g in
                    HStack {
                        Toggle("", isOn: Binding(get: { g.selectedCount > 0 }, set: { v in for i in g.items.indices { g.items[i].selected = v } }))
                            .toggleStyle(.checkbox).labelsHidden()
                        Image(systemName: g.icon).foregroundStyle(tint).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name).font(.system(size: 13, weight: .semibold))
                            Text(g.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(FS.fmt(g.selectedTotal)).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3).tag(g.id)
                }
            }
            .scrollContentBackground(.hidden)
            .frame(width: 330)
            Divider().opacity(0.3)
            if let id = open, let gi = groups.firstIndex(where: { $0.id == id }) {
                List {
                    ForEach($groups[gi].items) { $it in
                        HStack {
                            Toggle("", isOn: $it.selected).toggleStyle(.checkbox).labelsHidden()
                            Image(nsImage: NSWorkspace.shared.icon(forFile: it.url.path)).resizable().frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(it.name).lineLimit(1).truncationMode(.middle)
                                if !it.note.isEmpty { Text(it.note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                            Text(FS.fmt(it.size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contextMenu { Button("Show in Finder") { FS.reveal(it.url) } }
                    }
                }
                .scrollContentBackground(.hidden)
            } else {
                VStack { Spacer(); Text("Select a category to see its items").foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity)
            }
        }
        .onAppear { open = open ?? groups.first?.id }
    }
}

extension Array where Element == ItemGroup {
    var selectedTotal: Int64 { reduce(0) { $0 + $1.selectedTotal } }
    var selectedURLs: [URL] { flatMap { $0.items.filter(\.selected).map(\.url) } }
}

func confirm(_ title: String, _ text: String, ok: String = "Continue") -> Bool {
    let a = NSAlert(); a.messageText = title; a.informativeText = text
    a.addButton(withTitle: ok); a.addButton(withTitle: "Cancel")
    return a.runModal() == .alertFirstButtonReturn
}
