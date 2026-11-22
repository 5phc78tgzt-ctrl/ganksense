import SwiftUI
import AppKit
import CompanionCore

struct PopoverView: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    private var coordinator: Coordinator { model.coordinator }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                header
                section
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                footer
            }
        }
        .padding(12)
        .frame(width: 300)
        // menu bar windows never become key; without this every control draws in the dimmed inactive style.
        .environment(\.controlActiveState, .key)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.22, dampingFraction: 1.0),
                   value: coordinator.phase)
    }

    private var header: some View {
        HStack(alignment: .capCenter, spacing: 8) {
            Text(AppInfo.name)
                .font(.headline)
                .capCentered(style: .headline)
            Spacer(minLength: 8)
            StatusPill(text: Self.statusText(coordinator.phase, demo: model.isDemo),
                       live: coordinator.phase == .inGame)
        }
        .popoverRow()
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var section: some View {
        switch coordinator.phase {
        case .asleep:
            AsleepSection(model: model).id("asleep")
        case .client, .postGame:
            ClientSection(model: model).id("client")
        case .inGame:
            InGameSection(model: model).id("inGame")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            footerButton("Settings", action: showSettings).keyboardShortcut(",", modifiers: .command)
            footerButton("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
    }

    private func showSettings() {
        if let open = model.openSettings {
            open()
        } else {
            NSApp.activate()
            openSettings()
        }
    }

    static func statusText(_ phase: AppPhase, demo: Bool) -> String {
        let base: String = switch phase {
        case .asleep: "League closed"
        case .inGame: "In game"
        case .postGame: "Game finished"
        case .client(let p):
            switch p {
            case .lobby, .none, .unknown: "In client"
            case .matchmaking: "In queue"
            case .readyCheck: "Match found"
            case .champSelect: "Champ select"
            case .gameStart, .inProgress: "Loading game"
            case .reconnect: "Reconnecting"
            case .waitingForStats, .preEndOfGame, .endOfGame: "Game finished"
            }
        }
        return demo ? "Demo · \(base)" : base
    }
}
