import Foundation
import AppKit

struct NewsEvent {
    let title: String
    let startTime: Date
    let endTime: Date
}

@MainActor
@Observable
final class NewsScheduler {
    nonisolated init() {}

    private weak var player: RadioPlayer?

    // MARK: - State

    var isEnabled: Bool = UserDefaults.standard.bool(forKey: "autoNewsEnabled") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "autoNewsEnabled")
            if isEnabled {
                Task { await refreshSchedule() }
            } else {
                cancelAll()
                if autoPlayActive { stopAutoPlay() }
            }
        }
    }

    private(set) var autoPlayActive = false
    private(set) var nextNews: NewsEvent?
    /// Measured HLS live latency (broadcast to listener) in seconds.
    private(set) var hlsLatency: TimeInterval = 24

    private var newsEvents: [NewsEvent] = []
    private var scheduledTasks: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?
    private var isScreenAsleep = false

    // MARK: - Setup

    func configure(player: RadioPlayer) {
        self.player = player
        observeSystem()
        Task {
            await measureHLSLatency()
            if isEnabled { await refreshSchedule() }
        }
    }

    /// Call when user manually interacts with playback.
    func userDidInteract() {
        autoPlayActive = false
    }

    // MARK: - System Observation

    private func observeSystem() {
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            let s = self
            Task { @MainActor in s?.isScreenAsleep = true }
        }
        wsnc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            let s = self
            Task { @MainActor in
                s?.isScreenAsleep = false
                if s?.isEnabled == true { await s?.refreshSchedule() }
            }
        }
    }

    private nonisolated func isDNDActive() -> Bool {
        UserDefaults(suiteName: "com.apple.controlcenter")?
            .bool(forKey: "NSDoNotDisturbEnabled") ?? false
    }

    // MARK: - HLS Latency Measurement

    /// Measures actual HLS live latency by parsing segment timestamps from the playlist.
    /// Segment filenames encode their recording time (e.g. ras120260325T120659_6017247.aac),
    /// so we compare the newest segment's timestamp to wall clock time, then add the player's
    /// buffer depth (3 x target duration) to get the total broadcast-to-ear delay.
    func measureHLSLatency() async {
        do {
            let masterURL = Station.ras1.url
            let (masterData, _) = try await URLSession.shared.data(from: masterURL)
            guard let master = String(data: masterData, encoding: .utf8) else { return }

            // Resolve variant playlist URL
            var variantPath: String?
            for line in master.split(separator: "\n")
            where !line.hasPrefix("#") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                variantPath = line.trimmingCharacters(in: .whitespaces)
                break
            }
            guard let path = variantPath else { return }
            let variantURL = path.hasPrefix("http")
                ? URL(string: path)!
                : masterURL.deletingLastPathComponent().appendingPathComponent(path)

            let (varData, _) = try await URLSession.shared.data(from: variantURL)
            guard let playlist = String(data: varData, encoding: .utf8) else { return }

            var targetDuration: Double = 6
            var newestSegment: String?

            for line in playlist.split(separator: "\n") {
                let l = String(line)
                if l.hasPrefix("#EXT-X-TARGETDURATION:") {
                    targetDuration = Double(
                        l.replacingOccurrences(of: "#EXT-X-TARGETDURATION:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                    ) ?? 6
                }
                if l.hasSuffix(".aac") || l.hasSuffix(".ts") {
                    newestSegment = l
                }
            }

            // Parse timestamp from filename: ras1YYYYMMDDTHHMMSS_SEQ.aac
            if let filename = newestSegment,
               let range = filename.range(of: #"\d{8}T\d{6}"#, options: .regularExpression)
            {
                let df = DateFormatter()
                df.dateFormat = "yyyyMMdd'T'HHmmss"
                df.timeZone = TimeZone(identifier: "Atlantic/Reykjavik")
                if let segmentTime = df.date(from: String(filename[range])) {
                    let cdnDelay = Date().timeIntervalSince(segmentTime)
                    let playerBuffer = 3 * targetDuration
                    let measured = cdnDelay + playerBuffer
                    if measured > 5 && measured < 120 {
                        hlsLatency = measured
                    }
                }
            }
        } catch {
            // Keep default estimate
        }
    }

    // MARK: - Schedule Fetching

    func refreshSchedule() async {
        cancelAll()

        let tz = TimeZone(identifier: "Atlantic/Reykjavik")!
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = tz

        let today = df.string(from: Date())
        let tomorrow = df.string(from: Date().addingTimeInterval(86400))

        async let t = fetchEvents(date: today)
        async let tm = fetchEvents(date: tomorrow)

        let todayEvents = (try? await t) ?? []
        let tomorrowEvents = (try? await tm) ?? []
        let all = todayEvents + tomorrowEvents
        newsEvents = all.filter { $0.endTime > Date() }.sorted { $0.startTime < $1.startTime }

        scheduleTimers()
        updateNextNews()
        scheduleRefreshAtMidnight()
    }

    private func fetchEvents(date: String) async throws -> [NewsEvent] {
        let vars = "{\"channel\":\"ras1\",\"date\":\"\(date)\"}"
        let ext = "{\"persistedQuery\":{\"version\":1,\"sha256Hash\":\"16670c47c2a2e68558ce1984fa60f4486542b693d360de3a80620c32a4f5791d\"}}"

        var comps = URLComponents(string: "https://spilari.nyr.ruv.is/gql/")!
        comps.queryItems = [
            URLQueryItem(name: "operationName", value: "getSchedule"),
            URLQueryItem(name: "variables", value: vars),
            URLQueryItem(name: "extensions", value: ext),
        ]

        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("https://www.ruv.is/", forHTTPHeaderField: "referer")
        req.setValue("https://www.ruv.is", forHTTPHeaderField: "origin")

        let (data, _) = try await URLSession.shared.data(for: req)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any],
              let sched = d["Schedule"] as? [String: Any],
              let events = sched["events"] as? [[String: Any]] else { return [] }

        let tz = TimeZone(identifier: "Atlantic/Reykjavik")!
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm"
        timeFmt.timeZone = tz

        return events.compactMap { ev -> NewsEvent? in
            guard let slug = ev["slug"] as? String, slug.contains("frett"),
                  let title = ev["title"] as? String,
                  let start = ev["start_time_friendly"] as? String,
                  let end = ev["end_time_friendly"] as? String,
                  let startDate = timeFmt.date(from: "\(date) \(start)"),
                  var endDate = timeFmt.date(from: "\(date) \(end)") else { return nil }

            if endDate <= startDate { endDate.addTimeInterval(86400) }
            return NewsEvent(title: title, startTime: startDate, endTime: endDate)
        }
    }

    // MARK: - Timer Management

    private func scheduleTimers() {
        let now = Date()
        // Start streaming 10s before news so the player is buffered and playing
        // by the time the news audio reaches the listener through the HLS delay.
        let connectBuffer: TimeInterval = 10
        // Keep playing until the news end has propagated through the HLS delay,
        // plus a small margin for timing variance.
        let stopMargin: TimeInterval = 5

        for event in newsEvents {
            let connectAt = event.startTime.addingTimeInterval(-connectBuffer)
            let stopAt = event.endTime.addingTimeInterval(hlsLatency + stopMargin)
            guard stopAt > now else { continue }

            // Only schedule future news — never start mid-broadcast
            if connectAt > now {
                let delay = connectAt.timeIntervalSince(now)
                let task = Task {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    await self.startAutoPlay(for: event)
                }
                scheduledTasks.append(task)
            }

            let stopDelay = stopAt.timeIntervalSince(now)
            if stopDelay > 0 {
                let task = Task {
                    try? await Task.sleep(for: .seconds(stopDelay))
                    guard !Task.isCancelled else { return }
                    self.stopAutoPlay()
                }
                scheduledTasks.append(task)
            }
        }
    }

    private func startAutoPlay(for event: NewsEvent) async {
        // Only trigger if we're still before the news starts (within the
        // pre-connect window). If we missed the start — e.g. computer was
        // asleep — don't start mid-broadcast.
        guard Date() < event.startTime else { return }

        guard isEnabled, !isScreenAsleep, !isDNDActive(),
              player?.currentStation == nil else { return }

        // Re-measure latency right before connecting for maximum precision.
        // This accounts for CDN routing changes and network conditions.
        await measureHLSLatency()

        autoPlayActive = true
        await player?.play(station: .ras1)
        updateNextNews()
    }

    private func stopAutoPlay() {
        guard autoPlayActive else { return }
        autoPlayActive = false
        if player?.currentStation == .ras1 {
            player?.stop()
        }
        updateNextNews()
    }

    private func cancelAll() {
        scheduledTasks.forEach { $0.cancel() }
        scheduledTasks.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func updateNextNews() {
        nextNews = newsEvents.first { $0.startTime > Date() }
    }

    private func scheduleRefreshAtMidnight() {
        refreshTask?.cancel()
        refreshTask = Task {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Atlantic/Reykjavik")!
            guard let nextMidnight = cal.nextDate(
                after: Date(),
                matching: DateComponents(hour: 0, minute: 1),
                matchingPolicy: .nextTime
            ) else { return }

            let delay = nextMidnight.timeIntervalSinceNow
            guard delay > 0 else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await measureHLSLatency()
            await refreshSchedule()
        }
    }
}
