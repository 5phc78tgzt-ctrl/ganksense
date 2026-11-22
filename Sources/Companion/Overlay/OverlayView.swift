import SwiftUI
import Observation
import CompanionCore

/// what the overlay draws, as plain values: built from the live `coordinator` or from `overlaypreview`.
struct OverlayContent: Equatable {
    var goal: GoalProgress?
    var suggestion: BuildSuggestion?
    var nextIconURL: URL?
    var thenIconURL: URL?
    /// enemy physical share 0…1; nil hides the damage module.
    var adShare: Double?
    var spike: SpikeAlert?
    /// quiet enemy-jungler line; coarse by construction (age buckets, 5 s steps) so it rarely changes.
    var jungler: JunglerStatus?

    var isEmpty: Bool { goal == nil && suggestion == nil && adShare == nil && spike == nil && jungler == nil }
}

/// mutable overlay state the controller drives; the view only reads it.
@MainActor @Observable
final class OverlayState {
    var content = OverlayContent()
    /// visible (smart fade); the panel sits at alpha 0 otherwise.
    var active = false
    var scale: CGFloat = 1
    var alignment: Alignment = .topTrailing
}

/// the league-style hud stack: goal badge · next buy · enemy damage · spike row.
struct OverlayView: View {
    let state: OverlayState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1) }

    var body: some View {
        let k = state.scale
        let content = state.content
        VStack(alignment: horizontal, spacing: 6 * k) {
            if let goal = content.goal {
                GoalBadge(progress: goal)
            }
            if let s = content.suggestion {
                NextBuyCard(suggestion: s, iconURL: content.nextIconURL, thenIconURL: content.thenIconURL)
            }
            if let ad = content.adShare {
                DamageMix(adShare: ad)
            }
            if let spike = content.spike {
                SpikeRow(alert: spike)
                    .id(spike.id)
                    .transition(reduceMotion
                                ? .opacity
                                : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                              removal: .opacity.combined(with: .offset(x: 24 * k))))
            }
            if let jungler = content.jungler {
                JunglerRow(status: jungler)
            }
        }
        .frame(width: LeagueTheme.moduleWidth * k)
        .environment(\.hudScale, k)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 1), value: content.spike?.id)
        .animation(spring, value: content.suggestion?.next.id)
        .animation(spring, value: content.goal == nil)
        .animation(spring, value: content.adShare == nil)
        .animation(spring, value: content.jungler == nil)
        .padding(OverlayLayout.shadowPadding * k)
        // flatten to one metal-rendered layer (including the shadow margin, so shadows and the spike slide are
        // not clipped): otherwise every change, and every frame of a transition, re-rasterizes each text run
        // and gradient with coregraphics on the cpu.
        .drawingGroup()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: state.alignment)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }

    private var horizontal: HorizontalAlignment {
        switch state.alignment.horizontal {
        case .leading: .leading
        case .center: .center
        default: .trailing
        }
    }
}

/// panel geometry shared by the view and the controller.
enum OverlayLayout {
    /// transparent margin around the modules so shadows and the spike slide are not clipped.
    static let shadowPadding: CGFloat = 14
    /// tallest stack (all five modules, two rows of chips) at scale 1, plus slack.
    static let maxContentHeight: CGFloat = 392
    /// distance from the screen edges.
    static let margin: CGFloat = 16
}
