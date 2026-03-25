import SwiftUI

@main
struct RuvNoiseApp: App {
    @State private var player = RadioPlayer()
    @State private var scheduler = NewsScheduler()
    @State private var didConfigure = false

    var body: some Scene {
        MenuBarExtra("RUV Noise", systemImage: player.isPlaying ? "radio.fill" : "radio") {
            MenuContent(player: player, scheduler: scheduler, didConfigure: $didConfigure)
        }
    }
}

private struct MenuContent: View {
    let player: RadioPlayer
    let scheduler: NewsScheduler
    @Binding var didConfigure: Bool

    var body: some View {
        ForEach(Station.allCases, id: \.self) { station in
            Toggle(station.rawValue, isOn: Binding(
                get: { player.currentStation == station },
                set: { _ in
                    scheduler.userDidInteract()
                    Task { await player.play(station: station) }
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
        Toggle(isOn: Binding(
            get: { player.kitchenMode },
            set: { _ in player.toggleKitchenMode() }
        )) {
            Label("Kitchen Mode", systemImage: player.kitchenMode ? "frying.pan.fill" : "frying.pan")
        }
        Button(player.isMuted ? "Unmute" : "Mute") {
            player.toggleMute()
        }
        .disabled(!player.isPlaying)
        Divider()
        Button("Quit") {
            player.stop()
            NSApplication.shared.terminate(nil)
        }
        .task {
            guard !didConfigure else { return }
            didConfigure = true
            scheduler.configure(player: player)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}
