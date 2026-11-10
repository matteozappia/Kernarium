// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings while the guest runs, opened from the side keys. It slides up over
/// the guest, which keeps running behind it: watch the stats, install an app
/// from Files, connect a computer with adb and make a bug report. An
/// operation on the guest dismisses Settings and shows the full-screen
/// progress, and then how it ended.
struct SessionSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var picked = Import.apk
    @State private var copied = false
    @State private var detent: PresentationDetent

    init(large: Bool) {
        _detent = State(initialValue: large ? .large : .medium)
    }

    var body: some View {
        let session = model.session
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if model.capabilities.statistics { stats(session) }
                    if normalSession, model.capabilities.apkInstall { apps }
                    if normalSession, model.capabilities.adbOverNetwork { developer(session) }
                    if normalSession, model.capabilities.bugReport { diagnostics }
                }
                .task {
                    guard let target = model.sessionPreset.settingsScroll else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .task { await model.watchSettings() }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackground(Color(.systemGroupedBackground))
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .fileImporter(
            isPresented: $importing, allowedContentTypes: [picked == .zip ? .zip : InstallRefusal.pickerType]
        ) { result in
            guard case .success(let url) = result else { return }
            // Settings goes; the operation, or the refusal of a file of the
            // wrong kind, is on the full-screen overlay.
            if picked == .zip { model.flashPicked(url) } else { model.installPicked(url) }
            dismiss()
        }
    }

    /// What the file picker is opened for.
    private enum Import {
        case apk
        case zip
    }

    /// Recovery runs no adb: its operations are for a normal session.
    private var normalSession: Bool {
        if case .running(.normal) = model.phase { return true }
        return false
    }

    // MARK: Diagnostics

    /// Tapping the row starts at once.
    private var diagnostics: some View {
        Section("Diagnostics") {
            Button {
                dismiss()
                model.createBugReport()
            } label: {
                HStack(spacing: 12) {
                    IconTile(symbol: "ladybug.fill")
                    Text("Create bug report\u{2026}")
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                }
            }
        }
    }

    // MARK: Apps

    private var apps: some View {
        Section("Apps") {
            Button {
                picked = .apk
                importing = true
            } label: {
                HStack(spacing: 12) {
                    IconTile(symbol: "square.and.arrow.down.fill")
                    Text("Install APK\u{2026}")
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text("From Files")
                        .font(.subheadline)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            // Recovery installs the package: Android restarts into it.
            Button {
                picked = .zip
                importing = true
            } label: {
                HStack(spacing: 12) {
                    IconTile(symbol: "shippingbox.fill")
                    Text("Flash ZIP\u{2026}")
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text("In recovery")
                        .font(.subheadline)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
        }
    }

    // MARK: Developer

    private func developer(_ session: SessionState) -> some View {
        Section {
            Toggle(isOn: Binding(get: { session.adb }, set: { model.setAdbOverNetwork($0) })) {
                HStack(spacing: 12) {
                    IconTile(symbol: "terminal.fill", color: session.adb ? .accentColor : .gray)
                    Text("ADB over network")
                }
            }
            .disabled(!session.adb && !model.adbOverNetworkAvailable)
            if session.adb {
                if let address = session.adbAddress {
                    connectCommand("adb connect \(address):\(AdbNetworkBridge.defaultPort)")
                } else {
                    Text(AdbNetworkMessages.noAddress)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Developer")
        } footer: {
            if let problem = session.adbProblem {
                Text(problem).foregroundStyle(.red)
            } else if session.adb {
                Text("The guest asks to allow the computer the first time it connects. ADB turns off when the guest stops or USB debugging is turned off.")
            } else if !model.adbOverNetworkAvailable {
                Text("Turn on USB debugging in the guest\u{2019}s Developer options to use ADB over network.")
            } else {
                Text("Lets a computer on the same network connect to the guest with adb.")
            }
        }
    }

    /// The command to type on the computer, with a button that copies it.
    private func connectCommand(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On a computer on the same network, run:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(command)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = command
                    withAnimation(.snappy) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation(.snappy) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Copied" : "Copy command")
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(minHeight: 46)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .padding(.vertical, 4)
    }

    // MARK: Stats

    private func stats(_ session: SessionState) -> some View {
        @Bindable var session = session
        let memoryMiB = model.guest?.memoryMiB ?? Limits.defaultMemoryRangeMiB.lowerBound
        return Section("Stats") {
            LabeledContent {
                HStack(spacing: 10) {
                    Sparkline(values: session.readout.history)
                        .frame(width: 44, height: 18)
                    value(session.readout.cpuText)
                        .frame(minWidth: 44, alignment: .trailing)
                }
            } label: {
                rowLabel("CPU", symbol: "cpu")
            }
            // The rows read the statistics while the section shows; the CPU
            // row stands for it, since a modifier on the section would apply
            // to every row.
            .onAppear { model.statistics(.settings, visible: true) }
            .onDisappear { model.statistics(.settings, visible: false) }
            LabeledContent {
                usage(session.readout.memoryText(of: memoryMiB), share: session.readout.memoryFraction(of: memoryMiB))
            } label: {
                rowLabel("Memory", symbol: "memorychip")
            }
            LabeledContent {
                usage(session.readout.vramText, share: session.readout.vramFraction)
            } label: {
                rowLabel("VRAM", symbol: "cube")
            }
            LabeledContent {
                value(session.readout.fpsText)
            } label: {
                rowLabel("Frame rate", symbol: "speedometer")
            }
            Toggle(isOn: $session.showStats.animation(.snappy)) {
                rowLabel("Show on screen", symbol: "rectangle.topthird.inset.filled")
            }
        }
        .id("stats")
    }

    /// A figure of memory in use after a bar of its share, as the CPU
    /// figure follows its sparkline.
    private func usage(_ text: String, share: Double?) -> some View {
        HStack(spacing: 10) {
            ShareBar(share: share)
                .frame(width: 44, height: 6)
            value(text)
        }
    }

    private func rowLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .rounded).weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
    }
}
