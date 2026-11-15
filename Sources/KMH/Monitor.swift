//
//  Monitor.swift — KeepMyMacHealthy
//  Live health: CPU, memory, disk, battery health and network, in the window and the menu bar.
//  Copyright © 2026 Abhiram Upadrashta (Bubbles Aro). MIT License.
//

import SwiftUI
import IOKit
import IOKit.ps
import UserNotifications

@MainActor
final class Health: ObservableObject {
    static let shared = Health()
    @Published var cpu = 0.0           // 0…1
    @Published var memUsed: Int64 = 0
    @Published var memTotal: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    @Published var diskFree: Int64 = FS.diskFree
    @Published var diskTotal: Int64 = FS.diskTotal
    @Published var battery: Int?
    @Published var charging = false
    @Published var cycles: Int?
    @Published var batteryHealth: Int?
    @Published var down = 0.0, up = 0.0  // bytes/s
    @Published var history: [Double] = Array(repeating: 0, count: 40)
    private var lastTicks: (UInt64, UInt64)?
    private var lastNet: (UInt64, UInt64, Date)?
    private var timer: Timer?
    private var warnedDisk = false

    var memFraction: Double { Double(memUsed) / Double(max(memTotal, 1)) }
    var diskFraction: Double { 1 - Double(diskFree) / Double(max(diskTotal, 1)) }
    /// 0…100: a simple overall score shown on Smart Care.
    var score: Int {
        var s = 100.0
        if diskFraction > 0.8 { s -= (diskFraction - 0.8) * 150 }
        if memFraction > 0.85 { s -= (memFraction - 0.85) * 100 }
        if cpu > 0.7 { s -= (cpu - 0.7) * 40 }
        if let h = batteryHealth, h < 80 { s -= Double(80 - h) * 0.6 }
        return max(10, min(100, Int(s)))
    }

    func start() {
        guard timer == nil else { return }
        tick(); readBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in Health.shared.tick() } }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in Health.shared.readBattery() } }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func tick() {
        // CPU
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        if r == KERN_SUCCESS {
            let busy = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
            let total = busy + UInt64(info.cpu_ticks.2)
            if let l = lastTicks, total > l.1 { cpu = Double(busy - l.0) / Double(total - l.1) }
            lastTicks = (busy, total)
        }
        // memory
        var vm = vm_statistics64()
        var c2 = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r2 = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c2)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c2) } }
        if r2 == KERN_SUCCESS {
            let page = Int64(vm_kernel_page_size)
            memUsed = (Int64(vm.active_count) + Int64(vm.wire_count) + Int64(vm.compressor_page_count)) * page
        }
        diskFree = FS.diskFree; diskTotal = FS.diskTotal
        history = Array(history.dropFirst()) + [cpu]
        // network
        var ifs: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifs) == 0, let first = ifs {
            var rx: UInt64 = 0, tx: UInt64 = 0
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let i = p {
                if let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_LINK), let d = i.pointee.ifa_data {
                    let name = String(cString: i.pointee.ifa_name)
                    if !name.hasPrefix("lo") {
                        let n = d.assumingMemoryBound(to: if_data.self).pointee
                        rx += UInt64(n.ifi_ibytes); tx += UInt64(n.ifi_obytes)
                    }
                }
                p = i.pointee.ifa_next
            }
            freeifaddrs(ifs)
            let now = Date()
            if let l = lastNet, rx >= l.0, tx >= l.1 {
                let dt = now.timeIntervalSince(l.2)
                down = Double(rx - l.0) / dt; up = Double(tx - l.1) / dt
            }
            lastNet = (rx, tx, now)
        }
        // alerts
        if UserDefaults.standard.bool(forKey: "alerts"), diskFree < 10 << 30, !warnedDisk {
            warnedDisk = true
            notify("Your startup disk is almost full", "Only \(FS.fmt(diskFree)) left. Open KeepMyMacHealthy to free up space.")
        }
        if diskFree > 15 << 30 { warnedDisk = false }
    }

    private func readBattery() {
        if let i = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let l = IOPSCopyPowerSourcesList(i)?.takeRetainedValue() as? [CFTypeRef],
           let f = l.first, let d = IOPSGetPowerSourceDescription(i, f)?.takeUnretainedValue() as? [String: Any] {
            battery = d[kIOPSCurrentCapacityKey] as? Int
            charging = d[kIOPSIsChargingKey] as? Bool ?? false
        }
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard s != 0 else { return }
        defer { IOObjectRelease(s) }
        func v(_ k: String) -> Int? { (IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue }
        cycles = v("CycleCount")
        if let max = v("AppleRawMaxCapacity") ?? v("NominalChargeCapacity"), let design = v("DesignCapacity"), design > 0 { batteryHealth = min(100, max * 100 / design) }
    }

    func notify(_ t: String, _ b: String) {
        let c = UNMutableNotificationContent(); c.title = t; c.body = b
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    static func rate(_ b: Double) -> String { FS.fmt(Int64(b)) + "/s" }
}

struct Gauge2: View {
    let title: String, value: Double, label: String, tint: Color, icon: String
    var body: some View {
        Card {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(tint.opacity(0.18), lineWidth: 6)
                    Circle().trim(from: 0, to: max(0.01, min(1, value))).stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: value)
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                }.frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(label).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct HealthView: View {
    @ObservedObject var h = Health.shared
    let tint = Module.health.tint
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Health Monitor").font(.system(size: 28, weight: .bold)).padding(.top, 20)
                Text("Live readings, refreshed every two seconds.").foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    Gauge2(title: "CPU", value: h.cpu, label: "\(Int(h.cpu * 100))% busy", tint: KM.blue, icon: "cpu")
                    Gauge2(title: "Memory", value: h.memFraction, label: "\(FS.fmt(h.memUsed)) of \(FS.fmt(h.memTotal))", tint: KM.pink, icon: "memorychip")
                    Gauge2(title: "Storage", value: h.diskFraction, label: "\(FS.fmt(h.diskFree)) free", tint: KM.amber, icon: "internaldrive")
                    Gauge2(title: "Battery", value: Double(h.battery ?? 0) / 100,
                           label: h.battery.map { "\($0)%" + (h.charging ? " · charging" : "") } ?? "No battery", tint: KM.mint, icon: h.charging ? "bolt.fill" : "battery.75")
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CPU history").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Spark(values: h.history, tint: KM.blue).frame(height: 70)
                    }
                }
                HStack(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Network", systemImage: "wifi").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            Text("↓ \(Health.rate(h.down))   ↑ \(Health.rate(h.up))").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Battery health", systemImage: "heart.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            Text(h.batteryHealth.map { "\($0)% of original capacity" } ?? "—").font(.system(size: 15, weight: .semibold))
                            if let c = h.cycles { Text("\(c) charge cycles").font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 26).padding(.bottom, 26)
        }
    }
}

