import Foundation
import IOKit

// MARK: - Errors

enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case smcResult(UInt8, key: String)
    case keyNotFound(String)
    case notPrivileged
    case unsupportedType(key: String, type: String)
    case thermalLocked(String)

    var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let kr): return String(format: "IOServiceOpen failed (0x%08x)", UInt32(bitPattern: kr))
        case .callFailed(let kr): return String(format: "SMC call failed (0x%08x)", UInt32(bitPattern: kr))
        case .smcResult(let code, let key):
            let names: [UInt8: String] = [
                0x80: "comm collision", 0x81: "spurious data", 0x82: "bad command",
                0x83: "bad parameter", 0x84: "key not found", 0x85: "key not readable",
                0x86: "key not writable", 0x87: "size mismatch", 0x88: "framing error",
                0x89: "bad argument",
            ]
            return String(format: "SMC error 0x%02x (%@) for key %@",
                          code, names[code] ?? "unknown", key)
        case .keyNotFound(let key): return "SMC key not found: \(key)"
        case .notPrivileged: return "not privileged (fan writes need root — run with sudo)"
        case .unsupportedType(let key, let type): return "unsupported SMC data type '\(type)' for key \(key)"
        case .thermalLocked(let key):
            return "thermal manager refused to yield \(key) — fans stay under macOS control (heavy load can cause this; try again in a minute)"
        }
    }
}

// MARK: - Wire structs (must match the AppleSMC kernel ABI, 80 bytes total)

struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    // C sizeof(SMCKeyInfoData) is 12 (trailing pad); Swift packs at 9 — re-align to the kernel ABI.
    var _pad0: UInt8 = 0
    var _pad1: UInt8 = 0
    var _pad2: UInt8 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var _pad3: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

// MARK: - FourCC helpers

func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for c in s.utf8 { v = (v << 8) | UInt32(c) }
    return v
}

func fourCCString(_ v: UInt32) -> String {
    let b: [UInt8] = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                      UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? "????"
}

// MARK: - SMC client

final class SMC {
    private var conn: io_connect_t = 0

    private static let kernelIndex: UInt32 = 2 // kSMCHandleYPCEvent
    private static let cmdReadKey: UInt8 = 5
    private static let cmdWriteKey: UInt8 = 6
    private static let cmdKeyFromIndex: UInt8 = 8
    private static let cmdKeyInfo: UInt8 = 9

    private static let resultKeyNotFound: UInt8 = 0x84
    private static let krNotPrivileged = kern_return_t(bitPattern: 0xE00002C1)
    private static let krNotPermitted = kern_return_t(bitPattern: 0xE00002C2)

    init() throws {
        precondition(MemoryLayout<SMCParamStruct>.stride == 80,
                     "SMCParamStruct layout mismatch: \(MemoryLayout<SMCParamStruct>.stride)")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(conn, SMC.kernelIndex,
                                           &input, MemoryLayout<SMCParamStruct>.stride,
                                           &output, &outSize)
        if kr == SMC.krNotPrivileged || kr == SMC.krNotPermitted { throw SMCError.notPrivileged }
        guard kr == kIOReturnSuccess else { throw SMCError.callFailed(kr) }
        return output
    }

    // MARK: raw key access

    struct KeyInfo {
        let size: Int
        let type: String
    }

    func keyInfo(_ key: String) throws -> KeyInfo {
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.data8 = SMC.cmdKeyInfo
        let out = try call(&input)
        if out.result == SMC.resultKeyNotFound { throw SMCError.keyNotFound(key) }
        guard out.result == 0 else { throw SMCError.smcResult(out.result, key: key) }
        return KeyInfo(size: Int(out.keyInfo.dataSize), type: fourCCString(out.keyInfo.dataType))
    }

    func readBytes(_ key: String) throws -> (bytes: [UInt8], type: String) {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = SMC.cmdReadKey
        let out = try call(&input)
        if out.result == SMC.resultKeyNotFound { throw SMCError.keyNotFound(key) }
        guard out.result == 0 else { throw SMCError.smcResult(out.result, key: key) }
        let data = withUnsafeBytes(of: out.bytes) { Array($0.prefix(info.size)) }
        return (data, info.type)
    }

