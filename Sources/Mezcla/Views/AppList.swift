import MezclaCore
import SwiftUI

/// "Playing Now" plus, optionally, the other apps that use audio, so they can be set before they play.
struct AppList: View {
    @Environment(MixerViewModel.self) private var model

    var body: some View {
        let playing = model.playingApps
        let recording = model.microphoneOnlyApps
        let idle = model.idleApps
        // Tab titles need room, so the name column opens fully when tabs are listed.
        let nameWidth = model.hasBrowserTabs
            ? NameColumn.maximumWidth
            : NameColumn.width(for: (playing + recording + idle).map { app in (DisplayName.of(app), badgeWidth(for: app)) })

        Group {
            if playing.isEmpty, recording.isEmpty, idle.isEmpty {
                EmptyAppList(showsIdleApps: model.preferences.showsIdleApps)
                    .transition(.opacity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if !playing.isEmpty {
                            SectionTitle("Playing Now")
                            rows(playing, nameWidth: nameWidth)
                        }
                        if !recording.isEmpty {
                            SectionTitle("Using Microphone")
                                .padding(.top, playing.isEmpty ? 0 : 8)
                            rows(recording, nameWidth: nameWidth)
                        }
                        if !idle.isEmpty {
                            SectionTitle("Other Apps")
                                .padding(.top, playing.isEmpty && recording.isEmpty ? 0 : 8)
                            rows(idle, nameWidth: nameWidth)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.automatic)
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(PanelStyle.listAnimation, value: playing.map(\.id))
        .animation(PanelStyle.listAnimation, value: idle.map(\.id))
        .animation(PanelStyle.listAnimation, value: recording.map(\.id))
        .animation(PanelStyle.listAnimation, value: model.browsers.tabs.map(\.id))
    }

    /// Room for the microphone and output badges next to a name.
    private func badgeWidth(for app: AudioApp) -> CGFloat {
        (app.isUsingMicrophone ? 14 : 0) + (model.routes[app.id] != nil ? 16 : 0)
    }

    /// Each row receives its volume as a value, so moving one slider only re-renders that row.
    private func rows(_ apps: [AudioApp], nameWidth: CGFloat) -> some View {
        ForEach(apps) { app in
            AppVolumeRow(app: app, volume: model.volume(for: app.id), nameWidth: nameWidth)
                .transition(.opacity)
            let tabs = model.tabs(for: app.id)
            ForEach(tabs) { tab in
                TabVolumeRow(tab: tab, nameWidth: nameWidth, isLast: tab.id == tabs.last?.id)
                    .transition(.opacity)
            }
            if tabs.isEmpty, model.suggestsTabControl(for: app) {
                TabControlSuggestion()
                    .transition(.opacity)
            }
        }
    }
}

private struct SectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, PanelStyle.rowInset)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct EmptyAppList: View {
    let showsIdleApps: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "speaker.zzz")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(showsIdleApps ? "No apps are using audio" : "Nothing is playing")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            if !showsIdleApps {
                Text("Apps appear here when they play audio.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}
