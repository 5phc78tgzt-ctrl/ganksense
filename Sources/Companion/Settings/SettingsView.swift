import SwiftUI
import CompanionCore

enum SettingsTab: String, CaseIterable, Hashable {
    case general, overlay, goals, tilt

    var title: String {
        switch self {
        case .general: "General"
        case .overlay: "Overlay"
        case .goals: "Goals"
        case .tilt: "Tilt guard"
        }
    }

    /// debug: `--settings-preview <tab>` picks the tab the window opens on.
    static var fromArguments: SettingsTab {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--settings-preview"), args.indices.contains(i + 1),
              let tab = SettingsTab(rawValue: args[i + 1].lowercased()) else { return .general }
        return tab
    }
}

/// settings window: general, overlay, goals, tilt guard. every edit goes through `coordinator.updatesettings`.
/// a plain, opaque, native macos settings look: a centred segmented control (16 pt above and below), a hairline,
/// then the page in grouped sections with system fills and standard controls. one rhythm everywhere (see
/// `settingsmetrics`); no liquid glass here (the popover keeps it). one window height for every tab (the tallest
/// page), so the tab control never moves.
struct SettingsView: View {
    let model: AppModel
    @State private var tab = SettingsTab.fromArguments
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: tabBinding) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: SettingsMetrics.tabPickerWidth)
            .padding(.vertical, SettingsMetrics.tabPickerGap)
            .frame(maxWidth: .infinity)

            Divider()

            // every page is laid out at once, stacked and top-aligned, so the window is always as tall as the
            // tallest page: switching tabs never resizes the window and the tab control never moves. only the
            // selected page is visible and reachable.
            ZStack(alignment: .top) {
                ForEach(SettingsTab.allCases, id: \.self) { page in
                    let selected = page == tab
                    VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) { content(page) }
                        .padding(SettingsMetrics.pagePadding)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                        .accessibilityHidden(!selected)
                }
            }
        }
        .frame(width: SettingsMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .containerBackground(Color(nsColor: .windowBackgroundColor), for: .window)
    }

    @ViewBuilder private func content(_ page: SettingsTab) -> some View {
        switch page {
        case .general: GeneralSettings(model: model)
        case .overlay: OverlaySettings(model: model)
        case .goals: GoalSettings(model: model)
        case .tilt: TiltSettingsView(model: model)
        }
    }

    /// cross-fades the pages with a short, critically damped spring; switches instantly with reduce motion.
    private var tabBinding: Binding<SettingsTab> {
        Binding(
            get: { tab },
            set: { new in
                if reduceMotion { tab = new } else { withAnimation(.snappy(duration: 0.18)) { tab = new } }
            }
        )
    }
}

extension AppModel {
    func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { self.coordinator.settings[keyPath: keyPath] },
            set: { value in
                var s = self.coordinator.settings
                s[keyPath: keyPath] = value
                self.coordinator.updateSettings(s)
            }
        )
    }
}


/// the one set of numbers every settings page is built from.
enum SettingsMetrics {
    static let width: CGFloat = 480
    /// around every page, equal on all four sides.
    static let pagePadding: CGFloat = 20
    /// between sections (and between a section and a button below it).
    static let sectionSpacing: CGFloat = 14
    /// between a section's header or footer and its box.
    static let labelGap: CGFloat = 6
    /// inset of row content inside a box; headers and footers use it too, so all text lines up.
    static let rowInset: CGFloat = 12
    /// height of every single-line row; text and controls are centred in it.
    static let row: CGFloat = 40
    /// fixed trailing column every control sits in.
    static let controlColumn: CGFloat = 210
    static let sliderWidth: CGFloat = 150
    static let valueWidth: CGFloat = 48
    static let corner: CGFloat = 10
    /// the segmented tab control: its width and the gap above and below it.
    static let tabPickerWidth: CGFloat = 340
    static let tabPickerGap: CGFloat = 16
}

/// a grouped section (settings and the death review): optional header above, rows in a rounded system-fill box, optional footnote below.
struct SettingsSection<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.labelGap) {
            if let header {
                Text(header)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, SettingsMetrics.rowInset)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, SettingsMetrics.rowInset)
                .background(.quinary, in: RoundedRectangle(cornerRadius: SettingsMetrics.corner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsMetrics.corner, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.rowInset)
            }
        }
    }
}

struct RowDivider: View {
    var body: some View { Divider() }
}

/// one setting: title (and an optional caption hint directly under it) on the left, its control right-aligned in
/// the fixed trailing column, both vertically centred in the row.
private struct SettingRow<Control: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .frame(width: SettingsMetrics.controlColumn, alignment: .trailing)
        }
        .font(.body)
        .padding(.vertical, hint == nil ? 0 : 8)
        .frame(minHeight: SettingsMetrics.row)
    }
}

