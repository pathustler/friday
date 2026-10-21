import AppKit
import Darwin
import Foundation

struct ProcInfo: Codable, Hashable {
    var name: String
    var path: String?      // .app bundle, for the icon
    var cpu: Double        // % of one core (like Activity Monitor)
    var memMB: Double
}

struct SystemCard: Codable, Hashable {
    var cpu: Double                // 0...1, whole machine
    var cores: [Double]            // 0...1 per core
    var chip: String
    var memUsed: Double            // GB
    var memTotal: Double
    var memWired: Double
    var memCompressed: Double
    var swapUsed: Double
    var pressure: Int              // 0 normal, 1 warning, 2 critical
    var diskUsed: Double
    var diskTotal: Double
    var topCPU: [ProcInfo]
    var topMem: [ProcInfo]
    var uptime: String
    var battery: String?
}

struct DiskItem: Codable, Hashable {
    var name: String
    var path: String
    var bytes: Int64
    var isDir: Bool
}

struct DiskCard: Codable, Hashable {
    var path: String
    var items: [DiskItem]          // largest first; may end with an "Other" bucket
    var skipped: [String]          // folders that took too long to measure
    var volumeTotal: Int64
    var volumeFree: Int64
}

enum SystemInfo {
    // MARK: CPU

    private static func cpuTicks() -> [[UInt32]] {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &count) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(n)).map { i in (0..<stride).map { UInt32(bitPattern: info[i * stride + $0]) } }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    // MARK: processes

    private struct PS { var cpuSeconds: Double; var rssKB: Double; var path: String }

    private static func ps() -> [Int: PS] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pid=,cputime=,rss=,comm="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var r: [Int: PS] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int(f[0]), let rss = Double(f[2]) else { continue }
            let parts = f[1].split(separator: ":").reversed().map { Double($0) ?? 0 }      // [sec, min, hr]
            let secs = zip(parts, [1.0, 60, 3600]).reduce(0) { $0 + $1.0 * $1.1 }
            r[pid] = PS(cpuSeconds: secs, rssKB: rss, path: String(f[3]))
        }
        return r
    }

    private static func group(_ path: String) -> (name: String, app: String?) {
        if let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) {
            let appPath = String(path[..<r.upperBound]).replacingOccurrences(of: ".app/", with: ".app")
            return ((appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""), appPath)
        }
        return ((path as NSString).lastPathComponent, nil)
    }

    // MARK: snapshot

    /// Takes ~1 second: CPU needs two samples to measure load.
    static func snapshot() async -> SystemCard {
        let t1 = cpuTicks()
        let p1 = await Task.detached { ps() }.value
        let start = Date()
        try? await Task.sleep(nanoseconds: 900_000_000)
        let t2 = cpuTicks()
        let p2 = await Task.detached { ps() }.value
        let dt = max(Date().timeIntervalSince(start), 0.1)

        var cores: [Double] = []
        for (a, b) in zip(t1, t2) {
            let d = (0..<4).map { Double(b[$0] &- a[$0]) }
            let total = d.reduce(0, +)
            cores.append(total > 0 ? (d[0] + d[1] + d[3]) / total : 0)       // user + system + nice
        }

        // processes grouped by owning app (Chrome's helpers all count as Chrome)
        var groups: [String: ProcInfo] = [:]
        for (pid, now) in p2 {
            let g = group(now.path)
            var e = groups[g.name] ?? ProcInfo(name: g.name, path: g.app, cpu: 0, memMB: 0)
            if let before = p1[pid] { e.cpu += max(0, (now.cpuSeconds - before.cpuSeconds) / dt * 100) }
            e.memMB += now.rssKB / 1024
            groups[g.name] = e
        }
        let all = Array(groups.values)

        // memory (Activity Monitor's definition: app + wired + compressed)
        var vm = vm_statistics64_data_t()
        var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        _ = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt) }
        }
        let page = Double(vm_kernel_page_size), gb = 1_073_741_824.0
        let used = (Double(vm.internal_page_count) - Double(vm.purgeable_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var level: Int32 = 1
        var lvlSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lvlSize, nil, 0)

        // disk
        let vol = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let dTotal = Double(vol?.volumeTotalCapacity ?? 0), dFree = Double(vol?.volumeAvailableCapacityForImportantUsage ?? 0)

        // uptime, battery
        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0)
        let up = Int(Date().timeIntervalSince1970) - boot.tv_sec
        let uptime = up >= 86400 ? "\(up / 86400)d \(up % 86400 / 3600)h" : "\(up / 3600)h \(up % 3600 / 60)m"

        return SystemCard(
            cpu: cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count), cores: cores,
            chip: sysctlString("machdep.cpu.brand_string") ?? "CPU",
            memUsed: used / gb, memTotal: Double(ProcessInfo.processInfo.physicalMemory) / gb,
            memWired: Double(vm.wire_count) * page / gb, memCompressed: Double(vm.compressor_page_count) * page / gb,
            swapUsed: Double(swap.xsu_used) / gb, pressure: level >= 4 ? 2 : (level == 2 ? 1 : 0),
            diskUsed: (dTotal - dFree) / 1e9, diskTotal: dTotal / 1e9,        // decimal GB, like Finder
            topCPU: all.filter { $0.cpu >= 0.5 }.sorted { $0.cpu > $1.cpu }.prefix(5).map { $0 },
            topMem: all.sorted { $0.memMB > $1.memMB }.prefix(5).map { $0 },
            uptime: uptime, battery: battery())
    }

    private static func battery() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "batt"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let t = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard t.contains("InternalBattery"), let re = try? NSRegularExpression(pattern: #"(\d+)%;\s*([A-Za-z ]+)"#),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let a = Range(m.range(at: 1), in: t), let b = Range(m.range(at: 2), in: t) else { return nil }
        return "\(t[a])% · \(t[b].trimmingCharacters(in: .whitespaces))"
    }

    static func summary(_ s: SystemCard) -> String {
        func g(_ v: Double) -> String { String(format: "%.1f GB", v) }
        var lines = [
            "CPU \(Int(s.cpu * 100))% (\(s.cores.count) cores, \(s.chip)).",
            "Memory \(g(s.memUsed)) of \(g(s.memTotal)) used (wired \(g(s.memWired)), compressed \(g(s.memCompressed))), swap \(g(s.swapUsed)), pressure \(["normal", "warning", "critical"][s.pressure]).",
            "Disk \(Int(s.diskUsed)) of \(Int(s.diskTotal)) GB used (\(Int(s.diskTotal - s.diskUsed)) GB free).",
            "Top CPU: " + s.topCPU.map { "\($0.name) \(Int($0.cpu))%" }.joined(separator: ", "),
            "Top memory: " + s.topMem.map { "\($0.name) \(Int($0.memMB)) MB" }.joined(separator: ", "),
            "Uptime \(s.uptime)." + (s.battery.map { " Battery \($0)." } ?? ""),
        ]
        var hints: [String] = []
        if let t = s.topCPU.first, t.cpu > 80 { hints.append("\(t.name) is using \(Int(t.cpu))% of a core") }
        if s.pressure > 0 { hints.append("memory pressure is \(s.pressure == 2 ? "critical" : "elevated")") }
        if s.swapUsed > 1 { hints.append("\(g(s.swapUsed)) of swap in use (RAM is overcommitted)") }
        if s.diskTotal > 0, (s.diskTotal - s.diskUsed) / s.diskTotal < 0.1 { hints.append("disk is over 90% full") }
        if s.uptime.contains("d"), let d = Int(s.uptime.split(separator: "d").first ?? ""), d >= 14 { hints.append("not restarted for \(d) days") }
        lines.append(hints.isEmpty ? "Nothing looks unhealthy." : "Possible slowdown causes: " + hints.joined(separator: "; ") + ".")
        return lines.joined(separator: "\n")
    }
}

