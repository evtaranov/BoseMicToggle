// BoseMicToggle -- the play/pause button on a Bluetooth headset mutes Zoom.
//
// Why it is built this way (verified experimentally on 2026-09-28):
//
//  * During a call the headset switches to the HFP profile (16 kHz mono).
//    In HFP the multifunction button is call control, not AVRCP play/pause:
//    the headset sends the AT command `AT+CHUP` over RFCOMM.
//  * The system bluetoothd receives that command and never forwards it to
//    applications: it does not reach the CGEvent stream (hs.eventtap and
//    Karabiner cannot see it), MediaRemote does not get it either, and macOS
//    creates no HID device for a Bluetooth headset (the Consumer-Control
//    "Headset" devices that do exist belong to the built-in codec, i.e. the
//    3.5 mm jack).
//  * The only public way to observe the press is the unified log: bluetoothd
//    logs "Received call hangup event (AT+CHUP) from device <address>" and
//    does not redact the address. Hence reading `log stream` with a narrow
//    predicate.
//
// This is log scraping: Apple may reword that message in any macOS update and
// the trigger would silently stop working. The "Check button signal" menu item
// exists precisely to diagnose that quickly.

import AVFoundation
import AppKit
import ApplicationServices
import Foundation

// MARK: - Configuration

let zoomBundleID = "us.zoom.xos"
let meetingPollInterval: TimeInterval = 4.0

/// A single press lands in the log 2-3 times (different bluetoothd threads)
/// tens of milliseconds apart, so duplicates are suppressed.
let debounceInterval: TimeInterval = 0.5

/// The substring that identifies a headset button press.
let buttonMarker = "AT+CHUP"

/// Zoom's microphone menu items, keyed lowercase: Zoom writes "Unmute audio"
/// with a lowercase "a", and the capitalization has changed between versions.
/// A value of true means the microphone is currently muted -- the item offers
/// to unmute. Localized Zoom titles are listed alongside the English ones.
let micMenuTitles: [String: Bool] = [
    "mute audio": false,
    "unmute audio": true,
    "выключить звук": false,
    "включить звук": true,
]

// MARK: - Logging

// An agent launched through LaunchServices has no visible stderr, so we write
// to a file.
let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/BoseMicToggle.log")

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

// MARK: - Accessibility: reading and pressing Zoom's menu

func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    axCopy(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

func axTitle(_ element: AXUIElement) -> String? {
    axCopy(element, kAXTitleAttribute as String) as? String
}

func zoomMenuBar() -> AXUIElement? {
    guard let zoom = NSRunningApplication
        .runningApplications(withBundleIdentifier: zoomBundleID).first
    else { return nil }

    let axApp = AXUIElementCreateApplication(zoom.processIdentifier)
    guard let menuBar = axCopy(axApp, kAXMenuBarAttribute as String) else { return nil }
    return (menuBar as! AXUIElement)
}

/// Finds the mute/unmute item in Zoom's menu bar without opening any menu.
/// nil means there is no meeting: outside a meeting Zoom does not show it.
func findZoomMicMenuItem() -> (item: AXUIElement, muted: Bool)? {
    guard let menuBar = zoomMenuBar() else { return nil }

    // menuBar -> AXMenuBarItem ("Meeting", "View", ...) -> AXMenu -> AXMenuItem
    for barItem in axChildren(menuBar) {
        for menu in axChildren(barItem) {
            for entry in axChildren(menu) {
                guard let title = axTitle(entry)?.lowercased(),
                      let muted = micMenuTitles[title]
                else { continue }
                return (entry, muted)
            }
        }
    }
    return nil
}

enum MicToggle {
    case toggled(muted: Bool)
    /// No meeting -- nothing to toggle, which is not an error.
    case noMeeting
    /// A meeting is running but pressing the menu item failed.
    case failed
}

func toggleZoomMic() -> MicToggle {
    guard let (item, muted) = findZoomMicMenuItem() else {
        log("no meeting -- nothing to toggle")
        return .noMeeting
    }
    guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
        log("failed to press the menu item")
        return .failed
    }
    return .toggled(muted: !muted)
}

