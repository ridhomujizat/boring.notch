//
//  AgentSneakPeekView.swift
//  boringNotch
//
//  Transient closed-notch peek for coding-agent activity (Claude Code, Codex).
//

import AppKit
import SwiftUI

struct AgentSneakPeekView: View {
    let event: AgentEvent?
    let width: CGFloat

    private let horizontalPadding: CGFloat = 6
    private let providerLogoWidth: CGFloat = 18
    private let actionIconWidth: CGFloat = 18
    private let sessionIconWidth: CGFloat = 18
    private let iconSpacing: CGFloat = 7

    private var marqueeWidth: CGFloat {
        let fixedContentWidth = providerLogoWidth + actionIconWidth + sessionIconWidth + (iconSpacing * 3)
        return max(48, width - (horizontalPadding * 2) - fixedContentWidth)
    }

    private var icon: String {
        // Prefer the activity-type glyph (matches the Sessions list); fall back
        // to a status icon when the tool is unknown.
        if let glyph = event?.activityGlyph { return glyph }
        switch event?.kind {
        case .needsInput: return "pencil"
        case .done: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        default: return "hourglass"
        }
    }

    private var tint: Color {
        switch event?.kind {
        case .needsInput: return .yellow
        case .done: return .green
        case .error: return .red
        default: return .gray
        }
    }

    private var label: String {
        guard let event else { return "" }
        if let project = event.project, !project.isEmpty {
            return project
        }
        return event.title
    }

    private var message: String {
        event?.message ?? ""
    }

    private var text: String {
        [label, message].filter { !$0.isEmpty }.joined(separator: " - ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: iconSpacing) {
            providerLogo
                .frame(width: providerLogoWidth, height: providerLogoWidth)

            Image(systemName: icon)
                .symbolVariant(event?.kind == .needsInput ? .none : .fill)
                .foregroundStyle(tint)
                .frame(width: actionIconWidth, height: 18)

            MarqueeText(
                .constant(text),
                font: .caption,
                nsFont: .caption1,
                textColor: tint,
                minDuration: 1,
                frameWidth: marqueeWidth
            )
            .frame(width: marqueeWidth, alignment: .leading)

            sessionIcon
                .frame(width: sessionIconWidth, height: sessionIconWidth)
        }
        .padding(.horizontal, horizontalPadding)
        .frame(width: width, height: 28, alignment: .center)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var providerLogo: some View {
        switch event?.provider {
        case .codex:
            Image("codexUsageIcon")
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 4))
        case .claudeCode:
            Image("claudeUsageIcon")
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 4))
        default:
            Image(systemName: "cpu")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.gray)
        }
    }

    @ViewBuilder
    private var sessionIcon: some View {
        if let image = AgentHostAppResolver.image(host: event?.host, bundleIdentifier: event?.hostBundleId) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 4))
        } else {
            Image(systemName: "terminal")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.gray)
        }
    }
}