    func writeBytes(_ key: String, _ bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == info.size else {
            throw SMCError.unsupportedType(key: key, type: "\(info.type) size \(info.size) != \(bytes.count)")
        }
        // Another SMC client writing at the same time surfaces as transient
        // 0x80/0x81 results — retry those. 0x82 is NOT transient here: on M3+
        // it means thermalmonitord holds the fan keys (see Fans.writeMode).
        let retryable: Set<UInt8> = [0x80, 0x81]
        for attempt in 0..<4 {
            var input = SMCParamStruct()
            input.key = fourCC(key)
            input.keyInfo.dataSize = UInt32(info.size)
            input.data8 = SMC.cmdWriteKey
            withUnsafeMutableBytes(of: &input.bytes) { buf in
                for (i, b) in bytes.enumerated() { buf[i] = b }
            }
            let out = try call(&input)
            if out.result == 0 { return }
            if retryable.contains(out.result) && attempt < 3 {
                usleep(40_000)
                continue
            }
            throw SMCError.smcResult(out.result, key: key)
        }
    }

    // MARK: typed access

    func readNumber(_ key: String) throws -> Double {
        let (b, type) = try readBytes(key)
        switch type {
        case "flt ":
            guard b.count >= 4 else { throw SMCError.unsupportedType(key: key, type: type) }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ", "si8 ":
            return Double(b[0])
        case "ui16":
            return Double(UInt32(b[0]) << 8 | UInt32(b[1]))
        case "ui32":
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "fpe2":
            return Double(UInt32(b[0]) << 8 | UInt32(b[1])) / 4.0
        case "sp78":
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        default:
            throw SMCError.unsupportedType(key: key, type: type)
        }
    }

    func writeNumber(_ key: String, _ value: Double) throws {
        let info = try keyInfo(key)
        switch info.type {
        case "flt ":
            let bits = Float(value).bitPattern
            try writeBytes(key, [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
                                 UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)])
        case "ui8 ":
            try writeBytes(key, [UInt8(max(0, min(255, value)))])
        case "ui16":
            let v = UInt16(max(0, min(65535, value)))
            try writeBytes(key, [UInt8(v >> 8), UInt8(v & 0xff)])
        case "fpe2":
            let v = UInt16(max(0, min(16383, value)) * 4)
            try writeBytes(key, [UInt8(v >> 8), UInt8(v & 0xff)])
        default:
            throw SMCError.unsupportedType(key: key, type: info.type)
        }
    }

    func keyExists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    func allKeys() throws -> [String] {
        let count = Int(try readNumber("#KEY"))
        var keys: [String] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            var input = SMCParamStruct()
            input.data8 = SMC.cmdKeyFromIndex
            input.data32 = UInt32(i)
            let out = try call(&input)
            guard out.result == 0 else { continue }
            keys.append(fourCCString(out.key))
        }
        return keys
    }
}

// MARK: - Fan model

struct FanInfo {
    let id: Int
    let actual: Double
    let target: Double
    let min: Double
    let max: Double
    let manual: Bool
}

final class Fans {
    let smc: SMC
    let count: Int
    /// Per-fan mode key: "F0Md" (through M4), "F0md" (M5+), nil on Intel (FS! bitmask).
    private let modeKeys: [String?]

    init(smc: SMC) throws {
        self.smc = smc
        let n = Int(try smc.readNumber("FNum"))
        self.count = n
        self.modeKeys = (0..<n).map { i in
            if smc.keyExists("F\(i)Md") { return "F\(i)Md" }
            if smc.keyExists("F\(i)md") { return "F\(i)md" }
            return nil
        }
    }

    func info(_ i: Int) throws -> FanInfo {
        let actual = try smc.readNumber("F\(i)Ac")
        let target = (try? smc.readNumber("F\(i)Tg")) ?? 0
        let minRPM = (try? smc.readNumber("F\(i)Mn")) ?? 0
        let maxRPM = (try? smc.readNumber("F\(i)Mx")) ?? 0
        let manual: Bool
        if let mk = modeKeys[i] {
            // Mode 1 = forced/manual. Mode 0 = classic auto. Mode 3 =
            // thermalmonitord's system control (the normal state on M3+) —
            // both 0 and 3 are automatic.
            manual = ((try? smc.readNumber(mk)) ?? 0) == 1
        } else if smc.keyExists("FS! ") {
            let mask = (try? smc.readNumber("FS! ")) ?? 0
            manual = (Int(mask) & (1 << i)) != 0
        } else {
            manual = false
        }
        return FanInfo(id: i, actual: actual, target: target, min: minRPM, max: maxRPM, manual: manual)
    }

    func all() throws -> [FanInfo] {
        try (0..<count).map { try info($0) }
    }

    /// Force fan `i` to `rpm`, clamped to its [min, max] envelope. Root required.
    /// On M3+/M4 the first engage can take several seconds (thermal-manager unlock).
    func setSpeed(_ i: Int, rpm: Double) throws {
        let f = try info(i)
        // Firmware accepts targets outside [min, max] (even 0) — the envelope
        // is a guideline, so the clamp here is a deliberate safety choice.
        let clamped = max(f.min, min(f.max, rpm))
        if let mk = modeKeys[i] {
            try writeMode(mk, 1)
        } else {
            try legacySetManual(i, true)
        }
        try writeTarget(i, clamped)
    }

