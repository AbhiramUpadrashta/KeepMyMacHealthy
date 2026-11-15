//
//  App.swift — KeepMyMacHealthy
//  Main window with sidebar, menu bar monitor, settings and about.
//  Copyright © 2026 Abhiram Upadrashta (Bubbles Aro). MIT License.
//

import SwiftUI
import AppKit
import ServiceManagement

enum Module: String, CaseIterable, Identifiable {
    case smartCare = "Smart Care", cleanup = "Cleanup", protection = "Protection", performance = "Performance"
    case applications = "Applications", clutter = "My Clutter", lens = "Space Lens", health = "Health Monitor", shredder = "Shredder", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .smartCare: return "heart.text.square.fill"
        case .cleanup: return "sparkles"
        case .protection: return "hand.raised.fill"
        case .performance: return "bolt.fill"
        case .applications: return "square.grid.2x2.fill"
        case .clutter: return "folder.fill"
        case .lens: return "circle.hexagongrid.fill"
        case .health: return "waveform.path.ecg"
        case .shredder: return "scissors"
        case .settings: return "gearshape.fill"
        }
    }
    var tint: Color {
        switch self {
        case .smartCare: return KM.pink
        case .cleanup: return KM.mint
        case .protection: return Color(red: 1, green: 0.5, blue: 0.55)
        case .performance: return KM.amber
        case .applications: return KM.blue
        case .clutter: return Color(red: 0.4, green: 0.82, blue: 1)
        case .lens: return Color(red: 0.72, green: 0.55, blue: 1)
        case .health: return KM.mint
        case .shredder: return Color(red: 1, green: 0.6, blue: 0.4)
        case .settings: return .gray
        }
    }
    var section: String {
        switch self {
        case .smartCare: return ""
        case .cleanup, .protection, .performance: return "Care"
        case .applications, .clutter, .lens: return "Files & Apps"
        default: return "Tools"
        }
    }
}

