// BoseMicToggle -- кнопка play/pause на Bluetooth-гарнитуре мьютит микрофон в Zoom.
//
// Почему всё устроено именно так (проверено экспериментально 2026-09-28):
//
//  * Во время звонка гарнитура уходит в профиль HFP (16 кГц моно). В HFP
//    многофункциональная кнопка -- это управление вызовом, а не AVRCP
//    play/pause: наушники присылают AT-команду `AT+CHUP` по RFCOMM.
//  * Эту команду принимает системный bluetoothd и приложениям не отдаёт:
//    в поток CGEvent она не попадает (hs.eventtap/Karabiner её не видят),
//    MediaRemote её тоже не получает, и HID-устройства для Bluetooth-гарнитуры
//    macOS не создаёт (найденные Consumer-Control "Headset" принадлежат
//    встроенному кодеку, то есть разъёму 3.5 мм).
//  * Единственный публичный способ увидеть нажатие -- unified log: bluetoothd
//    пишет "Received call hangup event (AT+CHUP) from device <адрес>" и не
//    редактирует адрес. Отсюда чтение `log stream` с узким предикатом.
//
// Это скрейпинг лога, то есть Apple может переименовать сообщение в любом
// обновлении macOS, и тогда триггер молча перестанет работать. Пункт меню
// "Проверить сигнал кнопки" существует ровно для того, чтобы это быстро
// диагностировать.

import AVFoundation
import AppKit
import ApplicationServices
import Foundation

// MARK: - Настройки

let zoomBundleID = "us.zoom.xos"
let meetingPollInterval: TimeInterval = 4.0

/// Одно нажатие попадает в лог 2-3 раза (разные потоки bluetoothd) с разницей
/// в десятки миллисекунд, поэтому дубли гасим.
let debounceInterval: TimeInterval = 0.5

/// Подстрока, по которой узнаём нажатие кнопки гарнитуры.
let buttonMarker = "AT+CHUP"

/// Пункты меню Zoom для микрофона (ключи в нижнем регистре: Zoom пишет
/// "Unmute audio" со строчной "a", и капитализация менялась между версиями).
/// Значение true означает «микрофон сейчас выключен» -- пункт предлагает включить.
let micMenuTitles: [String: Bool] = [
    "mute audio": false,
    "unmute audio": true,
    "выключить звук": false,
    "включить звук": true,
]

// MARK: - Лог

// Запущенный через LaunchServices агент не имеет видимого stderr, поэтому
// пишем в файл.
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

// MARK: - Accessibility: чтение и нажатие меню Zoom

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

/// Ищет в меню-баре Zoom пункт mute/unmute. Меню при этом не открывается.
/// nil означает, что митинга нет: вне митинга Zoom такого пункта не показывает.
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
    /// Митинга нет -- переключать нечего, это не ошибка.
    case noMeeting
    /// Митинг есть, но нажать пункт меню не удалось.
    case failed
}

func toggleZoomMic() -> MicToggle {
    guard let (item, muted) = findZoomMicMenuItem() else {
        log("митинга нет -- переключать нечего")
        return .noMeeting
    }
    guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
        log("не удалось нажать пункт меню")
        return .failed
    }
    return .toggled(muted: !muted)
}

