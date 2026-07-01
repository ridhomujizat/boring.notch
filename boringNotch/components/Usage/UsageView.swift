//
//  UsageView.swift
//  boringNotch
//
//  Usage tab: live Claude Code and Codex CLI quota meters.
//

import SwiftUI

struct UsageView: View {
    @ObservedObject private var usage = AIUsageManager.shared

    private let claudeColor = Color(red: 0.85, green: 0.45, blue: 0.28)
    private let codexColor = Color(red: 0.40, green: 0.55, blue: 0.95)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button {
                    usage.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(usage.isLoading ? .secondary : .primary)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(usage.isLoading)
                .help("Refresh usage")
            }
            .frame(height: 18)

            ProviderUsageSection(
                name: "Claude",
                imageName: "claudeUsageIcon",
                color: claudeColor,
                snapshot: usage.claude,
                isLoading: usage.isLoading
            )

            ProviderUsageSection(
                name: "Codex",
                imageName: "codexUsageIcon",
                color: codexColor,
                snapshot: usage.codex,
                isLoading: usage.isLoading
            )
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .center)
        .onAppear { usage.start() }
        .onDisappear { usage.stop() }
    }
}

private struct ProviderUsageSection: View {
    let name: String
    let imageName: String
    let color: Color
    let snapshot: UsageSnapshot?
    let isLoading: Bool

    var body: some View {
        Group {
            if let snapshot, snapshot.hasData {
                ProviderRow(
                    name: name,
                    imageName: imageName,
                    color: color,
                    fiveHourUsed: snapshot.fiveHourPercent,
                    sevenDayUsed: snapshot.sevenDayPercent,
                    fiveHourReset: Self.relativeReset(snapshot.fiveHourResetAt),
                    sevenDayReset: Self.relativeReset(snapshot.sevenDayRefillAt),
                    detail: snapshot.detail,
                    warning: snapshot.lastError
                )
            } else if let message = snapshot?.lastError {
                ProviderMessageRow(
                    name: name,
                    imageName: imageName,
                    systemImage: "exclamationmark.triangle.fill",
                    message: message
                )
            } else {
                ProviderMessageRow(
                    name: name,
                    imageName: imageName,
                    systemImage: isLoading ? "hourglass" : "arrow.clockwise",
                    message: isLoading ? "Reading usage..." : "No usage data"
                )
            }
        }
    }

    private static func relativeReset(_ date: Date?) -> String {
        guard let date else { return "--" }
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "resetting" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "resets \(hours)h \(minutes)m" : "resets \(minutes)m"
    }
}

private struct ProviderRow: View {
    let name: String
    let imageName: String
    let color: Color
    let fiveHourUsed: Double
    let sevenDayUsed: Double
    let fiveHourReset: String
    let sevenDayReset: String
    let detail: String?
    let warning: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderBadge(name: name, imageName: imageName)

            VStack(alignment: .leading, spacing: 6) {
                MetricBar(period: "5H", usedValue: fiveHourUsed, reset: fiveHourReset, color: color)
                MetricBar(period: "7D", usedValue: sevenDayUsed, reset: sevenDayReset, color: color)

                if let detail {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

private struct ProviderMessageRow: View {
    let name: String
    let imageName: String
    let systemImage: String
    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderBadge(name: name, imageName: imageName)

            Label(message, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

private struct ProviderBadge: View {
    let name: String
    let imageName: String

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
            .accessibilityLabel(name)
            .frame(width: 58)
    }
}

private struct MetricBar: View {
    let period: String
    let usedValue: Double
    let reset: String
    let color: Color

    private var leftValue: Double {
        1 - min(1, max(0, usedValue))
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(period)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(Int((leftValue * 100).rounded()))% left")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text(reset)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            GeometryReader { geo in
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(color)
                            .frame(width: max(0, geo.size.width * leftValue))
                    }
            }
            .frame(height: 5)
        }
    }
}

#Preview {
    UsageView()
        .frame(width: 420, height: 220)
        .background(.black)
}
