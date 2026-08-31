import Foundation

// fanctl — tiny SMC fan utility for FanDial.
//
//   fanctl status [--json]   read fan state + die temps (no root needed)
//   fanctl temp              read CPU/GPU die temperatures (no root needed)
//   fanctl set <rpm>         force all fans to <rpm>, clamped to [min, max] (root)
//   fanctl max               force all fans to their max (root)
//   fanctl auto              hand fans back to macOS automatic control (root)
//   fanctl probe             test which fan keys accept writes (root, no state change)
//   fanctl keys              dump fan-related SMC keys (debug)

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("fanctl: " + msg + "\n").data(using: .utf8)!)
    exit(code)
}

func jsonEscape(_ d: Double) -> String {
    d.isFinite ? String(format: "%.1f", d) : "0"
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "status"

do {
    let smc = try SMC()
    let fans = try Fans(smc: smc)

    switch command {
    case "status":
        let infos = try fans.all()
        let sensors = Sensors(smc: smc)
        let cpuT = sensors.cpu()
        let gpuT = sensors.gpu()
        if args.contains("--json") {
            let items = infos.map {
                "{\"id\":\($0.id),\"actual\":\(jsonEscape($0.actual)),\"target\":\(jsonEscape($0.target)),\"min\":\(jsonEscape($0.min)),\"max\":\(jsonEscape($0.max)),\"manual\":\($0.manual)}"
            }
            let cpuJ = cpuT.map(jsonEscape) ?? "null"
            let gpuJ = gpuT.map(jsonEscape) ?? "null"
            print("{\"fans\":[\(items.joined(separator: ","))],\"cpuTemp\":\(cpuJ),\"gpuTemp\":\(gpuJ)}")
        } else {
            if infos.isEmpty { print("no fans reported (FNum = 0)") }
            for f in infos {
                let mode = f.manual ? "MANUAL" : "auto"
                print(String(format: "fan %d  %5.0f rpm  (target %5.0f, range %.0f–%.0f)  [%@]",
                             f.id, f.actual, f.target, f.min, f.max, mode))
            }
            let temps = [cpuT.map { String(format: "CPU %.0f°C", $0) },
                         gpuT.map { String(format: "GPU %.0f°C", $0) }].compactMap { $0 }
            if !temps.isEmpty { print(temps.joined(separator: "  ")) }
        }

    case "temp":
        let sensors = Sensors(smc: smc)
        let temps = [sensors.cpu().map { String(format: "CPU %.1f°C", $0) },
                     sensors.gpu().map { String(format: "GPU %.1f°C", $0) }].compactMap { $0 }
        if temps.isEmpty { print("no readable die-temperature sensors on this chip") }
        else { print(temps.joined(separator: "  ")) }

    case "set":
        guard args.count >= 2, let rpm = Double(args[1]), rpm > 0 else {
            fail("usage: fanctl set <rpm>")
        }
        FileHandle.standardError.write("engaging manual mode (first engage on M3+/M4 can take ~6 s)…\n".data(using: .utf8)!)
        for i in 0..<fans.count { try fans.setSpeed(i, rpm: rpm) }
        Thread.sleep(forTimeInterval: 0.15)
        for f in try fans.all() {
            print(String(format: "fan %d → target %.0f rpm [%@]", f.id, f.target, f.manual ? "MANUAL" : "auto"))
        }

    case "max":
        FileHandle.standardError.write("engaging manual mode (first engage on M3+/M4 can take ~6 s)…\n".data(using: .utf8)!)
        for i in 0..<fans.count {
            let f = try fans.info(i)
            try fans.setSpeed(i, rpm: f.max)
        }
        print("fans → max, manual mode")

    case "auto":
        let warnings = try fans.releaseAll()
        for w in warnings {
            FileHandle.standardError.write("warning: \(w)\n".data(using: .utf8)!)
        }
        print("fans → automatic control (thermal-manager unlock released)")

    case "probe":
        // Write every fan key back to its CURRENT bytes — changes nothing,
        // but tells us exactly which writes this OS/firmware accepts.
        print("probing SMC write path (writes current values back — no state change)")
        for i in 0..<fans.count {
            for key in ["F\(i)Md", "F\(i)Tg", "F\(i)Mn"] where smc.keyExists(key) {
                do {
                    let (bytes, type) = try smc.readBytes(key)
                    let hex = bytes.map { String(format: "%02x", $0) }.joined()
                    try smc.writeBytes(key, bytes)
                    print("\(key) [\(type)] \(hex) → write OK")
                } catch SMCError.notPrivileged {
                    fail("probe needs root — run: sudo ./fanctl probe", code: 3)
                } catch {
                    print("\(key) → \(error)")
                }
            }
        }

    case "keys":
        let fanKeys = try smc.allKeys().filter { $0.hasPrefix("F") }
        for k in fanKeys.sorted() {
            if let info = try? smc.keyInfo(k) {
                let value = (try? smc.readNumber(k)).map { String(format: "%.1f", $0) } ?? "-"
                print("\(k)  type=\(info.type) size=\(info.size)  value=\(value)")
            }
        }

    default:
        fail("unknown command '\(command)' — try: status | temp | set <rpm> | max | auto | probe | keys")
    }
} catch SMCError.notPrivileged {
    fail("fan writes need root — run with sudo", code: 3)
} catch {
    fail("\(error)", code: 2)
}