struct MainView: View {
    @State private var module: Module = .smartCare
    @ObservedObject var stats = Stats.shared
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ZStack {
                ModuleBackground(tint: module.tint)
                Group {
                    switch module {
                    case .smartCare: SmartCareView(module: $module)
                    case .cleanup: CleanupView()
                    case .protection: ProtectionView()
                    case .performance: PerformanceView()
                    case .applications: ApplicationsView()
                    case .clutter: ClutterView()
                    case .lens: SpaceLensView()
                    case .health: HealthView()
                    case .shredder: ShredderView()
                    case .settings: SettingsView()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .id(module)
            }
            .animation(.easeInOut(duration: 0.3), value: module)
        }
        .frame(minWidth: 960, minHeight: 640)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("KeepMyMacHealthy").font(.system(size: 13, weight: .bold))
                    Text("by Bubbles Aro").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.top, 34).padding(.bottom, 14)
            ForEach(["", "Care", "Files & Apps", "Tools"], id: \.self) { sec in
                if !sec.isEmpty { Text(sec.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 2) }
                ForEach(Module.allCases.filter { $0.section == sec && $0 != .settings }) { m in item(m) }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text("Freed so far").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(FS.fmt(Int64(stats.totalFreed))).font(.system(size: 14, weight: .bold)).foregroundStyle(KM.mint)
            }.padding(.horizontal, 16).padding(.bottom, 6)
            item(.settings).padding(.bottom, 12)
        }
        .frame(width: 210)
        .background(Color(red: 0.07, green: 0.07, blue: 0.12).opacity(0.96))
    }

    private func item(_ m: Module) -> some View {
        Button { module = m } label: {
            HStack(spacing: 10) {
                Image(systemName: m.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 7).fill(m.tint.gradient))
                Text(m.rawValue).font(.system(size: 13, weight: module == m ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9).fill(module == m ? Color.white.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 8)
    }
}

struct SettingsView: View {
    @AppStorage("menuBar") var menuBar = true
    @AppStorage("alerts") var alerts = true
    @AppStorage("autoUpdate") var autoUpdate = true
    @State private var login = LoginItem.enabled
    @AppStorage("ignore") var ignore = ""
    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: $login).onChange(of: login) { _, v in LoginItem.set(v) }
                Toggle("Show the health monitor in the menu bar", isOn: $menuBar).onChange(of: menuBar) { _, v in AppDelegate.shared?.setMenuBar(v) }
                Toggle("Alert me when the disk is almost full", isOn: $alerts)
            }
            Section("Ignore list") {
                TextEditor(text: $ignore).font(.system(size: 12, design: .monospaced)).frame(height: 70)
                HStack {
                    Text("One folder per line. Scans skip these and nothing inside is ever removed.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Folder…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = true
                        if p.runModal() == .OK { ignore += (ignore.isEmpty || ignore.hasSuffix("\n") ? "" : "\n") + p.urls.map(\.path).joined(separator: "\n") }
                    }
                }
            }
            Section("Permissions") {
                HStack {
                    Label(FS.hasFullDiskAccess ? "Full Disk Access is on" : "Full Disk Access is off", systemImage: FS.hasFullDiskAccess ? "checkmark.shield.fill" : "exclamationmark.shield")
                    Spacer()
                    Button("Open Settings") { FS.openFullDiskAccess() }
                }
                Text("Needed to clean Mail, Safari and some app data. Add KeepMyMacHealthy in System Settings → Privacy & Security → Full Disk Access.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                HStack { Text("Version \(Updater.shared.currentVersion)"); Spacer(); Button("Check for Updates") { Updater.shared.check(userInitiated: true) } }
            }
            Section("About") {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text("KeepMyMacHealthy").font(.headline)
                        Text("Free and open source, by Bubbles Aro.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Link("Website", destination: URL(string: "https://bubbles.foo.ng/KeepMyMacHealthy/")!)
                    Link("Support", destination: URL(string: "mailto:abhi@bubbles.foo.ng")!)
                    Spacer()
                    Button("Quit KeepMyMacHealthy") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).padding(20)
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) { try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var window: NSWindow?
    var status: NSStatusItem?
    let popover = NSPopover()

    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate(); shared = d
        app.delegate = d
        app.run()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: ["menuBar": true, "alerts": true, "autoUpdate": true])
        NSApp.setActivationPolicy(.regular)
        Installer.moveToApplicationsIfNeeded()
        Health.shared.start()
        Self.showMain()
        setMenuBar(UserDefaults.standard.bool(forKey: "menuBar"))
        buildMenu()
        Updater.shared.checkInBackgroundIfDue()
    }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { Self.showMain(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { !UserDefaults.standard.bool(forKey: "menuBar") }

    static func showMain() {
        guard let d = shared else { return }
        if d.window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView())
            w.center(); w.setFrameAutosaveName("main")
            d.window = w
        }
        d.popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        d.window?.makeKeyAndOrderFront(nil)
    }

    func setMenuBar(_ on: Bool) {
        if on, status == nil {
            let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            s.button?.image = NSImage(systemSymbolName: "heart.text.square", accessibilityDescription: "KeepMyMacHealthy")
            s.button?.target = self; s.button?.action = #selector(togglePopover)
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: MenuBarView().preferredColorScheme(.dark))
            status = s
        } else if !on, let s = status { NSStatusBar.system.removeStatusItem(s); status = nil }
    }

    @objc func togglePopover() {
        guard let b = status?.button else { return }
        if popover.isShown { popover.performClose(nil) } else { popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let m = NSMenu()
        m.addItem(withTitle: "About KeepMyMacHealthy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Hide KeepMyMacHealthy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        m.addItem(withTitle: "Quit KeepMyMacHealthy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        let editItem = NSMenuItem(); main.addItem(editItem)
        let e = NSMenu(title: "Edit")
        e.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        e.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        e.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = e
        let winItem = NSMenuItem(); main.addItem(winItem)
        let w = NSMenu(title: "Window")
        w.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        w.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = w
        NSApp.mainMenu = main
    }

    @objc func checkUpdates() { Updater.shared.check(userInitiated: true) }
}
