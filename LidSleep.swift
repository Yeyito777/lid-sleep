import AppKit
import CoreWLAN

func lidIcon(disabled: Bool?, busy: Bool = false) -> NSImage {
    // Vector template artwork stays crisp at Retina resolution and follows
    // macOS menu-bar tint, including dark mode and the highlighted menu.
    let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
        NSColor.black.set()
        let screen = NSBezierPath(roundedRect: NSRect(x: 3, y: 5.3, width: 16, height: 11),
                                  xRadius: 1.6, yRadius: 1.6)
        screen.lineWidth = 1.35
        screen.stroke()

        let base = NSBezierPath()
        base.move(to: NSPoint(x: 1.1, y: 4.6))
        base.line(to: NSPoint(x: 20.9, y: 4.6))
        base.curve(to: NSPoint(x: 18.8, y: 2.6),
                   controlPoint1: NSPoint(x: 20.7, y: 3.3),
                   controlPoint2: NSPoint(x: 19.9, y: 2.6))
        base.line(to: NSPoint(x: 3.2, y: 2.6))
        base.curve(to: NSPoint(x: 1.1, y: 4.6),
                   controlPoint1: NSPoint(x: 2.1, y: 2.6),
                   controlPoint2: NSPoint(x: 1.3, y: 3.3))
        base.close()
        base.lineWidth = 1.25
        base.lineJoinStyle = .round
        base.stroke()

        if busy {
            for x in [7.8, 11.0, 14.2] {
                NSBezierPath(ovalIn: NSRect(x: x - 0.7, y: 10.1, width: 1.4, height: 1.4)).fill()
            }
        } else if disabled == true {
            let center = NSPoint(x: 11, y: 10.8)
            NSBezierPath(ovalIn: NSRect(x: 9.4, y: 9.2, width: 3.2, height: 3.2)).fill()
            let rays = NSBezierPath()
            rays.lineWidth = 1.05
            rays.lineCapStyle = .round
            for index in 0..<8 {
                let angle = CGFloat(index) * .pi / 4
                rays.move(to: NSPoint(x: center.x + cos(angle) * 2.55,
                                     y: center.y + sin(angle) * 2.55))
                rays.line(to: NSPoint(x: center.x + cos(angle) * 3.35,
                                     y: center.y + sin(angle) * 3.35))
            }
            rays.stroke()
        } else if disabled == false {
            let halfAngle = acos(hypot(CGFloat(1.8), CGFloat(1.8)) / 6.4) * 180 / .pi
            let moon = NSBezierPath()
            moon.appendArc(withCenter: NSPoint(x: 11, y: 10.8), radius: 3.2,
                           startAngle: 45 + halfAngle, endAngle: 45 - halfAngle, clockwise: false)
            moon.appendArc(withCenter: NSPoint(x: 12.8, y: 12.6), radius: 3.2,
                           startAngle: 225 + halfAngle, endAngle: 225 - halfAngle, clockwise: true)
            moon.close()
            moon.fill()
        } else {
            let question = NSAttributedString(string: "?", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.black
            ])
            question.draw(at: NSPoint(x: (22 - question.size().width) / 2, y: 6.4))
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = busy ? "Lid: changing setting" :
        (disabled.map { $0 ? "Lid: Awake" : "Lid: Sleep" } ?? "Lid: unknown setting")
    return image
}

func sleepDisabled(in text: String) throws -> Bool {
    for line in text.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        if fields.first == "SleepDisabled" {
            guard fields.count == 2, fields[1] == "0" || fields[1] == "1" else {
                throw NSError(domain: "LidSleep", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Unrecognized SleepDisabled value."])
            }
            return fields[1] == "1"
        }
    }
    guard text.contains("System-wide power settings:"),
          text.contains("Currently in use:") else {
        throw NSError(domain: "LidSleep", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Could not read macOS power settings."])
    }
    // The key is absent on a default macOS configuration.
    return false
}

func readState() throws -> Bool {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "LidSleep", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "pmset could not read power settings."])
    }
    return try sleepDisabled(in: String(decoding: data, as: UTF8.self))
}

