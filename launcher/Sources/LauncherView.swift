import AppKit
import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var updateController: LauncherUpdateController
    @State private var showSettings = false
    @State private var showResetConfirmation = false

    private let heroImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MacticianHero", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        GeometryReader { geometry in
            let surfaceWidth = max(0, geometry.size.width - LauncherTheme.Metric.outerInset * 2)
            let surfaceHeight = max(0, geometry.size.height - LauncherTheme.Metric.outerInset * 2)
            ZStack {
                LauncherTheme.ColorToken.window.ignoresSafeArea()
                clientSurface(
                    compactHeight: geometry.size.height < 720,
                    availableWidth: surfaceWidth,
                    availableHeight: surfaceHeight
                )
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.shouldShowTelemetryNotice) {
            LauncherTelemetryNoticeView(model: model)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showSettings) {
            LauncherSettingsView(
                model: model,
                updateController: updateController,
                showResetConfirmation: $showResetConfirmation
            )
        }
        .sheet(item: $model.announcement) { announcement in
            LauncherAnnouncementView(
                announcement: announcement,
                dismiss: model.dismissAnnouncement
            )
            .interactiveDismissDisabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshHotkeyStatus()
        }
    }

    private func clientSurface(
        compactHeight: Bool,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        ZStack {
            artwork

            VStack(spacing: 0) {
                header
                hero(compact: compactHeight)
                Spacer(minLength: LauncherTheme.Spacing.medium)
                LauncherStateDeck(model: model, showSettings: $showSettings)
                    .frame(
                        width: min(
                            LauncherTheme.Metric.contentMaxWidth,
                            max(0, availableWidth - LauncherTheme.Metric.stateDeckInset * 2)
                        )
                    )
                footer
            }
            .frame(width: availableWidth)
        }
        .frame(width: availableWidth, height: availableHeight)
        .background(LauncherTheme.ColorToken.surface)
        .clipShape(
            RoundedRectangle(cornerRadius: LauncherTheme.Metric.surfaceRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LauncherTheme.Metric.surfaceRadius, style: .continuous)
                .stroke(LauncherTheme.ColorToken.neutralBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.52), radius: 22, y: 10)
    }

    private var artwork: some View {
        ZStack {
            if let heroImage {
                Image(nsImage: heroImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                LauncherTheme.ColorToken.surface
            }

            LinearGradient(
                stops: [
                    .init(color: LauncherTheme.ColorToken.surface.opacity(0.06), location: 0),
                    .init(color: LauncherTheme.ColorToken.surface.opacity(0.22), location: 0.42),
                    .init(color: LauncherTheme.ColorToken.surface.opacity(0.9), location: 0.78),
                    .init(color: LauncherTheme.ColorToken.surface, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [LauncherTheme.ColorToken.surface.opacity(0.9), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: LauncherTheme.Metric.trafficLightReserve)

            LauncherBrandMark()
                .padding(.trailing, LauncherTheme.Spacing.medium)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mactician")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(LauncherTheme.ColorToken.textPrimary)
                Text(LauncherL10n.text("header.subtitle"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(LauncherTheme.ColorToken.textTertiary)
            }

            LauncherDragRegion()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)

            HStack(spacing: LauncherTheme.Spacing.small) {
                Circle()
                    .fill(LauncherTheme.ColorToken.interactive)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(LauncherL10n.format("header.game_version_format", model.gameDisplayVersion))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(LauncherTheme.ColorToken.textPrimary)
            }
            .padding(.leading, LauncherTheme.Spacing.medium)
            .accessibilityElement(children: .combine)

            Text(LauncherBuildInfo.display)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(LauncherTheme.ColorToken.textSecondary)
                .padding(.leading, LauncherTheme.Spacing.medium)

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(LauncherIconButtonStyle())
            .accessibilityLabel(LauncherL10n.text("settings.open"))
            .help(LauncherL10n.text("settings.open"))
            .padding(.leading, LauncherTheme.Spacing.medium)
        }
        .padding(.trailing, LauncherTheme.Spacing.xLarge)
        .frame(height: LauncherTheme.Metric.headerHeight)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .bottom) { LauncherDivider() }
    }

    private func hero(compact: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: LauncherTheme.Spacing.small) {
                Text(LauncherL10n.text("hero.eyebrow"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(1.1)
                    .foregroundColor(LauncherTheme.ColorToken.interactive)

                Text(LauncherL10n.text("hero.title"))
                    .font(.system(size: compact ? 30 : 34, weight: .black, design: .serif))
                    .foregroundColor(LauncherTheme.ColorToken.textPrimary)
                    .shadow(color: Color.black.opacity(0.45), radius: 6, y: 2)

                if !compact {
                    Text(LauncherL10n.text("hero.description"))
                        .font(.system(size: 13))
                        .foregroundColor(LauncherTheme.ColorToken.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, LauncherTheme.Metric.trafficLightReserve)
        .frame(height: compact ? 104 : 152, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: LauncherTheme.Spacing.small) {
            Label(LauncherL10n.text("footer.private_build"), systemImage: "lock.fill")
            Text("\u{00b7}")
            Text(LauncherL10n.text("footer.apple_silicon"))
            Text("\u{00b7}")
            Link(destination: MacticianIdentity.websiteURL) {
                Label(LauncherL10n.text("footer.developer_website"), systemImage: "link")
                    .foregroundColor(LauncherTheme.ColorToken.interactive)
            }
            .buttonStyle(.plain)
            .help(LauncherL10n.text("footer.developer_website"))
            Spacer()
            Text(LauncherL10n.text("footer.legal"))
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(LauncherTheme.ColorToken.textTertiary)
        .padding(.horizontal, LauncherTheme.Metric.trafficLightReserve)
        .frame(height: 36)
    }
}
