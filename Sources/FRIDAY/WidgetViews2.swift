import AppKit
import SwiftUI

private func usageColor(_ v: Double) -> Color {
    Color(nsColor: v < 0.6 ? .systemGreen : (v < 0.85 ? .systemOrange : .systemRed))
}

struct RingGauge: View {
    let value: Double           // 0...1
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: max(min(value, 1), 0.001))
                    .stroke(usageColor(value), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((value * 100).rounded()))%").font(.system(size: 20, weight: .semibold)).foregroundStyle(.primary)
            }
            .frame(width: 80, height: 80)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.9))
            Text(detail).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.5)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SystemCardView: View {
    let card: SystemCard
    let compact: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                RingGauge(value: card.cpu, title: "CPU", detail: "\(card.cores.count) cores")
                RingGauge(value: card.memTotal > 0 ? card.memUsed / card.memTotal : 0, title: "Memory",
                          detail: String(format: "%.1f of %.0f GB", card.memUsed, card.memTotal))
                RingGauge(value: card.diskTotal > 0 ? card.diskUsed / card.diskTotal : 0, title: "Disk",
                          detail: String(format: "%.0f GB free", card.diskTotal - card.diskUsed))
            }

            if !compact {
                // per-core activity
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(card.cores.enumerated()), id: \.offset) { _, c in
                        ZStack(alignment: .bottom) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(usageColor(c)).frame(height: max(4, 30 * c))
                        }
                        .frame(maxWidth: .infinity).frame(height: 30)
                    }
                }
                .padding(.horizontal, 6)
            }

            HStack(alignment: .top, spacing: 16) {
                procList("Top CPU", card.topCPU.prefix(compact ? 3 : 5).map { $0 }, value: { "\(Int($0.cpu))%" }, fraction: { $0.cpu / 100 / Double(max(card.cores.count, 1)) * 4 })
                procList("Top memory", card.topMem.prefix(compact ? 3 : 5).map { $0 },
                         value: { $0.memMB >= 1024 ? String(format: "%.1f GB", $0.memMB / 1024) : "\(Int($0.memMB)) MB" },
                         fraction: { $0.memMB / 1024 / max(card.memTotal, 1) * 2 })
            }

            if !compact {
                HStack(spacing: 8) {
                    chip("Pressure: " + ["Normal", "Warning", "Critical"][card.pressure],
                         color: [Color.green, .orange, .red][card.pressure])
                    chip(String(format: "Swap %.1f GB", card.swapUsed), color: card.swapUsed > 1 ? .orange : .gray)
                    chip("Up \(card.uptime)", color: .gray)
                    if let b = card.battery { chip("🔋 \(b)", color: .gray) }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(height: compact ? WidgetView.compactHeight(.system(card)) : nil, alignment: .top)
        .background(cardBackground(Color(red: 0.3, green: 0.7, blue: 0.6)))
    }

    private func chip(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color.opacity(0.9)).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.8))
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func procList(_ title: String, _ procs: [ProcInfo], value: @escaping (ProcInfo) -> String,
                          fraction: @escaping (ProcInfo) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Color.primary.opacity(0.4))
            ForEach(Array(procs.enumerated()), id: \.offset) { _, p in
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        if let path = p.path {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "gearshape.fill").font(.system(size: 12)).frame(width: 18, height: 18).foregroundStyle(Color.primary.opacity(0.4))
                        }
                        Text(p.name).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.9)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(value(p)).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Color.primary.opacity(0.7))
                    }
                    GeometryReader { g in
                        Capsule().fill(Color.primary.opacity(0.08))
                            .overlay(alignment: .leading) {
                                Capsule().fill(usageColor(min(fraction(p), 1))).frame(width: max(3, g.size.width * min(fraction(p), 1)))
                            }
                    }
                    .frame(height: 3)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Disk usage treemap

