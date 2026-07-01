//
//  AgentSneakPeekView.swift
//  boringNotch
//
//  Transient closed-notch peek for coding-agent activity (Claude Code, Codex).
//

import SwiftUI

struct AgentSneakPeekView: View {
    let event: AgentEvent?
    let width: CGFloat

    private let horizontalPadding: CGFloat = 14
    private let iconWidth: CGFloat = 18
    private let iconSpacing: CGFloat = 8

    private var marqueeWidth: CGFloat {
        max(48, width - (horizontalPadding * 2) - iconWidth - iconSpacing)
    }

    private var icon: String {
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
        let context = [event.host, event.project].compactMap { $0 }.joined(separator: " · ")
        return context.isEmpty ? event.title : context
    }

    private var message: String {
        event?.message ?? ""
    }

    private var text: String {
        [label, message].filter { !$0.isEmpty }.joined(separator: " - ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: iconSpacing) {
            Image(systemName: icon)
                .symbolVariant(event?.kind == .needsInput ? .none : .fill)
                .foregroundStyle(tint)
                .frame(width: iconWidth, height: 18)

            MarqueeText(
                .constant(text),
                font: .caption,
                nsFont: .caption1,
                textColor: .gray,
                minDuration: 1,
                frameWidth: marqueeWidth
            )
            .frame(width: marqueeWidth, alignment: .leading)
        }
        .padding(.horizontal, horizontalPadding)
        .frame(width: width, height: 28, alignment: .center)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }
}
