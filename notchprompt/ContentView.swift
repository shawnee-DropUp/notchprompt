//
//  ContentView.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import SwiftUI
import AppKit
import CoreGraphics

struct ContentView: View {
    @ObservedObject private var model = PrompterModel.shared

    private let rowLabelWidth: CGFloat = 164
    private let valueWidth: CGFloat = 56

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerSection
                playbackSection
                appearanceSection
                displaySection
                privacySection
                shortcutsSection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(ScrollBounceBehaviorModifier())
        .frame(minWidth: 620, minHeight: 460)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.title3.weight(.semibold))
            Text("Configure playback, appearance, and display behavior for the overlay.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    private var playbackSection: some View {
        SettingsSection(title: "Playback") {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow(
                    title: "Speed",
                    valueText: "\(Int(model.speedPointsPerSecond))",
                    slider: Slider(value: $model.speedPointsPerSecond, in: 10...300, step: 5)
                )

                HStack(alignment: .firstTextBaseline) {
                    Text("Scroll mode")
                        .frame(width: rowLabelWidth, alignment: .leading)
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.scrollMode },
                            set: { model.setScrollMode($0) }
                        )
                    ) {
                        Text("Infinite").tag(PrompterModel.ScrollMode.infinite)
                        Text("Stop at end").tag(PrompterModel.ScrollMode.stopAtEnd)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                HStack {
                    Text("Countdown")
                        .frame(width: rowLabelWidth, alignment: .leading)
                    Picker("", selection: $model.countdownBehavior) {
                        ForEach(PrompterModel.CountdownBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Spacer(minLength: 0)
                }

                sliderRow(
                    title: "Countdown duration",
                    valueText: "\(model.countdownSeconds)s",
                    slider: Slider(
                        value: Binding(
                            get: { Double(model.countdownSeconds) },
                            set: { model.countdownSeconds = Int($0.rounded()) }
                        ),
                        in: 0...10,
                        step: 1
                    )
                    .disabled(model.countdownBehavior == .never)
                )
            }
        }
    }

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow(
                    title: "Font size",
                    valueText: "\(Int(model.fontSize))",
                    slider: Slider(value: $model.fontSize, in: 12...40, step: 1)
                )

                sliderRow(
                    title: "Overlay width",
                    valueText: "\(Int(model.overlayWidth))",
                    slider: Slider(value: $model.overlayWidth, in: 400...1200, step: 10)
                )

                sliderRow(
                    title: "Overlay height",
                    valueText: "\(Int(model.overlayHeight))",
                    slider: Slider(value: $model.overlayHeight, in: 120...300, step: 2)
                )
            }
        }
    }

    private var displaySection: some View {
        SettingsSection(title: "Display") {
            HStack {
                Text("Show overlay on")
                    .frame(width: rowLabelWidth, alignment: .leading)
                Picker("", selection: $model.selectedScreenID) {
                    Text("Auto (Built-in)").tag(CGDirectDisplayID(0))
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        Text(screen.localizedName).tag(screenID(for: screen))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer(minLength: 0)
            }
        }
    }

    private var privacySection: some View {
        SettingsSection(title: "Privacy") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show overlay", isOn: $model.isOverlayVisible)
                Toggle("Limit screen sharing capture", isOn: $model.privacyModeEnabled)
                Text("Best effort only. Capture behavior can vary by app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shortcutsSection: some View {
        SettingsSection(title: "Keyboard Shortcuts") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Use arrow keys for speed and reset", isOn: $model.captureArrowKeys)
                Text("While on, Notchprompt claims the plain arrow keys system-wide — "
                     + "they will not work in other apps until you turn this off or quit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.captureArrowKeys {
                    shortcutRow("Up arrow", "Increase speed")
                    shortcutRow("Down arrow", "Decrease speed")
                    shortcutRow("Left arrow", "Reset scroll")
                }

                Divider().padding(.vertical, 4)

                shortcutRow("Option+Command+P", "Start / Pause")
                shortcutRow("Option+Command+R", "Reset scroll")
                shortcutRow("Option+Command+J", "Jump back 5 seconds")
                shortcutRow("Option+Command+H", "Toggle privacy mode")
                shortcutRow("Option+Command+O", "Toggle overlay visibility")
                shortcutRow("Option+Command+=", "Increase speed")
                shortcutRow("Option+Command+-", "Decrease speed")
            }
        }
    }

    @ViewBuilder
    private func sliderRow<SliderView: View>(
        title: String,
        valueText: String,
        slider: SliderView
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: rowLabelWidth, alignment: .leading)
            slider
            Text(valueText)
                .foregroundStyle(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 175, alignment: .leading)
            Text(action)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
    }

    private func screenID(for screen: NSScreen) -> CGDirectDisplayID {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return CGDirectDisplayID(n.uint32Value)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox(label: Text(title).font(.headline)) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewDisplayName("Default")

        ContentView()
            .frame(width: 620, height: 360)
            .previewDisplayName("Compact Height")
    }
}
#endif

private struct ScrollBounceBehaviorModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }
}