/// Dumps Zoom's menu to the log. Needed when Zoom renames its items and
/// micMenuTitles stops matching.
func dumpZoomMenu() {
    guard let menuBar = zoomMenuBar() else {
        log("menu dump: Zoom is not running, or Accessibility is not granted")
        return
    }

    var lines: [String] = []
    for barItem in axChildren(menuBar) {
        let top = axTitle(barItem) ?? "?"
        var entries: [String] = []
        for menu in axChildren(barItem) {
            for entry in axChildren(menu) {
                if let title = axTitle(entry), !title.isEmpty { entries.append(title) }
            }
        }
        lines.append("  \(top): \(entries.joined(separator: " | "))")
    }
    log("Zoom menu dump:\n" + lines.joined(separator: "\n"))
}

// MARK: - Reversed system sounds

/// A prefix in a sound name: "reversed:Bottle" means take the system Bottle
/// sound and play it backwards. This is how mute and unmute end up sharing one
/// timbre and differing only in direction -- the system sounds offer no
/// rising counterpart to a falling one.
let reversedPrefix = "reversed:"

private let soundCacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/BoseMicToggle")

/// Reverses a system sound and caches the result. Returns the cached file.
func reversedSystemSound(_ name: String) -> URL? {
    let cached = soundCacheDir.appendingPathComponent("\(name)-reversed.wav")
    if FileManager.default.fileExists(atPath: cached.path) { return cached }

    let source = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
    guard let input = try? AVAudioFile(forReading: source) else {
        log("reverse: could not open \(source.lastPathComponent)")
        return nil
    }

    let format = input.processingFormat
    let frameCount = AVAudioFrameCount(input.length)
    guard frameCount > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
          (try? input.read(into: buffer)) != nil,
          let channels = buffer.floatChannelData
    else {
        log("reverse: could not read \(name)")
        return nil
    }

    let frames = Int(buffer.frameLength)
    let channelCount = Int(format.channelCount)

    for channel in 0..<channelCount {
        let samples = channels[channel]
        for i in 0..<(frames / 2) {
            let mirrored = frames - 1 - i
            let tmp = samples[i]
            samples[i] = samples[mirrored]
            samples[mirrored] = tmp
        }
    }

    // System sounds have a noticeable quiet tail; after reversing it lands at
    // the front and delays the onset, so trim it.
    var start = 0
    let threshold: Float = 0.01
    outer: for i in 0..<frames {
        for channel in 0..<channelCount where abs(channels[channel][i]) > threshold {
            start = i
            break outer
        }
    }

    let keep = frames - start
    guard keep > 0,
          let trimmed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(keep)),
          let target = trimmed.floatChannelData
    else { return nil }

    for channel in 0..<channelCount {
        target[channel].update(from: channels[channel] + start, count: keep)
    }
    trimmed.frameLength = AVAudioFrameCount(keep)

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    do {
        try FileManager.default.createDirectory(at: soundCacheDir, withIntermediateDirectories: true)
        let output = try AVAudioFile(forWriting: cached, settings: settings)
        try output.write(from: trimmed)
    } catch {
        log("reverse: could not write cache -- \(error.localizedDescription)")
        return nil
    }

    let seconds = Double(keep) / format.sampleRate
    log("reversed \(name): trimmed \(start) frames, length \(String(format: "%.2f", seconds))s")
    return cached
}

// MARK: - Audio feedback

/// System sounds instead of bundled files: nothing to ship, and they are
/// already balanced against the rest of the system. Names are the contents of
/// /System/Library/Sounds, plus the "reversed:" prefix. Changeable without
/// rebuilding, for example:
///   defaults write io.github.bosemictoggle soundUnmuted Ping
///   defaults write io.github.bosemictoggle soundMuted reversed:Purr
///   defaults write io.github.bosemictoggle soundVolume -float 0.5
final class Sounds {
    private var cache: [String: NSSound] = [:]

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            // One timbre, two directions: rising to unmute, falling to mute.
            "soundUnmuted": reversedPrefix + "Bottle",
            "soundMuted": "Bottle",
            "soundFailed": "Basso",     // the familiar system error sound
            "soundVolume": 0.75,
            "soundsEnabled": true,
        ])
    }

    var enabled: Bool {
        get { defaults.bool(forKey: "soundsEnabled") }
        set { defaults.set(newValue, forKey: "soundsEnabled") }
    }

    func playMuted() { play(defaults.string(forKey: "soundMuted")) }
    func playUnmuted() { play(defaults.string(forKey: "soundUnmuted")) }
    func playFailed() { play(defaults.string(forKey: "soundFailed")) }

    /// Plays all three in turn -- a check that does not touch the microphone.
    func preview() {
        let wasEnabled = enabled
        enabled = true

        playUnmuted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.playMuted() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            self.playFailed()
            self.enabled = wasEnabled
        }
    }

    private func play(_ name: String?) {
        guard enabled, let name else { return }

        guard let sound = cache[name] ?? load(name) else {
            log("sound \"\(name)\" not found")
            return
        }
        cache[name] = sound

        sound.volume = Float(defaults.double(forKey: "soundVolume"))

        // Otherwise rapid repeated presses get swallowed.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    private func load(_ name: String) -> NSSound? {
        guard name.hasPrefix(reversedPrefix) else { return NSSound(named: name) }

        let base = String(name.dropFirst(reversedPrefix.count))
        guard let file = reversedSystemSound(base) else {
            // Reversing failed -- a plain sound beats silence.
            return NSSound(named: base)
        }
        return NSSound(contentsOf: file, byReference: false)
    }
}

