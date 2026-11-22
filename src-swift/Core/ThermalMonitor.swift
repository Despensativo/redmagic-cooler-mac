import Foundation
import IOKit

/// Reads Apple-silicon die temperatures (CPU, GPU, SoC, Battery, Storage) and macOS thermal pressure.
///
/// Binds the private `IOHIDEventSystemClient` symbols out of IOKit once and maintains a persistent
/// client and classified service cache. This avoids the XPC thrashing and CPU overhead of tearing down
/// and recreating IOHID client connections on every 1 Hz polling cycle.
///
/// Reports both component temperatures and an effective driving die temperature (`max(cpu, gpu)`)
/// so the Autopilot and Safety Governor respond proportionally to GPU-heavy workloads (local LLMs,
/// Metal compute, 3D rendering) just as effectively as CPU workloads.
enum ThermalMonitor {

    /// `kIOHIDEventTypeTemperature`.
    private static let temperatureEventType: Int64 = 15

    /// HID usage page/usage that selects the SoC's thermal sensors.
    private static let sensorMatch =
        ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary

    /// Plausibility window for a die reading, in °C. Sensors occasionally
    /// return 0 or a garbage spike; those samples are dropped.
    private static let plausibleRange: ClosedRange<Double> = 1...130

    // ── Private IOKit binding ────────────────────────────────────────────────

    private typealias CreateFn = @convention(c) (CFAllocator?, UInt32) -> Unmanaged<AnyObject>?
    private typealias MatchFn  = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias ServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValueFn = @convention(c) (AnyObject, Int64) -> Double
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    private struct HIDSymbols {
        let create: CreateFn
        let setMatching: MatchFn
        let copyServices: ServicesFn
        let copyEvent: CopyEventFn
        let floatValue: FloatValueFn
        let copyProperty: CopyPropertyFn
    }