/// Выгружает меню Zoom в лог. Нужно, если Zoom переименует пункты и
/// micMenuTitles перестанет совпадать.
func dumpZoomMenu() {
    guard let menuBar = zoomMenuBar() else {
        log("дамп меню: Zoom не запущен или нет прав Accessibility")
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
    log("дамп меню Zoom:\n" + lines.joined(separator: "\n"))
}

// MARK: - Развёрнутые системные звуки

/// Префикс в имени звука: "reversed:Bottle" -- взять системный Bottle и
/// проиграть задом наперёд. Нужно, чтобы включение и выключение звучали одним
/// тембром и отличались только направлением: у системных звуков нарастающей
/// пары к спадающей просто нет.
let reversedPrefix = "reversed:"

private let soundCacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/BoseMicToggle")

/// Разворачивает системный звук и кладёт результат в кэш. Возвращает файл.
func reversedSystemSound(_ name: String) -> URL? {
    let cached = soundCacheDir.appendingPathComponent("\(name)-reversed.wav")
    if FileManager.default.fileExists(atPath: cached.path) { return cached }

    let source = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
    guard let input = try? AVAudioFile(forReading: source) else {
        log("разворот: не открылся \(source.lastPathComponent)")
        return nil
    }

    let format = input.processingFormat
    let frameCount = AVAudioFrameCount(input.length)
    guard frameCount > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
          (try? input.read(into: buffer)) != nil,
          let channels = buffer.floatChannelData
    else {
        log("разворот: не прочитался \(name)")
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

    // У системных звуков заметный тихий хвост; после разворота он оказывается
    // в начале и даёт задержку перед звуком, поэтому срезаем.
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
        log("разворот: не записался кэш -- \(error.localizedDescription)")
        return nil
    }

    let seconds = Double(keep) / format.sampleRate
    log("развернул \(name): срезано \(start) кадров, длина \(String(format: "%.2f", seconds))с")
    return cached
}

// MARK: - Звуковое подтверждение

/// Системные звуки вместо своих файлов: ничего не нужно тащить с собой, и они
/// уже подогнаны по громкости под остальную систему. Имена -- содержимое
/// /System/Library/Sounds, плюс префикс "reversed:" для разворота.
/// Меняются без пересборки, например:
///   defaults write io.github.bosemictoggle soundUnmuted Ping
///   defaults write io.github.bosemictoggle soundMuted reversed:Purr
///   defaults write io.github.bosemictoggle soundVolume -float 0.5
final class Sounds {
    private var cache: [String: NSSound] = [:]

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            // Одна пара одного тембра: вверх на включение, вниз на выключение.
            "soundUnmuted": reversedPrefix + "Bottle",
            "soundMuted": "Bottle",
            "soundFailed": "Basso",     // привычный системный звук ошибки
            "soundVolume": 0.35,
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

    /// Проиграть все три по очереди -- проверка без дёргания микрофона.
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
            log("звук \"\(name)\" не найден")
            return
        }
        cache[name] = sound

        sound.volume = Float(defaults.double(forKey: "soundVolume"))

        // Быстрые повторные нажатия иначе проглатываются.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    private func load(_ name: String) -> NSSound? {
        guard name.hasPrefix(reversedPrefix) else { return NSSound(named: name) }

        let base = String(name.dropFirst(reversedPrefix.count))
        guard let file = reversedSystemSound(base) else {
            // Разворот не получился -- лучше обычный звук, чем тишина.
            return NSSound(named: base)
        }
        return NSSound(contentsOf: file, byReference: false)
    }
}

// MARK: - Чтение нажатий кнопки из unified log

/// Запускает `log stream` с узким предикатом и дёргает onButton на каждую
/// AT-команду от гарнитуры. Стрим стоит около 7% CPU, поэтому живёт только
/// пока идёт митинг.
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

        // Если `log` умрёт (например, после сна), поднимаем заново.
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.process != nil else { return }
                log("стрим лога завершился, перезапускаю")
                self.process = nil
                self.start()
            }
        }

        do {
            try task.run()
        } catch {
            log("не удалось запустить log stream: \(error.localizedDescription)")
            return
        }

        process = task
        buffer = ""
        log("слушаю кнопку гарнитуры")
    }

    func stop() {
        guard let task = process else { return }
        process = nil          // чтобы terminationHandler не перезапустил
        task.terminate()
        log("перестал слушать кнопку")
    }

    private func consume(_ chunk: String) {
        buffer += chunk

        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])

            // `log stream` первой строкой печатает баннер с текстом предиката,
            // а в нём есть и сам маркер. Настоящие записи начинаются с
            // таймстампа, поэтому требуем цифру в начале строки.
            guard let first = line.first, first.isNumber,
                  line.contains(buttonMarker)
            else { continue }

            onButton?(line)
        }
    }
}

// MARK: - Агент