enum DiskUsage {
    /// Size of each item directly inside `path`, measured in parallel with `du`. Anything still running after
    /// `budget` seconds is cut off and reported as skipped, so a huge folder can't hang the answer.
    static func scan(_ rawPath: String, budget: TimeInterval = 40) async -> DiskCard? {
        let expanded = rawPath.hasPrefix("~") ? (rawPath as NSString).expandingTildeInPath
            : (rawPath.hasPrefix("/") ? rawPath : NSHomeDirectory() + "/" + rawPath)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue,
              let names = try? fm.contentsOfDirectory(atPath: expanded) else { return nil }

        let deadline = Date().addingTimeInterval(budget)
        var items: [DiskItem] = []
        var skipped: [String] = []
        var dirs: [String] = []
        for n in names {
            let p = (expanded as NSString).appendingPathComponent(n)
            guard let attrs = try? fm.attributesOfItem(atPath: p) else { continue }
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink { continue }
            if type == .typeDirectory { dirs.append(n) }
            else { items.append(DiskItem(name: n, path: p, bytes: Int64((attrs[.size] as? NSNumber)?.int64Value ?? 0), isDir: false)) }
        }

        func record(_ r: (String, Int64?)) {
            let p = (expanded as NSString).appendingPathComponent(r.0)
            if let b = r.1 { items.append(DiskItem(name: r.0, path: p, bytes: b, isDir: true)) } else { skipped.append(r.0) }
        }

        await withTaskGroup(of: (String, Int64?).self) { group in
            var running = 0
            for n in dirs {
                if running >= 6, let r = await group.next() { running -= 1; record(r) }
                let p = (expanded as NSString).appendingPathComponent(n)
                group.addTask { (n, await Task.detached { du(p, deadline: deadline) }.value) }
                running += 1
            }
            for await r in group { record(r) }
        }

        items = items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        if items.count > 14 {
            let rest = items[14...]
            items = Array(items[..<14]) + [DiskItem(name: "Other (\(rest.count) items)", path: expanded, bytes: rest.reduce(0) { $0 + $1.bytes }, isDir: false)]
        }
        let vol = try? URL(fileURLWithPath: expanded).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return DiskCard(path: expanded, items: items, skipped: skipped.sorted(),
                        volumeTotal: Int64(vol?.volumeTotalCapacity ?? 0), volumeFree: Int64(vol?.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    private static func du(_ path: String, deadline: Date) -> Int64? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-skx", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(deadline.timeIntervalSinceNow, 0)) { if p.isRunning { p.terminate() } }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard Date() < deadline.addingTimeInterval(1), let kb = text.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.flatMap({ Int64($0) }) else { return nil }
        return kb * 1024
    }

    static func summary(_ d: DiskCard) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        let total = d.items.reduce(Int64(0)) { $0 + $1.bytes }
        var lines = ["\((d.path as NSString).abbreviatingWithTildeInPath): \(f.string(fromByteCount: total)) measured. Largest:"]
        lines += d.items.prefix(10).map { "- \($0.name): \(f.string(fromByteCount: $0.bytes))" }
        if !d.skipped.isEmpty { lines.append("Too slow to measure (skipped): \(d.skipped.joined(separator: ", "))") }
        if d.volumeTotal > 0 { lines.append("Disk: \(f.string(fromByteCount: d.volumeFree)) free of \(f.string(fromByteCount: d.volumeTotal)).") }
        return lines.joined(separator: "\n")
    }
}