func changeArguments(disabled: Bool) -> [String] {
    // Never use a cached password or fall back to an interactive password prompt.
    return ["-n", "-k", "-u", "root", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
}

func appleScriptString(_ text: String) -> String {
    return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func setupScript(uid: uid_t = getuid()) -> String {
    // The rule contains exactly two commands, no wildcards or shell access.
    // A hidden staging file is ignored by sudo's includedir until validated.
    let shell = """
    set -eu
    umask 077
    [ "$(/usr/bin/id -u)" = 0 ]
    /usr/bin/grep -Eq '^[[:space:]]*(#|@)includedir[[:space:]]+(/private)?/etc/sudoers[.]d([[:space:]]|$)' /private/etc/sudoers || {
        echo 'The standard sudoers.d include is missing; no changes made.' >&2
        exit 1
    }
    /usr/sbin/visudo -cq
    target='/private/etc/sudoers.d/lidsleep-\(uid)'
    [ ! -L "$target" ] || { echo 'Refusing a symlink at the rule path.' >&2; exit 1; }
    temp=$(/usr/bin/mktemp '/private/etc/sudoers.d/.lidsleep-\(uid).XXXXXX')
    installed=0
    trap '/bin/rm -f "$temp"; if [ "$installed" = 1 ]; then /bin/rm -f "$target"; fi' EXIT
    /usr/bin/printf '%s\\n' '# Lid Sleep: only the two exact sleep toggle commands.' '#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1' > "$temp"
    /usr/sbin/chown root:wheel "$temp"
    /bin/chmod 0440 "$temp"
    /usr/sbin/visudo -cqf "$temp"
    if [ -e "$target" ]; then
        /usr/bin/cmp -s "$temp" "$target" || {
            echo 'A different rule already exists at this path; no changes made.' >&2
            exit 1
        }
    else
        /bin/mv "$temp" "$target"
        installed=1
        /usr/sbin/visudo -cq
        installed=0
    fi
    """
    return "do shell script \(appleScriptString(shell)) with prompt " +
        appleScriptString("One-time Lid Sleep setup: allow only the two sleep toggle commands without future password prompts.") +
        " with administrator privileges"
}

func runCommand(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "LidSleep", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "Command failed." : errorText])
    }
}

enum WiFiState: Equatable {
    case missing
    case off
    case connected
    case otherNetwork
    case offline
}

func isUsableIPv4(_ address: UInt32) -> Bool {
    // A self-assigned 169.254/16 address means DHCP failed; 0/8 and 127/8 never route.
    let first = address >> 24
    return first != 0 && first != 127 && address >> 16 != 0xA9FE
}

func classifyWiFi(interface: String?, powerOn: Bool, addressed: Set<String>) -> WiFiState {
    guard let interface = interface else { return .missing }
    // Wi-Fi the user turned off is never turned back on.
    guard powerOn else { return .off }
    if addressed.contains(interface) { return .connected }
    // Ethernet adapters and USB tethering are also en* interfaces; VPN tunnels are not.
    if addressed.contains(where: { $0.hasPrefix("en") }) { return .otherNetwork }
    return .offline
}

func addressedInterfaces() -> Set<String> {
    var names = Set<String>()
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return names }
    defer { freeifaddrs(list) }
    var cursor = list
    while let entry = cursor?.pointee {
        cursor = entry.ifa_next
        guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
              entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
        let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
        if isUsableIPv4(ipv4) { names.insert(String(cString: entry.ifa_name)) }
    }
    return names
}

func currentWiFiState() -> (WiFiState, String?) {
    let wifi = CWWiFiClient.shared().interface()
    let name = wifi?.interfaceName
    return (classifyWiFi(interface: name, powerOn: wifi?.powerOn() ?? false, addressed: addressedInterfaces()), name)
}

func wifiRetryDelay(restarts: Int) -> TimeInterval {
    // Give macOS auto-join a chance first, then back off to every five minutes.
    return [20, 60, 120, 300][min(restarts, 3)]
}

func setWiFiPower(_ name: String, on: Bool) -> Bool {
    guard let wifi = CWWiFiClient.shared().interface(withName: name) else { return false }
    do { try wifi.setPower(on) } catch { return false }
    return wifi.powerOn() == on
}

