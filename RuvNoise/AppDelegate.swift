import SwiftUI

@main
struct RuvNoiseApp: App {
    @State private var player = RadioPlayer()
    @State private var scheduler = NewsScheduler()
    @State private var configured = false

    var body: some Scene {
        MenuBarExtra("RUV Noise", systemImage: menuBarIcon) {
            MenuContent(player: player, scheduler: scheduler)
                .task {
                    guard !configured else { return }
                    configured = true
                    scheduler.configure(player: player)
                }
        }
    }

    private var menuBarIcon: String {
        switch player.state {
        case .idle: "radio"
        case .loading: "antenna.radiowaves.left.and.right"
        case .playing: "radio.fill"
        }
    }
}

private struct MenuContent: View {
    let player: RadioPlayer
    let scheduler: NewsScheduler

    var body: some View {
        ForEach(Station.allCases, id: \.self) { station in
            Toggle(station.rawValue, isOn: Binding(
                get: { player.state.isStation(station) },
                set: { _ in
                    scheduler.userDidInteract()
                    Task { await player.selectStation(station) }
                }
            ))
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
