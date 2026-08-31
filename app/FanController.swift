import AppKit
import CryptoKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class FanController: ObservableObject {
    struct Snapshot {
        var fans: [FanInfo] = []
        var minRPM: Double = 1000
        var maxRPM: Double = 6000
        var manual = false
        var target: Double = 0
        var actualAvg: Double = 0
        var cpuTemp: Double?
        var gpuTemp: Double?
    }

    @Published var snapshot = Snapshot()
    @Published var errorText: String?
    @Published var applying = false
    /// Non-nil while the user is dragging the dial (or a command is in flight for that drag).
    @Published var dragFraction: Double?
    @Published var helperInstalled = PrivilegedRunner.helperInstalled
    @Published var helperStale = PrivilegedRunner.helperStale
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Latest command requested while another was in flight — replaces, never queues up.
    private var pendingCommand: String?

    /// The manual RPM the user asked for (nil = automatic). Used to re-engage
    /// after sleep/wake resets Ftst, or if thermalmonitord reclaims the fans.
    private var desiredRPM: Int?
    private var lastReengage = Date.distantPast
    private var reengageFails = 0

    private var smc: SMC?
    private var fans: Fans?
    private var sensors: Sensors?
    private var timer: Timer?

    static private(set) weak var shared: FanController?

    init() {
        do {
            let smc = try SMC()
            self.smc = smc
            self.fans = try Fans(smc: smc)
            self.sensors = Sensors(smc: smc)
        } catch {
            errorText = "\(error)"
        }
        refresh()
        // If a previous run (or the CLI) left fans manual, adopt that target
        // as the desired state so wake-recovery keeps working across restarts.
        if snapshot.manual { desiredRPM = Int(snapshot.target) }
        FanController.shared = self
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Firmware resets Ftst during sleep, so manual control is always lost
        // on wake — refresh shortly after and let re-engage restore it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.refresh()
            }
        }
    }

    func installHelper() {
        guard !applying else { return }
        applying = true
        Task.detached(priority: .userInitiated) {
            let result = PrivilegedRunner.installHelper()
            await MainActor.run {
                self.applying = false
                self.helperInstalled = PrivilegedRunner.helperInstalled
                self.helperStale = PrivilegedRunner.helperStale
                if case .failure(let msg) = result { self.errorText = msg }
            }
        }
    }

    func refresh() {
        helperInstalled = PrivilegedRunner.helperInstalled
        helperStale = PrivilegedRunner.helperStale
        guard let fans else { return }
        do {
            let infos = try fans.all()
            guard !infos.isEmpty else {
                errorText = "SMC reports no fans on this Mac."
                return
            }
            var s = Snapshot()
            s.fans = infos
            s.minRPM = infos.map(\.min).min() ?? 0
            s.maxRPM = infos.map(\.max).max() ?? 1
            s.manual = infos.contains { $0.manual }
            s.target = infos.map(\.target).max() ?? 0
            s.actualAvg = infos.map(\.actual).reduce(0, +) / Double(infos.count)
            s.cpuTemp = sensors?.cpu()
            s.gpuTemp = sensors?.gpu()
            snapshot = s
            if s.manual { reengageFails = 0 }
            maybeReengage()
        } catch {
            errorText = "\(error)"
        }
    }

    /// Sleep/wake (or a thermalmonitord reclaim) silently drops manual mode.
    /// If the user wanted a manual RPM and the silent helper is available,
    /// re-engage — with a cooldown and a failure cap so we never sit in a
    /// tug-of-war with a thermal manager that refuses to yield.
    private func maybeReengage() {
        guard let desired = desiredRPM, helperInstalled, !applying, !snapshot.manual else { return }
        guard Date().timeIntervalSince(lastReengage) > 20 else { return }
        if reengageFails >= 3 {
            desiredRPM = nil
            errorText = "macOS keeps reclaiming the fans — leaving them on automatic."
            return
        }
        lastReengage = Date()
        reengageFails += 1
        run("set \(desired)")
    }

    // MARK: fraction ↔ rpm

    func rpm(for fraction: Double) -> Double {
        let f = max(0, min(1, fraction))
        let raw = snapshot.minRPM + f * (snapshot.maxRPM - snapshot.minRPM)
        return (raw / 50).rounded() * 50
    }

    func fraction(for rpm: Double) -> Double {
        guard snapshot.maxRPM > snapshot.minRPM else { return 0 }
        return max(0, min(1, (rpm - snapshot.minRPM) / (snapshot.maxRPM - snapshot.minRPM)))
    }

    /// What the dial should show right now.
    var displayFraction: Double {
        if let d = dragFraction { return d }
        return fraction(for: snapshot.manual ? snapshot.target : snapshot.actualAvg)
    }

    var displayRPM: Int {
        if let d = dragFraction { return Int(rpm(for: d)) }
        return Int(snapshot.actualAvg.rounded())
    }

    // MARK: actions

    func commit(fraction: Double) {
        let target = Int(rpm(for: fraction))
        desiredRPM = target
        reengageFails = 0
        run("set \(target)")
    }

    func setAuto() {
        desiredRPM = nil
        dragFraction = nil
        run("auto")
    }

    func setMax() {
        let target = Int(snapshot.maxRPM)
        desiredRPM = target
        reengageFails = 0
        dragFraction = 1
        run("max")
    }

    /// Center tap: releases manual → auto only. Engaging manual costs a
    /// multi-second thermal unlock and shouldn't happen from a stray tap.
    func toggleAuto() {
        if snapshot.manual { setAuto() }
    }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            errorText = "login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Called on quit: hand fans back to macOS so nothing stays pinned after
    /// the app is gone. Silent-helper only — never a password dialog at quit.
    static func restoreAutoOnQuit() {
        guard let c = shared, c.snapshot.manual, PrivilegedRunner.helperInstalled else { return }
        _ = PrivilegedRunner.run("auto")
    }

    /// Other fan-control apps re-assert their own targets; writing under them
    /// just loses the race (and can collide at the SMC). Name one if running.
    private func competingFanApp() -> String? {
        for app in NSWorkspace.shared.runningApplications {
            let bundle = app.bundleIdentifier?.lowercased() ?? ""
            if bundle.contains("macsfancontrol") || bundle.contains("smcfancontrol")
                || bundle.contains("tgpro") {
                return app.localizedName ?? "another fan-control app"
            }
        }
        return nil
    }

    private func run(_ command: String) {
        // A cold engage takes seconds — don't drop dial moves made meanwhile,
        // remember the latest and apply it when the current command lands.
        if applying {
            pendingCommand = command
            return
        }
        if let other = competingFanApp() {
            errorText = "\(other) is running and will override FanDial — quit it, then try again."
            dragFraction = nil
            return
        }
        applying = true
        Task.detached(priority: .userInitiated) {
            let result = PrivilegedRunner.run(command)
            await MainActor.run {
                self.applying = false
                if case .failure(let msg) = result {
                    self.errorText = msg
                } else {
                    self.errorText = nil
                }
                if let next = self.pendingCommand {
                    self.pendingCommand = nil
                    self.run(next)
                    return
                }
                self.dragFraction = nil
                self.refresh()
            }
        }
    }
}