final class Agent {
    private let watcher = ButtonWatcher()
    private let sounds = Sounds()
    private var lastToggle = Date.distantPast

    /// Идёт ли Zoom-митинг -- кешируем для отрисовки меню.
    private(set) var inMeeting = false

    /// Выключен ли микрофон. nil, когда митинга нет и состояния просто не существует.
    private(set) var micMuted: Bool?

    /// Смена состояния -- чтобы меню-бар перерисовался.
    var onStateChange: (() -> Void)?

    private let enabledKey = "enabled"

    /// Выключенный агент не слушает кнопку.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: enabledKey)
            log("enabled = \(enabled)")
            sync()
        }
    }

    /// Проброшено для меню-бара.
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

        log("нажатие кнопки: \(line)")
        toggleMic()
    }

    /// Ctrl+Alt+Cmd+M -- ручной триггер, удобно для проверки без наушников.
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
            log(nowMuted ? "микрофон выключен" : "микрофон включён")
            nowMuted ? sounds.playMuted() : sounds.playUnmuted()

            // Не ждём следующего опроса -- иконка должна меняться сразу.
            micMuted = nowMuted
            onStateChange?()

        case .failed:
            sounds.playFailed()

        case .noMeeting:
            break
        }
    }

    /// Стрим лога дорогой, поэтому держим его только во время митинга.
    private func sync() {
        // Один обход меню даёт и факт митинга, и состояние микрофона.
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

// MARK: - Иконка в меню-баре

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

        // Залитый значок -- идёт митинг и состояние настоящее.
        // Контурный -- митинга нет, показывать нечего.
        switch (agent.enabled, agent.micMuted) {
        case (false, _):
            symbol = "mic.slash"
            hint = "BoseMicToggle: выключен"
        case (true, .some(true)):
            symbol = "mic.slash.fill"
            hint = "Микрофон выключен"
        case (true, .some(false)):
            symbol = "mic.fill"
            hint = "Микрофон включён"
        case (true, .none):
            symbol = "mic"
            hint = "BoseMicToggle: ждёт начала митинга"
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
        case (false, _):            status = "Выключен"
        case (true, .some(true)):   status = "Микрофон выключен"
        case (true, .some(false)):  status = "Микрофон включён"
        case (true, .none):         status = "Ждёт начала митинга"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        add(menu, "Включён", checked: agent.enabled, #selector(toggleEnabled))
        add(menu, "Звуковое подтверждение", checked: agent.soundsEnabled,
            #selector(toggleSounds))

        menu.addItem(.separator())
        add(menu, "Прослушать звуки", checked: nil, #selector(previewSounds))
        add(menu, "Переключить микрофон сейчас", checked: nil, #selector(toggleMicNow))
        add(menu, "Проверить сигнал кнопки", checked: nil, #selector(checkButtonSignal))
        add(menu, "Записать меню Zoom в лог", checked: nil, #selector(dumpMenu))
        add(menu, "Открыть лог", checked: nil, #selector(openLog))
        add(menu, "Выйти", checked: nil, #selector(quit))
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

    /// Показывает, сколько нажатий кнопки система записала за последние 10 минут.
    /// Если тут ноль, а кнопку жали -- Apple переименовала сообщение в логе.
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
            log("проверка сигнала: не удалось запустить log show")
            return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let hits = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { $0.contains(buttonMarker) }

        log("проверка сигнала: нажатий за 10 минут -- \(hits.count)")
        if let last = hits.last { log("последнее: \(last)") }
    }
}

// MARK: - Точка входа

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let agent = Agent()
    private var statusBar: StatusBar?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("агент запущен, bundle=\(Bundle.main.bundleIdentifier ?? "nil")")

        // Без Accessibility агент не прочитает меню Zoom. Просим права один раз.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        log("accessibility trusted = \(AXIsProcessTrustedWithOptions(options as CFDictionary))")

        statusBar = StatusBar(agent: agent)
        agent.start()

        // `defaults write io.github.bosemictoggle dumpMenu -bool true`
        // -- выгрузить меню Zoom при следующем запуске.
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
