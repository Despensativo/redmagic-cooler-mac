import Foundation
import IOKit

/// Host-machine facts the UI displays: the Mac's marketing name, Apple Silicon
/// chip identifier, and the user's preferred temperature unit.
enum SystemInfo {

    // ── Temperature unit ─────────────────────────────────────────────────────

    enum TempUnit {
        case celsius, fahrenheit
        var suffix: String { self == .celsius ? "°C" : "°F" }
    }

    /// The system-wide preference (System Settings → General → Language &
    /// Region → Temperature), falling back to the locale's measurement system.
    static func temperatureUnit() -> TempUnit {
        // `AppleTemperatureUnit` lives in NSGlobalDomain, which `.standard`
        // searches. Its value is "Celsius" or "Fahrenheit".
        if let raw = UserDefaults.standard.string(forKey: "AppleTemperatureUnit") {
            return raw.lowercased().hasPrefix("f") ? .fahrenheit : .celsius
        }
        return Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
    }

    /// Formats a Celsius value in the user's unit, e.g. `54°C` / `129°F`.
    /// - Parameter degreeOnly: drop the C/F letter, for tight telemetry cells.
    static func formatTemp(_ celsius: Double?,
                           degreeOnly: Bool = false,
                           unit: TempUnit? = nil) -> String {
        guard let celsius else { return "—" }
        let unit = unit ?? temperatureUnit()
        // Floor in °C keeps integer display strictly aligned with >= K°C Step-Ladder
        // and < K°C Safety thresholds (e.g. 49.7°C shows 49°C while < 50°C Standby).
        let displayInt: Int
        if unit == .fahrenheit {
            displayInt = Int((celsius * 9 / 5 + 32).rounded())
        } else {
            displayInt = Int(floor(celsius))
        }
        return degreeOnly ? "\(displayInt)°" : "\(displayInt)\(unit.suffix)"
    }

    static func formatTemp(_ celsius: Int?,
                           degreeOnly: Bool = false,
                           unit: TempUnit? = nil) -> String {
        formatTemp(celsius.map(Double.init), degreeOnly: degreeOnly, unit: unit)
    }

    // ── Chip & Mac model name ────────────────────────────────────────────────

    /// Clean processor / Apple Silicon chip name from `machdep.cpu.brand_string`
    /// (e.g. `"Apple M5"`, `"Apple M4 Pro"`, `"Intel Core i7"`). Resolved once via sysctl.
    static let chipName: String? = {
        guard let raw = sysctlString("machdep.cpu.brand_string"), !raw.isEmpty else {
            return nil
        }
        return formatChipName(raw)
    }()

    /// Short chip suffix for tight labels (e.g. `"Apple M5"` -> `"M5"`, `"Apple M4 Pro"` -> `"M4 Pro"`).
    static var shortChipName: String? {
        guard let chip = chipName else { return nil }
        if chip.hasPrefix("Apple ") {
            return String(chip.dropFirst("Apple ".count))
        }
        return chip
    }

    /// Formats a raw `machdep.cpu.brand_string` for compact UI display.
    static func formatChipName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Apple ") {
            return trimmed
        }
        // Compact Intel strings like "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz" -> "Intel Core i7"
        let cleaned = trimmed
            .replacingOccurrences(of: "(R)", with: "")
            .replacingOccurrences(of: "(TM)", with: "")
        if let range = cleaned.range(of: #"Intel\s+Core\s+i[3579]"#, options: .regularExpression) {
            return String(cleaned[range]).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }
        return cleaned.components(separatedBy: " @ ").first?.trimmingCharacters(in: .whitespaces) ?? trimmed
    }

    /// Formats an IORegistry `product-name` such as `"MacBook Air (13-inch, M5)"`
    /// into a crisp display model like `"MacBook Air 13\""`.
    static func formatFriendlyModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parenStart = trimmed.firstIndex(of: "(") else {
            return trimmed
        }
        let base = trimmed[..<parenStart].trimmingCharacters(in: .whitespaces)
        let inside = String(trimmed[parenStart...])

        // Extract screen diagonal if present (e.g. "13-inch" -> "13\"")
        if let inchRange = inside.range(of: #"\d+(?=-inch)"#, options: .regularExpression) {
            let size = inside[inchRange]
            return "\(base) \(size)\""
        }
        return base.isEmpty ? trimmed : base
    }

    /// Guards `cachedModel`, which is written from the background resolver and
    /// read from the main thread on every menu draw.
    private static let cacheLock = NSLock()
    private static var cachedModel: String?

    /// Best known friendly model name, e.g. `"MacBook Air 13\""` or `"MacBook Pro 14\""`.
    ///
    /// Reads Apple Silicon's `IODeviceTree:/product` (`product-name`) synchronously
    /// in <1 ms when available; falls back to the cached `system_profiler` name or
    /// `hw.model` family on Intel Macs.
    static var macModel: String {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cachedModel { return cachedModel }
        let value = ioRegistryProductName().map(formatFriendlyModel)
            ?? UserDefaults.standard.string(forKey: Config.Key.cachedMacModel)
            ?? coarseModelFamily()
        cachedModel = value
        return value
    }

    /// Refines `macModel` (using IORegistry first, then `system_profiler` fallback)
    /// and caches the result across launches. `completion` runs on the main queue
    /// only if the name actually changed.
    static func resolveModelName(_ completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let resolved = ioRegistryProductName().map(formatFriendlyModel)
                ?? marketingName().map(formatFriendlyModel)
                ?? coarseModelFamily()

            cacheLock.lock()
            let changed = (resolved != cachedModel)
            cachedModel = resolved
            cacheLock.unlock()

            UserDefaults.standard.set(resolved, forKey: Config.Key.cachedMacModel)
            guard changed else { return }
            DispatchQueue.main.async { completion(resolved) }
        }
    }

    /// Reads `"product-name"` directly from `IODeviceTree:/product` (instant on Apple Silicon,
    /// e.g. `"MacBook Air (13-inch, M5)"`, without spawning any subprocess).
    private static func ioRegistryProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        guard let prop = IORegistryEntryCreateCFProperty(
            entry, "product-name" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else {
            return nil
        }

        let nullTrim = CharacterSet(charactersIn: "\0 \n\r\t")
        if let data = prop as? Data, let str = String(data: data, encoding: .utf8) {
            let trimmed = str.trimmingCharacters(in: nullTrim)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let str = prop as? String {
            let trimmed = str.trimmingCharacters(in: nullTrim)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Reads "Model Name" out of `system_profiler SPHardwareDataType`.
    private static func marketingName() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPHardwareDataType"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("Model Name:") else { continue }
                let name = trimmed.dropFirst("Model Name:".count)
                    .trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
        } catch {
            return nil
        }
        return nil
    }

    /// A fast, coarse family name from the `hw.model` identifier, so there is
    /// always something to show before `system_profiler` returns.
    ///
    /// Apple-silicon machines report an opaque `MacN,N` that carries no family,
    /// so those fall through to the generic "Mac" until the resolver runs.
    private static func coarseModelFamily() -> String {
        let identifier = hardwareIdentifier().lowercased()
        let families = [
            ("macbookpro", "MacBook Pro"),
            ("macbookair", "MacBook Air"),
            ("macbook",    "MacBook"),
            ("macmini",    "Mac mini"),
            ("macstudio",  "Mac Studio"),
            ("macpro",     "Mac Pro"),
            ("imac",       "iMac"),
        ]
        return families.first { identifier.hasPrefix($0.0) }?.1 ?? "Mac"
    }

    private static func hardwareIdentifier() -> String {
        sysctlString("hw.model") ?? ""
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
