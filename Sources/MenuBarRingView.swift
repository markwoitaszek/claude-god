// MenuBarRingView.swift
// Apple Watch Activity-style concentric rings for the Icon+ menubar mode.
// Up to 3 quota stats are shown as filled arcs, outer→inner.

import SwiftUI

// MARK: - Single ring arc (track + progress)

private struct RingArc: View {
    let progress: Double   // 0...1
    let color: Color
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            // Dim track
            Circle()
                .stroke(color.opacity(0.18), lineWidth: lineWidth)
            // Filled arc — starts at 12 o'clock, sweeps clockwise
            Circle()
                .trim(from: 0, to: CGFloat(min(max(progress, 0), 1.0)))
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .foregroundColor(color)
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Multi-ring icon

struct MenuBarRingView: View {

    /// Quota objects available for look-up.
    let quotas: [UsageQuota]
    /// Up to 3 quota labels to display. Empty string = unused slot.
    let labels: [String]

    // ── Apple Watch Activity ring palette ──
    // outer = Move (red), mid = Exercise (green), inner = Stand (cyan)
    static let ringColors: [Color] = [
        Color(red: 1.00, green: 0.31, blue: 0.25),
        Color(red: 0.31, green: 0.90, blue: 0.46),
        Color(red: 0.05, green: 0.73, blue: 0.93),
    ]

    // ── Layout constants ──
    private static let outerDiameter: CGFloat = 20
    private static let lineWidth:     CGFloat = 2.0
    private static let step:          CGFloat = 2.5   // lineWidth + 0.5 gap

    // Resolved (utilization, color) pairs — only for non-empty, matched labels
    private var rings: [(utilization: Double, color: Color)] {
        labels.prefix(3).enumerated().compactMap { i, label in
            guard !label.isEmpty,
                  let q = quotas.first(where: { $0.label == label })
            else { return nil }
            return (utilization: q.utilization,
                    color: Self.ringColors[i % Self.ringColors.count])
        }
    }

    var body: some View {
        ZStack {
            if rings.isEmpty {
                // Fallback: plain circled-C icon when no stats are configured
                Image(systemName: "c.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.primary)
            } else {
                ForEach(rings.indices, id: \.self) { i in
                    let diameter = Self.outerDiameter - CGFloat(i) * Self.step * 2
                    RingArc(
                        progress: rings[i].utilization / 100.0,
                        color:    rings[i].color,
                        diameter: diameter,
                        lineWidth: Self.lineWidth
                    )
                }
            }
        }
        .frame(width: Self.outerDiameter, height: Self.outerDiameter)
    }
}

// MARK: - Settings preview (larger, labeled)

struct RingSettingsPreview: View {
    let quotas: [UsageQuota]
    let labels: [String]

    var body: some View {
        HStack(spacing: 12) {
            MenuBarRingView(quotas: quotas, labels: labels)
                .scaleEffect(2.2)
                .frame(width: 48, height: 48)   // enough space for 2.2× scale

            VStack(alignment: .leading, spacing: 3) {
                ForEach(labels.prefix(3).indices, id: \.self) { i in
                    let label = labels[i]
                    let util = quotas.first(where: { $0.label == label })?.utilization
                    HStack(spacing: 5) {
                        Circle()
                            .fill(MenuBarRingView.ringColors[i % MenuBarRingView.ringColors.count])
                            .frame(width: 7, height: 7)
                        if label.isEmpty {
                            Text("—")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } else {
                            Text(label)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            if let u = util {
                                Text("\(Int(u))%")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}
