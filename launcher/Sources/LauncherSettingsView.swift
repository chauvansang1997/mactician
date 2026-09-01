import SwiftUI

struct LauncherSettingsView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var updateController: LauncherUpdateController
    @Binding var showResetConfirmation: Bool
    @Environment(\.presentationMode) private var presentationMode
    @State private var showsResourceHelp = false
    @State private var showsNativeForgetConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            LauncherDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: LauncherTheme.Spacing.large) {
                    if model.nativeIPadRuntimeEnabled {
                        experimentalSection
                        LauncherDivider()
                    }
                    if !model.isNativeIPadRuntimeSelected {
                        gameSection
                        LauncherDivider()
                        performanceSection
                        LauncherDivider()
                    }
                    if !model.isNativeIPadRuntimeSelected {
                        telemetrySection
                        LauncherDivider()
                    }
                    if !model.isNativeIPadRuntimeSelected {
                        hotkeySection
                        LauncherDivider()
                    }
                    updateSection
                    LauncherDivider()
                    maintenanceSection
                }
                .padding(LauncherTheme.Spacing.large)
            }
        }
        .frame(
            width: LauncherTheme.Metric.sheetWidth,
            height: model.nativeIPadRuntimeEnabled ? 660 : 620
        )
        .background(LauncherTheme.ColorToken.surface)
        .preferredColorScheme(.dark)
        .onAppear { model.refreshHotkeyStatus() }
        .alert(
            LauncherL10n.text("reset.confirmation.title"),
            isPresented: $showResetConfirmation
        ) {
            Button(LauncherL10n.text("action.cancel"), role: .cancel) { }
            Button(LauncherL10n.text("reset.confirmation.action"), role: .destructive) {
                model.reset()
            }
        } message: {
            Text(LauncherL10n.text("reset.confirmation.message"))
        }
        .alert(
            LauncherL10n.text("native_ipad.forget.confirmation.title"),
            isPresented: $showsNativeForgetConfirmation
        ) {
            Button(LauncherL10n.text("action.cancel"), role: .cancel) { }
            Button(LauncherL10n.text("native_ipad.forget"), role: .destructive) {
                model.forgetNativeIPadApplication()
            }
        } message: {
            Text(LauncherL10n.text("native_ipad.forget.confirmation.message"))
        }
    }

    private var header: some View {
        HStack(spacing: LauncherTheme.Spacing.medium) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(LauncherTheme.ColorToken.interactive)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LauncherTheme.Spacing.xSmall) {
                Text(LauncherL10n.text("settings.title"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(LauncherTheme.ColorToken.textPrimary)
                Text(LauncherL10n.text("settings.description"))
                    .font(.system(size: 12))
                    .foregroundColor(LauncherTheme.ColorToken.textSecondary)
            }
            Spacer()
            Button {
                presentationMode.wrappedValue.dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(LauncherIconButtonStyle())
            .accessibilityLabel(LauncherL10n.text("action.close"))
            .help(LauncherL10n.text("action.close"))
        }
        .padding(.horizontal, LauncherTheme.Spacing.large)
        .frame(height: 72)
    }

    private var gameSection: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Spacing.regular) {
            LauncherSectionHeader(
                LauncherL10n.text("settings.game.title"),
                description: model.settingsLocked
                    ? LauncherL10n.text("settings.runtime_locked")
                    : nil
            )
            settingRow(LauncherL10n.text("field.game_language")) {
                LauncherMenuControl(value: model.selectedLanguage.title) {
                    ForEach(GameLanguage.supported) { language in
                        Button {
                            model.selectLanguage(language.id)
                        } label: {
                            if language.id == model.selectedLanguageID {
                                Label(language.title, systemImage: "checkmark")
                            } else {
                                Text(language.title)
                            }
                        }
                    }
                }
                .frame(width: 230)
            }
            settingRow(LauncherL10n.text("field.effects_quality")) {
                LauncherMenuControl(value: model.selectedEffectsQuality.title) {
                    ForEach(EffectsQuality.allCases) { quality in
                        Button {
                            model.selectEffectsQuality(quality.id)
                        } label: {
                            if quality.id == model.selectedEffectsQualityID {
                                Label(quality.title, systemImage: "checkmark")
                            } else {
                                Text(quality.title)
                            }
                        }
                    }
                }
                .frame(width: 230)
            }
            settingRow(LauncherL10n.text("field.interface_scale")) {
                LauncherMenuControl(value: "\(model.selectedUIScalePercent)%") {
                    ForEach(model.availableUIScalePercents, id: \.self) { percent in
                        Button {
                            model.selectUIScalePercent(percent)
                        } label: {
                            if percent == model.selectedUIScalePercent {
                                Label("\(percent)%", systemImage: "checkmark")
                            } else {
                                Text("\(percent)%")
                            }
                        }
                    }
                }
                .frame(width: 230)
            }
        }
        .disabled(model.settingsLocked)
    }

    private var experimentalSection: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Spacing.regular) {
            LauncherSectionHeader(
                LauncherL10n.text("experimental.title"),
                description: LauncherL10n.text("native_ipad.warning")
            )

            settingRow(LauncherL10n.text("experimental.runtime")) {
                LauncherMenuControl(value: runtimeTitle(model.selectedRuntimeKind)) {
                    ForEach(GameRuntimeKind.allCases) { kind in
                        Button {
                            model.selectRuntime(kind)
                        } label: {
                            if kind == model.selectedRuntimeKind {
                                Label(runtimeTitle(kind), systemImage: "checkmark")
                            } else {
                                Text(runtimeTitle(kind))
                            }
                        }
                        .disabled(kind == .nativeIPadExperimental && !model.nativeIPadRuntimeEnabled)
                    }
                }
                .frame(width: 260)
            }
            .disabled(model.runtimeSelectionLocked)

            if model.isNativeIPadRuntimeSelected {
                Text(LauncherL10n.text("native_ipad.disclaimer"))
                    .font(.system(size: 12))
                    .foregroundColor(LauncherTheme.ColorToken.warning)
                    .fixedSize(horizontal: false, vertical: true)

                if let descriptor = model.nativeIPadDescriptor {
                    VStack(alignment: .leading, spacing: LauncherTheme.Spacing.xSmall) {
                        nativeMetadataRow(
                            LauncherL10n.text("native_ipad.application"),
                            descriptor.displayName
                        )
                        if let version = model.nativeIPadVersionSummary {
                            nativeMetadataRow(LauncherL10n.text("native_ipad.version"), version)
                        }
                        nativeMetadataRow(
                            LauncherL10n.text("native_ipad.bundle_identifier"),
                            descriptor.bundleIdentifier
                        )
                        nativeMetadataRow(
                            LauncherL10n.text("native_ipad.signature"),
                            LauncherL10n.text("native_ipad.signature.\(descriptor.signatureKind.rawValue)")
                        )
                        if let date = model.nativeIPadLastValidatedAt {
                            HStack {
                                Text(LauncherL10n.text("native_ipad.last_validated"))
                                Spacer()
                                Text(date, style: .relative)
                            }
                            .font(.system(size: 11))
                            .foregroundColor(LauncherTheme.ColorToken.textTertiary)
                        }
                    }
                    .padding(LauncherTheme.Spacing.regular)
                    .background(
                        RoundedRectangle(cornerRadius: LauncherTheme.Metric.controlRadius)
                            .fill(LauncherTheme.ColorToken.raisedControl.opacity(0.62))
                    )
                } else if let error = model.nativeIPadValidationError {
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(LauncherTheme.ColorToken.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: LauncherTheme.Spacing.medium) {
                    Button(
                        LauncherL10n.text(
                            model.nativeIPadDescriptor == nil
                                ? "native_ipad.choose"
                                : "native_ipad.replace"
                        )
                    ) { model.chooseNativeIPadApplication() }
                        .buttonStyle(LauncherSecondaryButtonStyle())

                    if model.nativeIPadDescriptor != nil {
                        Button(LauncherL10n.text("native_ipad.revalidate")) {
                            model.revalidateNativeIPadApplication()
                        }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                    }
                    if model.nativeIPadHasSavedState {
                        Button(LauncherL10n.text("native_ipad.forget")) {
                            showsNativeForgetConfirmation = true
                        }
                        .buttonStyle(LauncherTertiaryButtonStyle(tint: LauncherTheme.ColorToken.danger))
                    }
                }
                .disabled(model.maintenanceLocked)
            }
        }
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Spacing.regular) {
            LauncherSectionHeader(
                LauncherL10n.text("settings.performance.title"),
                description: model.hostResourceSummary
            )

            HStack(spacing: LauncherTheme.Spacing.regular) {
                VStack(alignment: .leading, spacing: LauncherTheme.Spacing.xSmall) {
                    Text(LauncherL10n.text("settings.performance.recommended"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(LauncherTheme.ColorToken.success)
                    Text(
                        LauncherL10n.format(
                            "settings.performance.recommended_format",
                            model.recommendedResources.memoryMB / 1024,
                            model.recommendedResources.cpuCores
                        )
                    )
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(LauncherTheme.ColorToken.textPrimary)
                }
                Spacer()
                Button(LauncherL10n.text("settings.performance.apply")) {
                    model.applyRecommendedResources()
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .disabled(model.settingsLocked || usesRecommendedResources)
            }
            .padding(LauncherTheme.Spacing.regular)
            .background(
                RoundedRectangle(cornerRadius: LauncherTheme.Metric.controlRadius)
                    .fill(LauncherTheme.ColorToken.success.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LauncherTheme.Metric.controlRadius)
                    .stroke(LauncherTheme.ColorToken.success.opacity(0.26), lineWidth: 1)
            )

            settingRow(LauncherL10n.text("field.android_ram")) {
                LauncherMenuControl(value: "\(model.selectedMemoryMB / 1024) GB") {
                    ForEach(model.availableMemoryMB, id: \.self) { memory in
                        Button {
                            model.selectMemoryMB(memory)
                        } label: {
                            if memory == model.selectedMemoryMB {
                                Label("\(memory / 1024) GB", systemImage: "checkmark")
                            } else {
                                Text("\(memory / 1024) GB")
                            }
                        }
                    }
                }
                .frame(width: 230)
            }
            .disabled(model.settingsLocked)

            settingRow(LauncherL10n.text("field.vcpu")) {
                LauncherMenuControl(
                    value: LauncherL10n.format("field.vcpu_value_format", model.selectedCPUCores)
                ) {
                    ForEach(model.availableCPUCores, id: \.self) { cores in
                        let title = LauncherL10n.format("field.vcpu_value_format", cores)
                        Button {
                            model.selectCPUCores(cores)
                        } label: {
                            if cores == model.selectedCPUCores {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                }
                .frame(width: 230)
            }
            .disabled(model.settingsLocked)

            DisclosureGroup(isExpanded: $showsResourceHelp) {
                VStack(alignment: .leading, spacing: LauncherTheme.Spacing.regular) {
                    resourceHelp("settings.performance.help.balanced.title", "settings.performance.help.balanced.body")
                    resourceHelp("settings.performance.help.ram.title", "settings.performance.help.ram.body")
                    resourceHelp("settings.performance.help.cpu.title", "settings.performance.help.cpu.body")
                }
                .padding(.top, LauncherTheme.Spacing.medium)
            } label: {
                Text(LauncherL10n.text("settings.performance.help.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(LauncherTheme.ColorToken.interactive)
            }
        }
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Spacing.regular) {
            LauncherSectionHeader(
                LauncherL10n.text("hotkeys.title"),
                description: LauncherL10n.text("hotkeys.description")
            )

            HStack(spacing: LauncherTheme.Spacing.medium) {
                Image(systemName: hotkeyStatusSymbol)
                    .foregroundColor(hotkeyStatusColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LauncherTheme.Spacing.xSmall) {
                    Text(LauncherL10n.text("hotkeys.status.label"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(LauncherTheme.ColorToken.textTertiary)
                    Text(LauncherL10n.text(model.hotkeyStatus.localizationKey))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(LauncherTheme.ColorToken.textPrimary)
                }
                Spacer()
                if needsPermissionAction {
                    Button(LauncherL10n.text("hotkeys.grant_access")) {
                        model.requestInputPermissions()
                    }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                }
            }
            .padding(LauncherTheme.Spacing.regular)
            .background(
                RoundedRectangle(cornerRadius: LauncherTheme.Metric.controlRadius)
                    .fill(
                        needsHotkeyAction
                            ? LauncherTheme.ColorToken.warning.opacity(0.09)
                            : LauncherTheme.ColorToken.raisedControl.opacity(0.62)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: LauncherTheme.Metric.controlRadius)
                    .stroke(
                        needsHotkeyAction
                            ? LauncherTheme.ColorToken.warning.opacity(0.36)
                            : Color.clear,
                        lineWidth: 1
                    )
            )

            Text(LauncherL10n.text("hotkeys.shortcuts"))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(LauncherTheme.ColorToken.textSecondary)
        }
        .accessibilityElement(children: .contain)
    }

    private var telemetrySection: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Spacing.regular) {
            LauncherSectionHeader(
                LauncherL10n.text("telemetry.settings.title"),
                description: LauncherL10n.text("telemetry.settings.description")
            )

            HStack(spacing: LauncherTheme.Spacing.regular) {
                Toggle(
                    LauncherL10n.text("telemetry.extended.toggle"),
                    isOn: Binding(
                        get: { model.extendedDiagnosticsEnabled },
                        set: { model.setExtendedDiagnosticsEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                Spacer()
                if model.extendedDiagnosticsEnabled {
                    Link(
                        LauncherL10n.text("telemetry.extended.data_link"),
                        destination: MacticianIdentity.extendedDiagnosticsURL
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(LauncherTheme.ColorToken.interactive)
                }
            }

            Text(LauncherL10n.text("telemetry.settings.basic_note"))
                .font(.system(size: 12))
                .foregroundColor(LauncherTheme.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Spacing.regular) {
            LauncherSectionHeader(
                LauncherL10n.text("settings.maintenance.title"),
                description: LauncherL10n.text(
                    model.isNativeIPadRuntimeSelected
                        ? "native_ipad.maintenance.description"
                        : "settings.maintenance.description"
                )
            )

            HStack(spacing: LauncherTheme.Spacing.medium) {
                if !model.isNativeIPadRuntimeSelected {
                    Button(LauncherL10n.text("action.repair_installation")) { model.repair() }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .disabled(model.maintenanceLocked)
                }
                Button(LauncherL10n.text("action.data_folder")) { model.openDataFolder() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                Button(LauncherL10n.text("action.view_log")) { model.openLog() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
            }

            if !model.isNativeIPadRuntimeSelected {
                LauncherDivider()

                HStack(alignment: .center, spacing: LauncherTheme.Spacing.regular) {
                    Text(LauncherL10n.text("settings.maintenance.reset_description"))
                        .font(.system(size: 12))
                        .foregroundColor(LauncherTheme.ColorToken.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(LauncherL10n.text("action.reset_all_data")) {
                        showResetConfirmation = true
                    }
                    .buttonStyle(LauncherDestructiveButtonStyle())
                    .disabled(model.maintenanceLocked)
                }
            }
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Spacing.regular) {
            LauncherSectionHeader(
                LauncherL10n.text("updates.title"),
                description: LauncherL10n.text("updates.description")
            )

            HStack(spacing: LauncherTheme.Spacing.regular) {
                VStack(alignment: .leading, spacing: LauncherTheme.Spacing.xSmall) {
                    Text(LauncherBuildInfo.display)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(LauncherTheme.ColorToken.textPrimary)
                    Text(LauncherL10n.text("updates.automatic_checks"))
                        .font(.system(size: 12))
                        .foregroundColor(LauncherTheme.ColorToken.textSecondary)
                }
                Spacer()
                Button(LauncherL10n.text("updates.check")) {
                    updateController.checkForUpdates()
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .disabled(!updateController.canCheckForUpdates)
            }
        }
    }

    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: LauncherTheme.Spacing.regular) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(LauncherTheme.ColorToken.textPrimary)
            Spacer()
            content()
        }
        .frame(minHeight: LauncherTheme.Metric.standardControlHeight)
    }

    private func resourceHelp(_ titleKey: String, _ bodyKey: String) -> some View {
        VStack(alignment: .leading, spacing: LauncherTheme.Spacing.xSmall) {
            Text(LauncherL10n.text(titleKey))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(LauncherTheme.ColorToken.textPrimary)
            Text(LauncherL10n.text(bodyKey))
                .font(.system(size: 12))
                .foregroundColor(LauncherTheme.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runtimeTitle(_ kind: GameRuntimeKind) -> String {
        LauncherL10n.text(
            kind == .androidEmulator
                ? "experimental.runtime.android"
                : "experimental.runtime.native_ipad"
        )
    }

    private func nativeMetadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
        .foregroundColor(LauncherTheme.ColorToken.textSecondary)
    }

    private var usesRecommendedResources: Bool {
        model.selectedMemoryMB == model.recommendedResources.memoryMB
            && model.selectedCPUCores == model.recommendedResources.cpuCores
    }

    private var needsHotkeyAction: Bool {
        model.hotkeyStatus == .permissionRequired
            || model.hotkeyStatus == .unavailable
    }

    private var needsPermissionAction: Bool {
        model.hotkeyStatus == .permissionRequired
    }

    private var hotkeyStatusColor: Color {
        switch model.hotkeyStatus {
        case .ready, .active: return LauncherTheme.ColorToken.success
        case .permissionRequired, .unavailable: return LauncherTheme.ColorToken.warning
        }
    }

    private var hotkeyStatusSymbol: String {
        switch model.hotkeyStatus {
        case .ready, .active: return "checkmark.circle.fill"
        case .permissionRequired, .unavailable: return "exclamationmark.circle.fill"
        }
    }
}