    /// Resolved once on first use. `nil` when the private symbols are missing,
    /// which permanently disables die-temperature reporting for this run.
    private static let symbols: HIDSymbols? = {
        guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            return nil
        }
        func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(lib, name) }

        guard let create = sym("IOHIDEventSystemClientCreate"),
              let match = sym("IOHIDEventSystemClientSetMatching"),
              let services = sym("IOHIDEventSystemClientCopyServices"),
              let event = sym("IOHIDServiceClientCopyEvent"),
              let fval = sym("IOHIDEventGetFloatValue"),
              let prop = sym("IOHIDServiceClientCopyProperty") else {
            EventLogger.record("thermal — private IOKit symbols unavailable; die temperature disabled")
            return nil
        }
        return HIDSymbols(
            create: unsafeBitCast(create, to: CreateFn.self),
            setMatching: unsafeBitCast(match, to: MatchFn.self),
            copyServices: unsafeBitCast(services, to: ServicesFn.self),
            copyEvent: unsafeBitCast(event, to: CopyEventFn.self),
            floatValue: unsafeBitCast(fval, to: FloatValueFn.self),
            copyProperty: unsafeBitCast(prop, to: CopyPropertyFn.self)
        )
    }()

    // ── Persistent IOKit Client & Service Cache ──────────────────────────────

    private final class ClientCache {
        let client: AnyObject
        let cpuServices: [AnyObject]
        let gpuServices: [AnyObject]
        let socServices: [AnyObject]
        let batteryServices: [AnyObject]
        let storageServices: [AnyObject]

        init?(symbols: HIDSymbols) {
            guard let clientRef = symbols.create(kCFAllocatorDefault, 0) else { return nil }
            let client = clientRef.takeRetainedValue()
            symbols.setMatching(client, sensorMatch)

            guard let servicesRef = symbols.copyServices(client) else { return nil }
            let sList = servicesRef.takeRetainedValue() as [AnyObject]

            var cpu: [AnyObject] = []
            var gpu: [AnyObject] = []
            var soc: [AnyObject] = []
            var bat: [AnyObject] = []
            var ssd: [AnyObject] = []

            for s in sList {
                guard let nameRef = symbols.copyProperty(s, "Product" as CFString),
                      let name = nameRef.takeRetainedValue() as? String else { continue }
                let n = name.lowercased()
                if name.hasPrefix("PMU tdie") {
                    cpu.append(s)
                } else if name.hasPrefix("PMU2 tdie") {
                    gpu.append(s)
                } else if name.hasPrefix("PMU") {
                    soc.append(s)
                } else if n.contains("battery") || n.contains("gas gauge") {
                    bat.append(s)
                } else if n.contains("nand") || n.contains("ssd") {
                    ssd.append(s)
                }
            }

            self.client = client
            self.cpuServices = cpu
            self.gpuServices = gpu
            self.socServices = soc
            self.batteryServices = bat
            self.storageServices = ssd
        }
    }

    private static var activeCache: ClientCache?

    private static func getOrCreateCache(symbols: HIDSymbols) -> ClientCache? {
        if let existing = activeCache {
            return existing
        }
        let created = ClientCache(symbols: symbols)
        activeCache = created
        return created
    }

    /// Resets the persistent IOHID client (e.g. after system wake from sleep).
    static func invalidateCache() {
        activeCache = nil
    }

    // ── Public API ───────────────────────────────────────────────────────────

    struct Reading {
        /// macOS's own thermal pressure level — always available.
        let thermalState: ThermalState
        /// Effective die temperature in °C driving the Autopilot, safety governor and UI.
        /// Evaluated as max(cpuTempC, gpuTempC) on Apple Silicon, ensuring GPU-intensive
        /// tasks (AI inference, Metal rendering, 3D viewports) trigger cooling proportionally.
        let dieTemperatureC: Double?

        /// Mean temperatures by hardware category (°C):
        let cpuTempC: Double?
        let gpuTempC: Double?
        let socTempC: Double?
        let batteryTempC: Double?
        let storageTempC: Double?

        /// Peak/hottest single sensor temperature across all active CPU and GPU dies:
        let peakDieTempC: Double?

        init(thermalState: ThermalState,
             dieTemperatureC: Double?,
             cpuTempC: Double? = nil,
             gpuTempC: Double? = nil,
             socTempC: Double? = nil,
             batteryTempC: Double? = nil,
             storageTempC: Double? = nil,
             peakDieTempC: Double? = nil) {
            self.thermalState = thermalState
            self.dieTemperatureC = dieTemperatureC
            self.cpuTempC = cpuTempC
            self.gpuTempC = gpuTempC
            self.socTempC = socTempC
            self.batteryTempC = batteryTempC
            self.storageTempC = storageTempC
            self.peakDieTempC = peakDieTempC
        }
    }

    /// Samples all hardware thermal signals. Cheap and cached for 1 Hz polling.
    static func read() -> Reading {
        let state = ThermalState(ProcessInfo.processInfo.thermalState)
        guard let hid = symbols, let cache = getOrCreateCache(symbols: hid) else {
            return Reading(thermalState: state, dieTemperatureC: nil)
        }

        let (cpuAvg, cpuPeak) = averageAndPeak(for: cache.cpuServices, symbols: hid)
        let (gpuAvg, gpuPeak) = averageAndPeak(for: cache.gpuServices, symbols: hid)
        let (socAvg, _)       = averageAndPeak(for: cache.socServices, symbols: hid)
        let (batAvg, _)       = averageAndPeak(for: cache.batteryServices, symbols: hid)
        let (ssdAvg, _)       = averageAndPeak(for: cache.storageServices, symbols: hid)

        // Effective die temperature driving the Autopilot:
        let effectiveDie: Double?
        if let cpu = cpuAvg, let gpu = gpuAvg {
            effectiveDie = max(cpu, gpu)
        } else {
            effectiveDie = cpuAvg ?? gpuAvg
        }

        // Peak sensor across CPU and GPU:
        let peakDie: Double?
        if let cp = cpuPeak, let gp = gpuPeak {
            peakDie = max(cp, gp)
        } else {
            peakDie = cpuPeak ?? gpuPeak
        }

        return Reading(
            thermalState: state,
            dieTemperatureC: effectiveDie,
            cpuTempC: cpuAvg,
            gpuTempC: gpuAvg,
            socTempC: socAvg,
            batteryTempC: batAvg,
            storageTempC: ssdAvg,
            peakDieTempC: peakDie
        )
    }

    private static func averageAndPeak(for services: [AnyObject], symbols: HIDSymbols) -> (avg: Double?, peak: Double?) {
        guard !services.isEmpty else { return (nil, nil) }
        var sum = 0.0
        var count = 0
        var peak: Double? = nil

        for service in services {
            guard let eventRef = symbols.copyEvent(service, temperatureEventType, 0, 0) else { continue }
            let celsius = symbols.floatValue(eventRef.takeRetainedValue(), temperatureEventType << 16)
            guard plausibleRange.contains(celsius) else { continue }

            sum += celsius
            count += 1
            if peak == nil || celsius > peak! {
                peak = celsius
            }
        }
        return count > 0 ? (sum / Double(count), peak) : (nil, nil)
    }
}