func durationText(_ interval: TimeInterval) -> String {
    let seconds = Int(interval)
    return seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60)m" : "\(seconds / 3600)h \(seconds % 3600 / 60)m"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var yesItem: NSMenuItem!
    private var noItem: NSMenuItem!
    private var setupItem: NSMenuItem!
    private var wifiItem: NSMenuItem!
    private var wifiStatusItem: NSMenuItem!
    private var state: Bool?
    private var busy = false
    private var timer: Timer?
    private var wifiTimer: Timer?
    private var authorizationProcess: Process?
    private var wifiState = WiFiState.missing
    private var wifiOfflineSince: Date?
    private var wifiLastRestart: Date?
    private var wifiRestarts = 0
    private var wifiRestarting = false
    private var wifiPowerPending = false
    private var reconnectWiFi: Bool { UserDefaults.standard.bool(forKey: "reconnectWiFi") }
    private let awakeIcon = lidIcon(disabled: true)
    private let sleepIcon = lidIcon(disabled: false)
    private let unknownIcon = lidIcon(disabled: nil)
    private let busyIcon = lidIcon(disabled: nil, busy: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "local.yeyito.LidSleep")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleNone
        let title = NSMenuItem(title: "Sleep on lid close", action: nil, keyEquivalent: "")
        menu.addItem(title)
        yesItem = NSMenuItem(title: "Yes — allow normal sleep", action: #selector(allowSleep), keyEquivalent: "")
        noItem = NSMenuItem(title: "No — keep Mac awake", action: #selector(preventSleep), keyEquivalent: "")
        for item in [yesItem!, noItem!] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "“No” disables ALL system sleep.", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Battery drains.", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Toggles need no password after one-time setup.", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        wifiItem = NSMenuItem(title: "Reconnect Wi-Fi automatically", action: #selector(toggleWiFiReconnect), keyEquivalent: "")
        wifiItem.target = self
        menu.addItem(wifiItem)
        wifiStatusItem = NSMenuItem(title: "Wi-Fi: checking…", action: nil, keyEquivalent: "")
        menu.addItem(wifiStatusItem)
        menu.addItem(NSMenuItem(title: "Restarts Wi-Fi so macOS rejoins a known network.", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        setupItem = NSMenuItem(title: "Enable password-free toggles…", action: #selector(enableNoPrompt), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        let quit = NSMenuItem(title: "Quit (keeps current setting)", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        menu.autoenablesItems = false
        for item in menu.items where item.action == nil {
            item.isEnabled = false
        }
        statusItem.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        UserDefaults.standard.register(defaults: ["reconnectWiFi": true])
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        checkWiFi()
        wifiTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkWiFi()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        checkWiFi()
    }

    private func checkWiFi() {
        // While restarting, our own power-off must not read as the user turning Wi-Fi off.
        guard !wifiRestarting else { return updateWiFiStatus() }
        let (current, name) = currentWiFiState()
        wifiState = current
        let now = Date()
        // A power-on that failed after our restart is retried rather than left off.
        if current == .offline || (current == .off && wifiPowerPending), let name = name {
            if wifiOfflineSince == nil { wifiOfflineSince = now }
            if reconnectWiFi, let since = wifiOfflineSince,
               now.timeIntervalSince(wifiLastRestart ?? since) >= wifiRetryDelay(restarts: wifiRestarts) {
                restartWiFi(name)
            }
        } else {
            if current == .connected && wifiRestarts > 0 {
                NSLog("Wi-Fi reconnected after %d restart(s)", wifiRestarts)
            }
            wifiOfflineSince = nil
            wifiLastRestart = nil
            wifiRestarts = 0
            wifiPowerPending = false
        }
        updateWiFiStatus()
    }

    private func restartWiFi(_ name: String) {
        wifiRestarting = true
        wifiRestarts += 1
        wifiLastRestart = Date()
        NSLog("Wi-Fi offline; restarting %@ so macOS rejoins a known network (attempt %d)", name, wifiRestarts)
        DispatchQueue.global(qos: .utility).async {
            if setWiFiPower(name, on: false) {
                Thread.sleep(forTimeInterval: 2)
            } else {
                NSLog("Could not turn Wi-Fi off")
            }
            var restored = setWiFiPower(name, on: true)
            for _ in 0..<2 where !restored {
                Thread.sleep(forTimeInterval: 2)
                restored = setWiFiPower(name, on: true)
            }
            if !restored { NSLog("Could not turn Wi-Fi back on; will retry") }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.wifiRestarting = false
                self.wifiPowerPending = !restored
                self.checkWiFi()
            }
        }
    }

    private func updateWiFiStatus() {
        wifiItem.state = reconnectWiFi ? .on : .off
        if wifiRestarting {
            wifiStatusItem.title = "Wi-Fi: restarting to rejoin a network…"
            return
        }
        switch wifiState {
        case .missing: wifiStatusItem.title = "Wi-Fi: no Wi-Fi hardware found"
        case .off: wifiStatusItem.title = wifiPowerPending ? "Wi-Fi: could not turn back on; retrying" : "Wi-Fi: turned off — left alone"
        case .connected: wifiStatusItem.title = "Wi-Fi: connected"
        case .otherNetwork: wifiStatusItem.title = "Wi-Fi: idle — online through another network"
        case .offline:
            let offline = wifiOfflineSince.map { durationText(Date().timeIntervalSince($0)) } ?? "0s"
            let restarts = wifiRestarts == 0 ? "" : wifiRestarts == 1 ? " — restarted once" : " — restarted \(wifiRestarts)×"
            wifiStatusItem.title = "Wi-Fi: offline \(offline)" + restarts
        }
    }

    @objc private func toggleWiFiReconnect() {
        UserDefaults.standard.set(!reconnectWiFi, forKey: "reconnectWiFi")
        checkWiFi()
    }

    @objc private func didWake() {
        // macOS rejoins on its own after wake; give it the full grace period again.
        wifiOfflineSince = nil
        wifiLastRestart = nil
        wifiRestarts = 0
    }

    private func refresh() {
        state = try? readState()
        yesItem.state = state == false ? .on : .off
        noItem.state = state == true ? .on : .off
        yesItem.isEnabled = !busy
        noItem.isEnabled = !busy
        setupItem.isEnabled = !busy
        statusItem.button?.title = ""
        statusItem.button?.image = busy ? busyIcon : (state.map { $0 ? awakeIcon : sleepIcon } ?? unknownIcon)
        let label = busy ? "Lid: changing setting" : (state.map { $0 ? "Lid: Awake" : "Lid: Sleep" } ?? "Lid: unknown setting")
        statusItem.button?.setAccessibilityLabel(label)
        statusItem.button?.toolTip = busy ? "Changing sleep setting…" : state.map {
            $0 ? "Lid: Awake ☀︎ — sleep on close is off. System sleep is disabled on battery and charger."
               : "Lid: Sleep ☾ — sleep on close is on. Normal macOS sleep rules apply, including external-display clamshell mode."
        } ?? "Could not read macOS sleep settings. Click to retry."
    }

    @objc private func allowSleep() { setDisabled(false) }
    @objc private func preventSleep() { setDisabled(true) }
    @objc private func enableNoPrompt() {
        guard !busy else { return }
        perform("/usr/bin/osascript", ["-e", setupScript()], expectedState: nil)
    }
    @objc private func quitApp() {
        if !busy { NSApp.terminate(nil) }
    }

    private func setDisabled(_ disabled: Bool) {
        guard !busy else { return }
        refresh()
        guard state != disabled else { return }
        perform("/usr/bin/sudo", changeArguments(disabled: disabled), expectedState: disabled)
    }

    private func perform(_ executable: String, _ arguments: [String], expectedState: Bool?) {
        busy = true
        refresh()
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        authorizationProcess = process
        process.terminationHandler = { [weak self] completed in
            let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                self.authorizationProcess = nil
                self.refresh()
                if completed.terminationStatus != 0 {
                    // Canceling the system password dialog is not an application error.
                    if !errorText.contains("-128") {
                        let hint = expectedState == nil ? "" : "\nUse “Enable password-free toggles…” for one-time setup."
                        self.showError((errorText.isEmpty ? "The command failed." : errorText) + hint)
                    }
                } else if let expectedState = expectedState, self.state != expectedState {
                    self.showError("macOS did not report the requested setting. Please try again.")
                }
            }
        }
        do {
            try process.run()
        } catch {
            busy = false
            authorizationProcess = nil
            refresh()
            showError(error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Could not complete Lid Sleep action"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

if CommandLine.arguments.contains("--self-test") {
    do {
        func check(_ condition: Bool) {
            if !condition { fatalError("Self-test failed") }
        }
        check(try sleepDisabled(in: "System-wide power settings:\n SleepDisabled\t1\nCurrently in use:\n"))
        check(try !sleepDisabled(in: "System-wide power settings:\n SleepDisabled 0\nCurrently in use:\n"))
        check(try !sleepDisabled(in: "System-wide power settings:\nCurrently in use:\n sleep 1\n"))
        do {
            _ = try sleepDisabled(in: "unrecognized output")
            fatalError("Malformed output accepted")
        } catch {}
        do {
            _ = try sleepDisabled(in: "SleepDisabled 2")
            fatalError("Invalid value accepted")
        } catch {}
        check(changeArguments(disabled: true) == ["-n", "-k", "-u", "root", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        check(changeArguments(disabled: false) == ["-n", "-k", "-u", "root", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        check(appleScriptString("a\"b\\c") == "\"a\\\"b\\\\c\"")
        let script = setupScript(uid: 501)
        check(script.contains("#501 ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"))
        check(!script.contains("NOPASSWD: ALL"))
        check(!script.contains("NOPASSWD: /bin/"))
        check(script.contains("/usr/sbin/visudo -cqf"))
        let icons = [lidIcon(disabled: true), lidIcon(disabled: false),
                     lidIcon(disabled: nil), lidIcon(disabled: nil, busy: true)]
        for icon in icons {
            check(icon.isTemplate)
            check(icon.size == NSSize(width: 22, height: 18))
            check(icon.accessibilityDescription != nil)
            check(icon.tiffRepresentation != nil)
        }
        check(Set(icons.compactMap { $0.tiffRepresentation }).count == 4)
        check(isUsableIPv4(0xC0A8_0102))   // 192.168.1.2
        check(isUsableIPv4(0xAC14_0A06))   // 172.20.10.6, iPhone hotspot
        check(isUsableIPv4(0xC000_0002))   // 192.0.0.2, CLAT on IPv6-only Wi-Fi
        check(!isUsableIPv4(0xA9FE_0102))  // 169.254.1.2, DHCP failed
        check(!isUsableIPv4(0x7F00_0001))
        check(!isUsableIPv4(0))
        check(classifyWiFi(interface: nil, powerOn: true, addressed: ["en0"]) == .missing)
        check(classifyWiFi(interface: "en0", powerOn: false, addressed: []) == .off)
        check(classifyWiFi(interface: "en0", powerOn: true, addressed: ["en0", "utun3"]) == .connected)
        check(classifyWiFi(interface: "en0", powerOn: true, addressed: ["en7"]) == .otherNetwork)
        check(classifyWiFi(interface: "en0", powerOn: true, addressed: ["utun3", "bridge100"]) == .offline)
        check(wifiRetryDelay(restarts: 0) == 20 && wifiRetryDelay(restarts: 1) == 60)
        check(wifiRetryDelay(restarts: 3) == 300 && wifiRetryDelay(restarts: 50) == 300)
        check(durationText(59) == "59s" && durationText(125) == "2m" && durationText(3720) == "1h 2m")
        print("PASS: parsing, noninteractive commands, scoped setup, four distinct template icons, and Wi-Fi checks; no settings changed.")
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.contains("--status") {
    do {
        print(try readState() ? "Sleep on close: No (system sleep disabled)" : "Sleep on close: Yes (normal macOS rules)")
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments == [CommandLine.arguments[0], "--wifi-status"] {
    let (state, name) = currentWiFiState()
    let descriptions: [WiFiState: String] = [
        .missing: "no Wi-Fi hardware found", .off: "turned off", .connected: "connected",
        .otherNetwork: "idle; online through another network", .offline: "offline"
    ]
    print("Wi-Fi\(name.map { " (\($0))" } ?? ""): \(descriptions[state]!)")
    print("Reconnect automatically: \(UserDefaults.standard.object(forKey: "reconnectWiFi") as? Bool ?? true ? "on" : "off")")
} else if CommandLine.arguments == [CommandLine.arguments[0], "--enable-no-prompt"] {
    do {
        try runCommand("/usr/bin/osascript", ["-e", setupScript()])
        print("One-time setup complete. Only the two exact sleep commands are authorized.")
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--set",
          ["sleep", "awake"].contains(CommandLine.arguments[2]) {
    do {
        let disabled = CommandLine.arguments[2] == "awake"
        try runCommand("/usr/bin/sudo", changeArguments(disabled: disabled))
        guard try readState() == disabled else {
            throw NSError(domain: "LidSleep", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "The requested setting was not applied."])
        }
        print(disabled ? "Lid: Awake" : "Lid: Sleep")
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--icon-preview" {
    do {
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, icon) in [("awake", lidIcon(disabled: true)), ("sleep", lidIcon(disabled: false)),
                             ("unknown", lidIcon(disabled: nil)), ("busy", lidIcon(disabled: nil, busy: true))] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 176, pixelsHigh: 144,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw NSError(domain: "LidSleep", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Could not render icon preview."])
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: 8, y: 8)
            let bounds = NSRect(origin: .zero, size: icon.size)
            NSColor.white.setFill()
            bounds.fill()
            icon.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "LidSleep", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Could not encode icon preview."])
            }
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
        print("Exported four icon previews.")
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.contains("-h") || CommandLine.arguments.contains("--help") {
    print("LidSleep: native menu-bar sleep toggle.\nOptions: --status, --wifi-status, --self-test, --set sleep|awake, --enable-no-prompt, --icon-preview DIRECTORY, --help\nSetup requests admin approval once; toggles never prompt.")
} else if CommandLine.arguments.count > 1 {
    fputs("Unknown arguments. Use --help.\n", stderr)
    exit(2)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
}