// MARK: - Reading button presses from the unified log

/// Runs `log stream` with a narrow predicate and calls onButton for every AT
/// command from the headset. The stream costs roughly 7% CPU, so it only lives
/// while a meeting is running.
final class ButtonWatcher {
    private var process: Process?
    private var buffer = ""

    var onButton: ((String) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
        guard !isRunning else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = [
            "stream",
            "--style", "compact",
            "--debug",
            "--predicate", "process == \"bluetoothd\" AND eventMessage CONTAINS \"\(buttonMarker)\"",
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(chunk) }
        }

        // If `log` dies (after sleep, for instance), bring it back.
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.process != nil else { return }
                log("log stream exited, restarting")
                self.process = nil
                self.start()
            }
        }

        do {
            try task.run()
        } catch {
            log("could not start log stream: \(error.localizedDescription)")
            return
        }

        process = task
        buffer = ""
        log("listening for the headset button")
    }

    func stop() {
        guard let task = process else { return }
        process = nil          // so terminationHandler does not restart it
        task.terminate()
        log("stopped listening for the button")
    }

    private func consume(_ chunk: String) {
        buffer += chunk

        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])

            // `log stream` prints a banner with the predicate text as its first
            // line, and that banner contains the marker itself. Real entries
            // start with a timestamp, so require a leading digit.
            guard let first = line.first, first.isNumber,
                  line.contains(buttonMarker)
            else { continue }

            onButton?(line)
        }
    }
}

// MARK: - Agent

final class Agent {
    private let watcher = ButtonWatcher()
    private let sounds = Sounds()
    private var lastToggle = Date.distantPast

    /// Whether a Zoom meeting is running -- cached for the menu bar.
    private(set) var inMeeting = false

    /// Whether the microphone is muted. nil when there is no meeting and the
    /// state simply does not exist.
    private(set) var micMuted: Bool?

    /// State changed -- redraw the menu bar.
    var onStateChange: (() -> Void)?

    private let enabledKey = "enabled"

    /// A disabled agent does not listen for the button.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: enabledKey)
            log("enabled = \(enabled)")
            sync()
        }
    }

    /// Exposed for the menu bar.
    var soundsEnabled: Bool {
        get { sounds.enabled }
        set { sounds.enabled = newValue }
    }

    func previewSounds() { sounds.preview() }

    init() {
        UserDefaults.standard.register(defaults: [enabledKey: true])
        enabled = UserDefaults.standard.bool(forKey: enabledKey)
    }

    func start() {
        watcher.onButton = { [weak self] line in self?.handleButton(line) }
        installHotkey()

        sync()
        Timer.scheduledTimer(withTimeInterval: meetingPollInterval, repeats: true) { _ in
            self.sync()
        }
    }

    private func handleButton(_ line: String) {
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > debounceInterval else { return }
        lastToggle = now

        log("button press: \(line)")
        toggleMic()
    }

    /// Ctrl+Alt+Cmd+M -- a manual trigger, handy for testing without a headset.
    private func installHotkey() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == [.control, .option, .command],
                  event.charactersIgnoringModifiers?.lowercased() == "m"
            else { return }
            self?.toggleMic()
        }
    }

    func toggleMic() {
        switch toggleZoomMic() {
        case .toggled(let nowMuted):
            log(nowMuted ? "microphone muted" : "microphone unmuted")
            nowMuted ? sounds.playMuted() : sounds.playUnmuted()

            // Do not wait for the next poll -- the icon should change at once.
            micMuted = nowMuted
            onStateChange?()

        case .failed:
            sounds.playFailed()

        case .noMeeting:
            break
        }
    }

    /// The log stream is expensive, so keep it only while a meeting runs.
    private func sync() {
        // One menu walk yields both the meeting state and the mic state.
        if enabled, let found = findZoomMicMenuItem() {
            inMeeting = true
            micMuted = found.muted
        } else {
            inMeeting = false
            micMuted = nil
        }

        if enabled, inMeeting {
            watcher.start()
        } else {
            watcher.stop()
        }

        onStateChange?()
    }
}

