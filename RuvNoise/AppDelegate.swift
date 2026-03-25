import SwiftUI

@main
struct RuvNoiseApp: App {
    @State private var player = RadioPlayer()

    var body: some Scene {
        MenuBarExtra("RÚV Noise", systemImage: player.isPlaying ? "radio.fill" : "radio") {
            ForEach(Station.allCases, id: \.self) { station in
                Toggle(station.rawValue, isOn: Binding(
                    get: { player.currentStation == station },
                    set: { _ in Task { await player.play(station: station) } }
                ))
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
        }
    }
}