struct Spark: View {
    let values: [Double]; let tint: Color
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            var p = Path()
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1), y: size.height * (1 - CGFloat(min(1, v))))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            var fill = p; fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.35), .clear]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(p, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The menu bar popover.
struct MenuBarView: View {
    @ObservedObject var h = Health.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
                Text("KeepMyMacHealthy").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(h.score)").font(.system(size: 13, weight: .bold)).foregroundStyle(h.score > 75 ? KM.mint : h.score > 50 ? KM.amber : KM.red)
                    .help("Health score")
            }
            row("cpu", "CPU", "\(Int(h.cpu * 100))%", h.cpu, KM.blue)
            row("memorychip", "Memory", FS.fmt(h.memUsed), h.memFraction, KM.pink)
            row("internaldrive", "Storage", "\(FS.fmt(h.diskFree)) free", h.diskFraction, KM.amber)
            if let b = h.battery { row(h.charging ? "bolt.fill" : "battery.75", "Battery", "\(b)%", Double(b) / 100, KM.mint) }
            HStack { Image(systemName: "wifi").frame(width: 18); Text("↓ \(Health.rate(h.down))  ↑ \(Health.rate(h.up))").monospacedDigit(); Spacer() }
                .font(.system(size: 12))
            Divider()
            HStack {
                Button("Free up RAM") { _ = Shell.admin("/usr/sbin/purge", prompt: "KeepMyMacHealthy needs your password to free up memory.") }
                Spacer()
                Button("Open App") { AppDelegate.showMain() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 290)
    }
    private func row(_ icon: String, _ t: String, _ v: String, _ f: Double, _ c: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(c).frame(width: 18)
            Text(t).font(.system(size: 12))
            Spacer()
            Capsule().fill(c.opacity(0.18)).frame(width: 80, height: 5).overlay(alignment: .leading) { Capsule().fill(c).frame(width: 80 * max(0.02, min(1, f)), height: 5) }
            Text(v).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 84, alignment: .trailing)
        }
    }
}
