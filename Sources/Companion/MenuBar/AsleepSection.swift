import SwiftUI
import CompanionCore

struct AsleepSection: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var coordinator: Coordinator { model.coordinator }

    var body: some View {
        VStack(spacing: 10) {
            // its own glass element (not inside a card): glass on glass turns muddy.
            Button {
                model.launchLeague()
            } label: {
                Label(model.launchState == .starting ? "Starting League…" : "Launch League",
                      systemImage: "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .foregroundStyle(.primary)
            .disabled(model.launchState == .starting)

            if let message = launchMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }

            GlassSection {
                GoalPicker(model: model)
            }

            if model.reviewHint != nil {
                GlassSection { ReviewLastGameRow(model: model) }
            }

            GlassSection {
                VStack(spacing: 0) {
                    if let s = coordinator.lastSession {
                        StatRow(title: "Last session", value: Format.record(wins: s.wins, losses: s.losses))
                    }
                    StatRow(title: "Goal streak", value: streakText)
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.launchState)
    }

    private var streakText: String {
        switch coordinator.goalStreak {
        case 0: "None yet"
        case 1: "1 game"
        case let n: "\(n) games"
        }
    }

    private var launchMessage: String? {
        switch model.launchState {
        case .notInstalled: "League of Legends isn't installed in Applications."
        case .failed: "League didn't start. Try opening it from the Riot Client."
        case .idle, .starting: nil
        }
    }
}