private struct SettingSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

/// a numeric value with its stepper, right-aligned: "2 deaths ▲▼".
private struct ValueStepper: View {
    let text: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText(value: value))
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: value)
            Stepper("", value: $value, in: range, step: step).labelsHidden()
        }
    }
}

/// slider with its value, same widths on every page.
private struct SliderControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .frame(width: SettingsMetrics.sliderWidth)
            Text("\(Int((value * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: SettingsMetrics.valueWidth, alignment: .trailing)
        }
    }
}


private struct GeneralSettings: View {
    let model: AppModel
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginFailed = false
    @State private var confirmDelete = false
    @State private var deleted = false

    var body: some View {
        SettingsSection(header: "Startup") {
            SettingRow(title: "Open at login",
                       hint: loginFailed ? "macOS didn't allow this. Check System Settings › General › Login Items." : nil) {
                SettingSwitch(isOn: Binding(
                    get: { loginEnabled },
                    set: { want in
                        let now = LoginItem.set(want)
                        loginEnabled = now
                        loginFailed = now != want
                        model.setting(\.launchAtLogin).wrappedValue = now
                    }
                ))
            }
        }
        SettingsSection(header: "Queue") {
            SettingRow(title: "Accept matches automatically",
                       hint: "Accepts the ready check as soon as it opens. You can still decline in the client.") {
                SettingSwitch(isOn: model.setting(\.autoAccept))
            }
            RowDivider()
            SettingRow(title: "Notify when a match is found",
                       hint: "Only when the League client isn't in front.") {
                SettingSwitch(isOn: model.setting(\.notifyMatchFound))
            }
        }
        SettingsSection(header: "Builds",
                        footer: "Base builds come from OP.GG when available, otherwise from built-in templates.") {
            SettingRow(title: "Use OP.GG builds") {
                SettingSwitch(isOn: model.setting(\.useOPGG))
            }
        }
        privacy
        SettingsSection {
            SettingRow(title: "Version") {
                Text(Self.version).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .onAppear { loginEnabled = LoginItem.isEnabled }
    }

    private var privacy: some View {
        SettingsSection(header: "Privacy") {
            Text("Stored on your Mac only: settings and your game history (date, champion, role, result, goal result, deaths with time and killer champion). Nothing is sent to ganksense. Downloads: public League data from Riot, and build suggestions from OP.GG if enabled.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            RowDivider()
            SettingRow(title: "Privacy policy") {
                Link(destination: Self.privacyURL) {
                    HStack(spacing: 4) {
                        Text("ganksense.app/privacy")
                        Image(systemName: "arrow.up.right").imageScale(.small)
                    }
                }
            }
            RowDivider()
            SettingRow(title: "Data folder") {
                Button("Show in Finder") {
                    let dir = model.dataFolder
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
            RowDivider()
            SettingRow(title: "Game history",
                       hint: deleted ? "Deleted." : "Settings are kept.") {
                Button("Delete all data…", role: .destructive) { confirmDelete = true }
            }
        }
        .alert("Delete all data?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.deleteAllData()
                deleted = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your game history (every recorded game with its deaths and goal results) and downloaded caches (item and champion data, build suggestions). Your settings are kept. This cannot be undone.")
        }
    }

    private static let privacyURL = URL(string: "https://ganksense.app/privacy") ?? URL(filePath: "/")
    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

private struct OverlaySettings: View {
    let model: AppModel

    var body: some View {
        SettingsSection(header: "In game") {
            SettingRow(title: "Show overlay in game") {
                SettingSwitch(isOn: model.setting(\.overlayEnabled))
            }
            RowDivider()
            SettingRow(title: "Show enemy jungler line",
                       hint: "From the kill feed and objectives only, never positions.") {
                SettingSwitch(isOn: model.setting(\.showJunglerLine))
            }
            RowDivider()
            SettingRow(title: "Show while holding Tab",
                       hint: "Reads the Tab key state only while League is in front. Nothing is recorded.") {
                SettingSwitch(isOn: model.setting(\.showWhileHoldingTab))
            }
            RowDivider()
            SettingRow(title: "Show gold lead",
                       hint: "While holding Tab: item gold, your team and lane against the enemy. An estimate from items owned.") {
                SettingSwitch(isOn: model.setting(\.showGoldLead))
            }
        }
        SettingsSection(header: "Appearance") {
            SettingRow(title: "Position") {
                Picker("", selection: model.setting(\.overlayCorner)) {
                    ForEach(OverlayAnchor.allCases, id: \.self) { anchor in
                        Text(Self.title(anchor)).tag(anchor)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            RowDivider()
            SettingRow(title: "Size") {
                SliderControl(value: model.setting(\.overlayScale), range: 0.8...1.3, step: 0.05)
            }
            RowDivider()
            SettingRow(title: "Champ select banner",
                       hint: "Automatic uses a slim bar when the full banner would cover the League client, like on a laptop screen.") {
                Picker("", selection: model.setting(\.bannerStyle)) {
                    Text("Automatic").tag(BannerStyle.auto)
                    Text("Full").tag(BannerStyle.full)
                    Text("Slim").tag(BannerStyle.slim)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        HStack {
            Spacer()
            Button(model.champSelectPreview ? "Hide banner preview" : "Show banner preview") {
                if model.champSelectPreview { model.endBannerDemo() } else { model.startBannerDemo() }
            }
            .buttonStyle(.bordered)
            .disabled(model.coordinator.phase == .client(.champSelect))
            .help("The champ select banner with sample data, above the League client or where it would be")
            if let end = model.overlayPreviewEndsAt {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    Button("Showing… \(max(1, Int(end.timeIntervalSince(context.date).rounded(.up))))s") {}
                        .buttonStyle(.bordered)
                        .disabled(true)
                }
            } else {
                Button("Show overlay preview") { model.showOverlayPreview?() }
                    .buttonStyle(.bordered)
                    .disabled(model.showOverlayPreview == nil)
            }
        }
    }

    static func title(_ anchor: OverlayAnchor) -> String {
        switch anchor {
        case .rightUpper: "Right, upper"
        case .rightMiddle: "Right, middle"
        case .leftUpper: "Left, upper"
        case .topCenter: "Top, centre"
        }
    }
}

private struct GoalSettings: View {
    let model: AppModel

    var body: some View {
        SettingsSection(header: "Targets",
                        footer: "One target and minute per goal, used in every game. Choose the goal for your next game from the menu bar icon.") {
            ForEach(Array(GoalPreset.allCases.enumerated()), id: \.element) { index, preset in
                if index > 0 { RowDivider() }
                SettingRow(title: model.coordinator.settings.title(for: preset)) {
                    ValueStepper(text: GoalTargetText.text(model.coordinator.settings.target(for: preset), preset),
                                 value: target(preset), range: GoalPicker.range(preset), step: GoalPicker.step(preset))
                }
                if let minutes = model.coordinator.settings.minutes(for: preset) {
                    RowDivider()
                    SettingRow(title: preset == .deathsBefore14 ? "Counted until" : "Checked at") {
                        ValueStepper(text: "\(minutes):00", value: minutesBinding(preset),
                                     range: GoalPicker.minutesRange, step: 1)
                    }
                }
            }
        }

        Button("Reset targets") {
            var s = model.coordinator.settings
            s.resetTargets()
            model.coordinator.updateSettings(s)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .disabled(model.coordinator.settings.goalTargets.isEmpty && model.coordinator.settings.goalMinutes.isEmpty)
    }

    private func minutesBinding(_ preset: GoalPreset) -> Binding<Double> {
        Binding(
            get: { Double(model.coordinator.settings.minutes(for: preset) ?? 0) },
            set: { value in
                var s = model.coordinator.settings
                s.setMinutes(Int(value.rounded()), for: preset)
                model.coordinator.updateSettings(s)
            }
        )
    }

    private func target(_ preset: GoalPreset) -> Binding<Double> {
        Binding(
            get: { model.coordinator.settings.target(for: preset) },
            set: { value in
                var s = model.coordinator.settings
                s.setTarget(value, for: preset)
                model.coordinator.updateSettings(s)
            }
        )
    }
}

private struct TiltSettingsView: View {
    let model: AppModel

    var body: some View {
        let tilt = model.coordinator.settings.tilt
        SettingsSection(header: "Break reminders",
                        footer: "One calm notification and a card in the menu. It never blocks queueing.") {
            SettingRow(title: "Nudge me to take breaks") {
                SettingSwitch(isOn: model.setting(\.tilt.enabled))
            }
            RowDivider()
            SettingRow(title: "After a loss streak of") {
                ValueStepper(text: "\(tilt.lossStreak) games", value: intBinding(\.tilt.lossStreak),
                             range: 2...6, step: 1)
            }
            .disabled(!tilt.enabled)
            RowDivider()
            SettingRow(title: "After playing for") {
                ValueStepper(text: String(format: "%.1f hours", tilt.sessionHours),
                             value: model.setting(\.tilt.sessionHours), range: 1...5, step: 0.5)
            }
            .disabled(!tilt.enabled)
        }
    }

    private func intBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(model.coordinator.settings[keyPath: keyPath]) },
            set: { value in
                var s = model.coordinator.settings
                s[keyPath: keyPath] = Int(value.rounded())
                model.coordinator.updateSettings(s)
            }
        )
    }
}