    /// Return every fan to automatic control and release the thermal-manager
    /// unlock (Ftst). Returns non-fatal warnings: once Ftst is cleared,
    /// thermalmonitord reclaims the fans even if a mode write was refused.
    func releaseAll() throws -> [String] {
        var warnings: [String] = []
        for i in 0..<count {
            do {
                if let mk = modeKeys[i] {
                    try writeMode(mk, 0)
                } else {
                    try legacySetManual(i, false)
                }
            } catch {
                warnings.append("fan \(i): \(error)")
            }
        }
        if smc.keyExists("Ftst") {
            try smc.writeNumber("Ftst", 0)
        } else if warnings.count == count {
            // nothing worked and there is no unlock flag to release
            throw SMCError.thermalLocked("F0Md")
        }
        return warnings
    }

    /// M3+/M4: thermalmonitord holds the fan keys and the firmware rejects
    /// mode writes with 0x82 until the Ftst diagnostic flag is set and the
    /// thermal manager yields (typically 3–6 s, longer under heavy load).
    private func writeMode(_ key: String, _ value: Double) throws {
        let current = (try? smc.readNumber(key)) ?? -1
        if current == value { return }
        // Mode 3 = system control; asking for auto (0) there is already satisfied.
        if value == 0 && current == 3 { return }
        do {
            try smc.writeNumber(key, value)
            return
        } catch let e as SMCError {
            guard case .smcResult(let code, _) = e, code == 0x82 else { throw e }
            guard smc.keyExists("Ftst") else { throw e }
        }
        try smc.writeNumber("Ftst", 1)
        // Poll rather than blind-sleeping: the manager yields when it yields
        // (measured ~1–4 s cold on M4 Pro), so total wait = actual yield time.
        for _ in 0..<120 {
            Thread.sleep(forTimeInterval: 0.1)
            do {
                try smc.writeNumber(key, value)
                return
            } catch let e as SMCError {
                guard case .smcResult(let code, _) = e, code == 0x82 else { throw e }
            }
        }
        throw SMCError.thermalLocked(key)
    }

    /// Target writes can still bounce 0x82 briefly right after the mode flips.
    private func writeTarget(_ i: Int, _ rpm: Double) throws {
        let key = "F\(i)Tg"
        for _ in 0..<20 {
            do {
                try smc.writeNumber(key, rpm)
                return
            } catch let e as SMCError {
                guard case .smcResult(let code, _) = e, code == 0x82 else { throw e }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw SMCError.thermalLocked(key)
    }

    /// Pre-M3 / Intel path: manual mode is a bitmask in "FS! ".
    private func legacySetManual(_ i: Int, _ manual: Bool) throws {
        guard smc.keyExists("FS! ") else { throw SMCError.keyNotFound("F\(i)Md / FS! ") }
        var mask = Int((try? smc.readNumber("FS! ")) ?? 0)
        if manual { mask |= (1 << i) } else { mask &= ~(1 << i) }
        try smc.writeNumber("FS! ", Double(mask))
    }
}

// MARK: - Die temperature sensors

/// Averaged Apple Silicon die temperatures (readable without root).
/// Key sets from smctemp: M4 CPU = Tp01/Tp09/Tp0f/Tp05/Tp0D, M4 GPU =
/// Tg0D/Tg0P/Tg0X/Tg0j (M3 adds a few more). Keys that don't exist on the
/// running chip are filtered out at init; readings outside 10–120 °C are junk.
final class Sensors {
    private let smc: SMC
    private let cpuKeys: [String]
    private let gpuKeys: [String]

    private static let cpuCandidates = ["Tp01", "Tp09", "Tp0f", "Tp05", "Tp0D",
                                        "Tp0n", "Tp0j", "Tp0r"]
    private static let gpuCandidates = ["Tg0D", "Tg0P", "Tg0X", "Tg0j",
                                        "Tg0b", "Tg0v"]

    init(smc: SMC) {
        self.smc = smc
        cpuKeys = Self.cpuCandidates.filter { smc.keyExists($0) }
        gpuKeys = Self.gpuCandidates.filter { smc.keyExists($0) }
    }

    private func average(_ keys: [String]) -> Double? {
        let valid = keys.compactMap { try? smc.readNumber($0) }.filter { $0 > 10 && $0 < 120 }
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }

    func cpu() -> Double? { average(cpuKeys) }
    func gpu() -> Double? { average(gpuKeys) }
}