// MARK: - Menu bar icon

final class StatusBar: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let agent: Agent

    init(agent: Agent) {
        self.agent = agent
        super.init()

        item.menu = NSMenu()
        agent.onStateChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        let symbol: String
        let hint: String

        // A filled glyph means a meeting is running and the state is real.
        // An outlined one means there is no meeting and nothing to show.
        switch (agent.enabled, agent.micMuted) {
        case (false, _):
            symbol = "mic.slash"
            hint = "BoseMicToggle: disabled"
        case (true, .some(true)):
            symbol = "mic.slash.fill"
            hint = "Microphone muted"
        case (true, .some(false)):
            symbol = "mic.fill"
            hint = "Microphone live"
        case (true, .none):
            symbol = "mic"
            hint = "BoseMicToggle: waiting for a meeting"
        }

        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: hint)
        item.button?.toolTip = hint

        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = item.menu else { return }
        menu.removeAllItems()

        let status: String
        switch (agent.enabled, agent.micMuted) {
        case (false, _):            status = "Disabled"
        case (true, .some(true)):   status = "Microphone muted"
        case (true, .some(false)):  status = "Microphone live"
        case (true, .none):         status = "Waiting for a meeting"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        add(menu, "Enabled", checked: agent.enabled, #selector(toggleEnabled))
        add(menu, "Audio feedback", checked: agent.soundsEnabled, #selector(toggleSounds))

        menu.addItem(.separator())
        add(menu, "Preview sounds", checked: nil, #selector(previewSounds))
        add(menu, "Toggle microphone now", checked: nil, #selector(toggleMicNow))
        add(menu, "Check button signal", checked: nil, #selector(checkButtonSignal))
        add(menu, "Dump Zoom menu to log", checked: nil, #selector(dumpMenu))
        add(menu, "Open log", checked: nil, #selector(openLog))
        add(menu, "Quit", checked: nil, #selector(quit))
    }

    private func add(_ menu: NSMenu, _ title: String, checked: Bool?, _ action: Selector) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        if let checked { entry.state = checked ? .on : .off }
        menu.addItem(entry)
    }

    @objc private func toggleEnabled() { agent.enabled.toggle() }
    @objc private func toggleSounds() { agent.soundsEnabled.toggle(); refresh() }
    @objc private func previewSounds() { agent.previewSounds() }
    @objc private func toggleMicNow() { agent.toggleMic() }
    @objc private func dumpMenu() { dumpZoomMenu() }
    @objc private func openLog() { NSWorkspace.shared.open(logURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Reports how many button presses the system logged in the last 10
    /// minutes. Zero here after pressing the button means Apple reworded the
    /// log message.
    @objc private func checkButtonSignal() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = [
            "show", "--last", "10m", "--debug", "--style", "compact",
            "--predicate", "eventMessage CONTAINS \"\(buttonMarker)\"",
        ]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()

        guard (try? task.run()) != nil else {
            log("signal check: could not run log show")
            return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let hits = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { $0.contains(buttonMarker) }

        log("signal check: \(hits.count) presses in the last 10 minutes")
        if let last = hits.last { log("most recent: \(last)") }
    }
}

// MARK: - Entry point

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let agent = Agent()
    private var statusBar: StatusBar?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("agent started, bundle=\(Bundle.main.bundleIdentifier ?? "nil")")

        // Without Accessibility the agent cannot read Zoom's menu. Ask once.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        log("accessibility trusted = \(AXIsProcessTrustedWithOptions(options as CFDictionary))")

        statusBar = StatusBar(agent: agent)
        agent.start()

        // `defaults write io.github.bosemictoggle dumpMenu -bool true`
        // -- dump Zoom's menu on the next launch.
        if UserDefaults.standard.bool(forKey: "dumpMenu") {
            dumpZoomMenu()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
