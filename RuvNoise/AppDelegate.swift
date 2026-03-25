import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let radioPlayer = RadioPlayer()

    // Menu items we need to update
    private var ras1Item: NSMenuItem!
    private var ras2Item: NSMenuItem!
    private var muteItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock (belt-and-suspenders with Info.plist LSUIElement)
        NSApp.setActivationPolicy(.accessory)

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()

        // Build menu
        let menu = NSMenu()

        ras1Item = NSMenuItem(title: Station.ras1.rawValue, action: #selector(playRas1), keyEquivalent: "1")
        ras1Item.target = self
        menu.addItem(ras1Item)

        ras2Item = NSMenuItem(title: Station.ras2.rawValue, action: #selector(playRas2), keyEquivalent: "2")
        ras2Item.target = self
        menu.addItem(ras2Item)

        menu.addItem(.separator())

        muteItem = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "m")
        muteItem.target = self
        menu.addItem(muteItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Listen for state changes
        radioPlayer.onStateChange = { [weak self] in
            self?.updateMenu()
            self?.updateIcon()
        }
    }

    // MARK: - Actions

    @objc private func playRas1() {
        radioPlayer.play(station: .ras1)
    }

    @objc private func playRas2() {
        radioPlayer.play(station: .ras2)
    }

    @objc private func toggleMute() {
        radioPlayer.toggleMute()
        updateMenu()
    }

    @objc private func quit() {
        radioPlayer.stop()
        NSApp.terminate(nil)
    }

    // MARK: - UI Updates

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbolName = radioPlayer.isPlaying ? "radio.fill" : "radio"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "RÚV Noise")
        image?.isTemplate = true
        button.image = image
    }

    private func updateMenu() {
        ras1Item.state = radioPlayer.currentStation == .ras1 ? .on : .off
        ras2Item.state = radioPlayer.currentStation == .ras2 ? .on : .off
        muteItem.state = radioPlayer.isMuted ? .on : .off
        muteItem.isEnabled = radioPlayer.isPlaying
    }
}
