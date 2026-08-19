import SwiftUI
import Sparkle

@main
struct RuvNoiseApp: App {
    @State private var player = RadioPlayer()
    @State private var scheduler = NewsScheduler()
    @State private var configured = false

    var body: some Scene {
        MenuBarExtra("RUV Noise", systemImage: player.state.isActive ? "radio.fill" : "radio") {
            MenuContent(player: player, scheduler: scheduler, updater: Updater.shared)
                .task {
                    guard !configured else { return }
                    configured = true
                    scheduler.configure(player: player)
                }
        }
    }
}

/// Thin wrapper around Sparkle's updater controller so the menu can trigger
/// update checks without owning the controller's lifecycle.
final class Updater {
    static let shared = Updater()
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

private struct MenuContent: View {
    let player: RadioPlayer
    let scheduler: NewsScheduler
    let updater: Updater

    var body: some View {
        Section("RÚV") {
            ForEach(Station.ruvStations, id: \.self) { station in
                StationRow(station: station, player: player, scheduler: scheduler)
            }
        }
        Section("Aðrar stöðvar") {
            ForEach(Station.liveStations, id: \.self) { station in
                StationRow(station: station, player: player, scheduler: scheduler)
            }
        }
        Divider()
        Toggle("Spila fréttir sjálfkrafa", isOn: Binding(
            get: { scheduler.isEnabled },
            set: { scheduler.isEnabled = $0 }
        ))
        if scheduler.isEnabled, let next = scheduler.nextNews {
            Text("\(next.title) kl. \(formatTime(next.startTime))")
                .foregroundStyle(.secondary)
        }
        Divider()
        ForEach(AudioMode.allCases, id: \.self) { mode in
            Toggle(isOn: Binding(
                get: { player.audioMode == mode },
                set: { _ in player.setAudioMode(mode) }
            )) {
                Label(mode.rawValue, systemImage: mode.systemImage)
            }
        }
        Divider()
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        Divider()
        Button("Quit") {
            player.stop()
            NSApplication.shared.terminate(nil)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}

/// A station toggle with its now-playing line attached underneath when active:
/// the scheduled show (RÚV) or the ICY song title (live stations).
private struct StationRow: View {
    let station: Station
    let player: RadioPlayer
    let scheduler: NewsScheduler

    var body: some View {
        Toggle(station.rawValue, isOn: Binding(
            get: { player.state.isStation(station) },
            set: { _ in
                scheduler.userDidInteract()
                Task { await player.selectStation(station) }
            }
        ))
        if player.state.isStation(station) {
            nowPlayingLine()
        }
    }

    // Explicit @MainActor: Xcode 15 (macos-14 CI) infers isolation for View.body
    // but not for sibling methods — reading RadioPlayer's @MainActor state from a
    // non-isolated helper fails to compile there.
    @MainActor
    @ViewBuilder
    private func nowPlayingLine() -> some View {
        if let show = player.nowPlayingShow {
            Text("\(show.title) • \(formatTime(show.startTime))")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else if let title = player.nowPlayingLiveTitle {
            Text(title)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}