enum Treemap {
    /// Squarified treemap layout: tiles sized by value, as close to square as possible.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let areas = values.map { $0 / total * Double(rect.width * rect.height) }
        var rects: [CGRect] = []
        var r = rect
        var i = 0
        func worst(_ row: [Double], _ w: Double) -> Double {
            let s = row.reduce(0, +)
            return max(w * w * (row.max() ?? 0) / (s * s), s * s / (w * w * max(row.min() ?? 1, 0.0001)))
        }
        while i < areas.count {
            let side = Double(min(r.width, r.height))
            var row = [areas[i]]
            var j = i + 1
            while j < areas.count, worst(row + [areas[j]], side) <= worst(row, side) { row.append(areas[j]); j += 1 }
            let s = row.reduce(0, +)
            if r.width >= r.height {
                let w = CGFloat(s) / r.height
                var y = r.minY
                for a in row { let h = CGFloat(a) / w; rects.append(CGRect(x: r.minX, y: y, width: w, height: h)); y += h }
                r = CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height)
            } else {
                let h = CGFloat(s) / r.width
                var x = r.minX
                for a in row { let w = CGFloat(a) / h; rects.append(CGRect(x: x, y: r.minY, width: w, height: h)); x += w }
                r = CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h)
            }
            i = j
        }
        return rects
    }
}

struct DiskCardView: View {
    let card: DiskCard
    let compact: Bool

    /// One hue (the user's accent colour) in graded shades: calm and native instead of a rainbow.
    private func color(_ i: Int, _ item: DiskItem) -> Color {
        item.name.hasPrefix("Other (") ? Color.secondary.opacity(0.45) : Color.accentColor.opacity(max(0.9 - Double(i) * 0.07, 0.3))
    }
    private static let fmt: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()

    var body: some View {
        let total = card.items.reduce(Int64(0)) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "internaldrive.fill").foregroundStyle(Color.primary.opacity(0.5))
                Text((card.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.95)).lineLimit(1)
                Spacer()
                Text(Self.fmt.string(fromByteCount: total)).font(.system(size: 16, weight: .light)).foregroundStyle(Color.primary.opacity(0.9))
            }

            if card.volumeTotal > 0 {
                let used = Double(card.volumeTotal - card.volumeFree) / Double(card.volumeTotal)
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { g in
                        Capsule().fill(Color.primary.opacity(0.1))
                            .overlay(alignment: .leading) { Capsule().fill(usageColor(used)).frame(width: g.size.width * used) }
                    }
                    .frame(height: 6)
                    Text("\(Self.fmt.string(fromByteCount: card.volumeFree)) free of \(Self.fmt.string(fromByteCount: card.volumeTotal))")
                        .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.5))
                }
            }

            GeometryReader { g in
                let rects = Treemap.layout(card.items.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: g.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(card.items.indices, rects)), id: \.0) { i, r in
                        let item = card.items[i]
                        Button { reveal(item) } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(color(i, item).opacity(0.85))
                                .overlay(alignment: .topLeading) {
                                    if r.width > 70 && r.height > 36 {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                            Text(Self.fmt.string(fromByteCount: item.bytes)).font(.system(size: 11)).opacity(0.85)
                                        }
                                        .foregroundStyle(.white).padding(6)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .frame(width: max(r.width - 2, 1), height: max(r.height - 2, 1))
                        .offset(x: r.minX + 1, y: r.minY + 1)
                        .help("\(item.name) — \(Self.fmt.string(fromByteCount: item.bytes))")
                    }
                }
            }
            .frame(height: compact ? 130 : 190)

            if !compact {
                VStack(spacing: 0) {
                    ForEach(Array(card.items.prefix(8).enumerated()), id: \.offset) { i, item in
                        Button { reveal(item) } label: {
                            HStack(spacing: 10) {
                                Circle().fill(color(i, item)).frame(width: 9, height: 9)
                                Text(item.name).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.9)).lineLimit(1)
                                Spacer()
                                Text(String(format: "%.0f%%", total > 0 ? Double(item.bytes) / Double(total) * 100 : 0))
                                    .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.4))
                                Text(Self.fmt.string(fromByteCount: item.bytes)).font(.system(size: 13, weight: .medium).monospacedDigit())
                                    .foregroundStyle(Color.primary.opacity(0.85)).frame(width: 78, alignment: .trailing)
                            }
                            .frame(height: 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !card.skipped.isEmpty {
                    Text("Too slow to measure: \(card.skipped.joined(separator: ", "))")
                        .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.4))
                }
            }
        }
        .padding(14)
        .background(cardBackground(Color(red: 0.55, green: 0.4, blue: 0.9)))
    }

    private func reveal(_ item: DiskItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }
}