// MARK: - Privileged command runner

/// Runs `fanctl <command>`. If a root-owned setuid fanctl is installed
/// (see install-helper.sh) it runs directly with no prompt; otherwise it
/// goes through macOS's own admin-authorization dialog via osascript —
/// the OS collects the credentials, never this app.
enum PrivilegedRunner {
    enum Result { case ok, cancelled, failure(String) }

    static let installedHelperPath = "/usr/local/bin/fanctl"

    private static func candidatePaths() -> [String] {
        var candidates = [installedHelperPath]
        if let res = Bundle.main.resourceURL?.appendingPathComponent("fanctl").path {
            candidates.append(res)
        }
        candidates.append(FileManager.default.currentDirectoryPath + "/fanctl")
        return candidates
    }

    /// Prefer a root setuid helper wherever it lives (silent writes),
    /// otherwise any executable copy (admin-dialog path).
    static func fanctlPath() -> String? {
        let candidates = candidatePaths()
        return candidates.first(where: isSetuidRoot)
            ?? candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var helperInstalled: Bool { isSetuidRoot(installedHelperPath) }

    /// The freshest local fanctl build that could be (re)installed as the helper.
    private static func updateSourcePath() -> String? {
        candidatePaths().dropFirst().first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// True when the installed root helper's binary differs from the current build.
    static var helperStale: Bool {
        guard helperInstalled, let source = updateSourcePath(),
              let installed = try? Data(contentsOf: URL(fileURLWithPath: installedHelperPath)),
              let fresh = try? Data(contentsOf: URL(fileURLWithPath: source)) else { return false }
        return SHA256.hash(data: installed) != SHA256.hash(data: fresh)
    }

    /// Install the bundled fanctl as a root setuid helper — one admin dialog,
    /// then every future fan change is silent. Same tradeoff as install-helper.sh.
    static func installHelper() -> Result {
        guard let source = updateSourcePath() else {
            return .failure("no fanctl binary found to install")
        }
        let cmd = "mkdir -p /usr/local/bin && /usr/bin/install -o root -g wheel -m 4755 '\(source)' \(installedHelperPath)"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        let r = exec("/usr/bin/osascript", args: ["-e", script])
        if case .failure(let msg) = r, msg.contains("-128") || msg.lowercased().contains("cancel") {
            return .cancelled
        }
        return r
    }

    private static func isSetuidRoot(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return st.st_uid == 0 && (st.st_mode & mode_t(S_ISUID)) != 0
    }

    static func run(_ command: String) -> Result {
        guard let path = fanctlPath() else {
            return .failure("fanctl helper not found — run build.sh first")
        }
        // Prefer the silent path when a root setuid helper is installed.
        if isSetuidRoot(path) {
            return exec(path, args: command.split(separator: " ").map(String.init))
        }
        let script = "do shell script \"'\(path)' \(command)\" with administrator privileges"
        let r = exec("/usr/bin/osascript", args: ["-e", script])
        if case .failure(let msg) = r, msg.contains("-128") || msg.lowercased().contains("cancel") {
            return .cancelled
        }
        return r
    }

    private static func exec(_ launchPath: String, args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        do {
            try p.run()
        } catch {
            return .failure("could not run \(launchPath): \(error.localizedDescription)")
        }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return .ok }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failure(msg.isEmpty ? "helper exited with status \(p.terminationStatus)" : msg)
    }
}
