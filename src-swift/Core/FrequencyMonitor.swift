import Foundation
import IOKit

/// Sudoless hardware telemetry monitor for Apple Silicon:
/// - CPU (E/P clusters) & GPU weighted clock frequencies via IOReport + IODeviceTree DVFS (`pmgr`)
/// - Apple Neural Engine (ANE) activity, duty residency, voltage/bandwidth floor, and fabric bandwidth via `PMP` IOReport
public final class FrequencyMonitor {

    public static let shared = FrequencyMonitor()

    public enum ANEPowerFloor: Int, Comparable {
        case vmin = 0
        case vnom = 1
        case vmax = 2
        case vovd = 3
        case vovd2 = 4

        public static func < (lhs: ANEPowerFloor, rhs: ANEPowerFloor) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var label: String {
            switch self {
            case .vmin: return "Repouso"
            case .vnom: return "Normal"
            case .vmax: return "Alto"
            case .vovd, .vovd2: return "Máx"
            }
        }

        public var rawFloorName: String {
            switch self {
            case .vmin: return "VMIN"
            case .vnom: return "VNOM"
            case .vmax: return "VMAX"
            case .vovd: return "VOVD"
            case .vovd2: return "VOVD2"
            }
        }

        public init(stateName: String) {
            switch stateName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
            case "VNOM": self = .vnom
            case "VMAX": self = .vmax
            case "VOVD": self = .vovd
            case "VOVD2": self = .vovd2
            default: self = .vmin
            }
        }
    }

    public struct ANEReading: Equatable {
        public var isSupported: Bool
        public var isActive: Bool
        public var activePercent: Double
        public var peakFloor: ANEPowerFloor
        public var peakBandwidthGBs: Int
        public var recentMaxActivePercent: Double = 0
        public var recentPeakBandwidthGBs: Int = 0

        public init(
            isSupported: Bool,
            isActive: Bool,
            activePercent: Double = 0,
            peakFloor: ANEPowerFloor = .vmin,
            peakBandwidthGBs: Int = 0,
            recentMaxActivePercent: Double = 0,
            recentPeakBandwidthGBs: Int = 0
        ) {
            self.isSupported = isSupported
            self.isActive = isActive
            self.activePercent = activePercent
            self.peakFloor = peakFloor
            self.peakBandwidthGBs = peakBandwidthGBs
            self.recentMaxActivePercent = recentMaxActivePercent
            self.recentPeakBandwidthGBs = recentPeakBandwidthGBs
        }
    }

    public struct Reading: Equatable {
        public var cpuMHz: Int
        public var gpuMHz: Int
        public var pCpuMHz: Int
        public var eCpuMHz: Int
        public var maxCpuMHz: Int
        public var maxGpuMHz: Int
        public var ane: ANEReading?

        public var cpuFormatted: String {
            FrequencyMonitor.formatFreq(cpuMHz)
        }

        public var gpuFormatted: String {
            FrequencyMonitor.formatFreq(gpuMHz)
        }

        public var cpuWithMaxFormatted: String {
            FrequencyMonitor.formatCurrentWithMax(currentMHz: cpuMHz, maxMHz: maxCpuMHz)
        }

        public var gpuWithMaxFormatted: String {
            FrequencyMonitor.formatCurrentWithMax(currentMHz: gpuMHz, maxMHz: maxGpuMHz)
        }
    }

    public static func formatFreq(_ mhz: Int) -> String {
        guard mhz > 0 else { return "" }
        if mhz >= 1000 {
            return String(format: "%.1f GHz", Double(mhz) / 1000.0)
        }
        return "\(mhz) MHz"
    }

    public static func formatCurrentWithMax(currentMHz: Int, maxMHz: Int) -> String {
        guard currentMHz > 0 else {
            return maxMHz > 0 ? "Máx \(formatFreq(maxMHz))" : ""
        }
        guard maxMHz > 0 else {
            return formatFreq(currentMHz)
        }

        if currentMHz >= 1000 && maxMHz >= 1000 {
            let curG = Double(currentMHz) / 1000.0
            let maxG = Double(maxMHz) / 1000.0
            return String(format: "%.1f / %.1f GHz", curG, maxG)
        } else if currentMHz < 1000 && maxMHz >= 1000 {
            let maxG = Double(maxMHz) / 1000.0
            return String(format: "%d MHz / %.1f GHz", currentMHz, maxG)
        } else {
            return "\(currentMHz) / \(maxMHz) MHz"
        }
    }

    public static func formatANEPercent(_ percent: Double) -> String {
        guard percent > 0 else { return "0%" }
        if percent < 1.0 { return "<1%" }
        return "\(Int(min(100.0, percent.rounded())))%"
    }

    public static func formatANEStatus(_ reading: ANEReading) -> String {
        if reading.isActive {
            var parts = ["Ativo"]
            if reading.activePercent > 0 {
                parts.append(formatANEPercent(reading.activePercent))
            }
            if reading.peakFloor > .vmin {
                parts.append(reading.peakFloor.label)
            }
            if reading.peakBandwidthGBs > 0 {
                parts.append("\(reading.peakBandwidthGBs) GB/s")
            }
            return parts.joined(separator: " · ")
        }

        if reading.recentPeakBandwidthGBs > 0 {
            return "Ocioso · Pico \(reading.recentPeakBandwidthGBs) GB/s"
        }
        if reading.recentMaxActivePercent > 0 {
            return "Ocioso · Pico \(formatANEPercent(reading.recentMaxActivePercent))"
        }
        return "Ocioso"
    }

    /// Parses `"  32GB/s"` / `"64 GB/s"` state labels exposed by `PMP` bandwidth channels.
    public static func parseBandwidthGBs(_ stateName: String) -> Int? {
        let trimmed = stateName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasSuffix("GB/S") else { return nil }
        let numberPart = trimmed.dropLast(4).trimmingCharacters(in: .whitespaces)
        return Int(numberPart)
    }

    /// Computes instantaneous ANE activity from IOReport `PMP` state histograms, with optional
    /// `H11ANEIn` driver power fallback when `PMP` counters are unavailable on older chips.
    public static func summarizeANE(
        floorStates: [(name: String, residency: UInt64)],
        niStates: [(name: String, residency: UInt64)],
        afStates: [(name: String, residency: UInt64)],
        hasDriverFallbackActive: Bool = false,
        isSupported: Bool = true
    ) -> ANEReading {
        guard isSupported else {
            return ANEReading(isSupported: false, isActive: false)
        }

        var vminTicks: UInt64 = 0
        var activeTicks: UInt64 = 0
        var peakFloor: ANEPowerFloor = .vmin

        for (index, state) in floorStates.enumerated() where state.residency > 0 {
            let floor = ANEPowerFloor(stateName: state.name)
            if index == 0 || floor == .vmin {
                vminTicks += state.residency
            } else {
                activeTicks += state.residency
                if floor > peakFloor { peakFloor = floor }
            }
        }

        let totalFloorTicks = vminTicks + activeTicks
        let activePercent = totalFloorTicks > 0
            ? (Double(activeTicks) / Double(totalFloorTicks)) * 100.0
            : 0.0

        // Index 0 in PMP bandwidth histograms (2GB/s on SOC-NI3 ANE UP, 1GB/s on AF BW) represents
        // powered baseline keepalive traffic; count indices >= 1 as genuine workload transfers.
        func peakBandwidth(in states: [(name: String, residency: UInt64)]) -> Int {
            var peak = 0
            for (index, state) in states.enumerated() where index > 0 && state.residency > 0 {
                if let gb = parseBandwidthGBs(state.name), gb > peak {
                    peak = gb
                }
            }
            return peak
        }

        let niPeak = peakBandwidth(in: niStates)
        let afPeak = peakBandwidth(in: afStates)
        let peakBandwidthGBs = max(niPeak, afPeak)

        let hasPmpSignals = !floorStates.isEmpty || !niStates.isEmpty || !afStates.isEmpty
        let isActive: Bool
        if hasPmpSignals {
            isActive = activePercent > 0.01 || peakFloor > .vmin || peakBandwidthGBs > 0
        } else {
            isActive = hasDriverFallbackActive
        }

        return ANEReading(
            isSupported: true,
            isActive: isActive,
            activePercent: activePercent,
            peakFloor: peakFloor,
            peakBandwidthGBs: peakBandwidthGBs
        )
    }

    public var maxCpuMHz: Int {
        let pMax = pCpuFreqs.max() ?? 0
        let eMax = eCpuFreqs.max() ?? 0
        return Int(max(pMax, eMax))
    }

    public var maxGpuMHz: Int {
        return Int(gpuFreqs.max() ?? 0)
    }

    private var eCpuFreqs: [UInt32] = []
    private var pCpuFreqs: [UInt32] = []
    private var gpuFreqs: [UInt32] = []

    // ── Private libIOReport bindings ─────────────────────────────────────────

    private typealias IOReportCopyChannelsInGroupFunc = @convention(c) (CFString?, CFString?, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias IOReportCreateSubscriptionFunc = @convention(c) (UnsafeMutableRawPointer?, CFDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias IOReportCreateSamplesFunc = @convention(c) (UnsafeMutableRawPointer, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IOReportCreateSamplesDeltaFunc = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IOReportIterateFunc = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Int32
    private typealias IOReportChannelGetSubGroupFunc = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IOReportChannelGetChannelNameFunc = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IOReportChannelGetFormatFunc = @convention(c) (CFDictionary) -> UInt8
    private typealias IOReportStateGetCountFunc = @convention(c) (CFDictionary) -> UInt32
    private typealias IOReportStateGetNameForIndexFunc = @convention(c) (CFDictionary, UInt32) -> Unmanaged<CFString>?
    private typealias IOReportStateGetResidencyFunc = @convention(c) (CFDictionary, UInt32) -> UInt64

    private struct IOReportAPI {
        let copyChannels: IOReportCopyChannelsInGroupFunc
        let createSub: IOReportCreateSubscriptionFunc
        let createSamples: IOReportCreateSamplesFunc
        let createDelta: IOReportCreateSamplesDeltaFunc
        let iterate: IOReportIterateFunc
        let getSubGroup: IOReportChannelGetSubGroupFunc
        let getChannelName: IOReportChannelGetChannelNameFunc
        let getFormat: IOReportChannelGetFormatFunc
        let stateGetCount: IOReportStateGetCountFunc
        let stateGetName: IOReportStateGetNameForIndexFunc
        let stateGetResidency: IOReportStateGetResidencyFunc
    }

    private final class Subscription {
        private let handle: UnsafeMutableRawPointer
        private let channels: CFDictionary
        private var previousSample: CFDictionary?
        private let api: IOReportAPI

        init?(channels: CFDictionary, api: IOReportAPI) {
            var subDict: Unmanaged<CFMutableDictionary>? = nil
            guard let sub = api.createSub(nil, channels, &subDict, 0, nil) else { return nil }
            self.handle = sub
            self.channels = channels
            self.api = api
            self.previousSample = api.createSamples(sub, channels, nil)?.takeRetainedValue()
        }

        func sampleDelta(_ body: (CFDictionary) -> Void) {
            guard let cur = api.createSamples(handle, channels, nil)?.takeRetainedValue() else { return }
            defer { previousSample = cur }
            guard let prev = previousSample,
                  let delta = api.createDelta(prev, cur, nil)?.takeRetainedValue() else { return }
            _ = api.iterate(delta) { channel in
                body(channel)
                return 0
            }
        }
    }

    private var api: IOReportAPI?
    private var cpuSub: Subscription?
    private var gpuSub: Subscription?
    private var aneSub: Subscription?
    private var hasH11ANEService: Bool = false

    // Rolling 10-minute ANE peak history so brief bursts stay visible after completion.
    private struct ANEHistoryEntry {
        let timestamp: TimeInterval
        let activePercent: Double
        let peakBandwidthGBs: Int
    }
    private var aneHistory: [ANEHistoryEntry] = []

    public private(set) var current: Reading = Reading(
        cpuMHz: 0,
        gpuMHz: 0,
        pCpuMHz: 0,
        eCpuMHz: 0,
        maxCpuMHz: 0,
        maxGpuMHz: 0,
        ane: nil
    )

    public init() {
        loadLibIOReport()
        loadDvfsTables()
        detectH11ANEService()
        setupSubscriptions()
        current = Reading(
            cpuMHz: 0,
            gpuMHz: 0,
            pCpuMHz: 0,
            eCpuMHz: 0,
            maxCpuMHz: maxCpuMHz,
            maxGpuMHz: maxGpuMHz,
            ane: initialANEReading()
        )
    }

    private func loadLibIOReport() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        guard let symCopy = dlsym(lib, "IOReportCopyChannelsInGroup"),
              let symSub = dlsym(lib, "IOReportCreateSubscription"),
              let symSamples = dlsym(lib, "IOReportCreateSamples"),
              let symDelta = dlsym(lib, "IOReportCreateSamplesDelta"),
              let symIter = dlsym(lib, "IOReportIterate"),
              let symSubGrp = dlsym(lib, "IOReportChannelGetSubGroup"),
              let symChan = dlsym(lib, "IOReportChannelGetChannelName"),
              let symFmt = dlsym(lib, "IOReportChannelGetFormat"),
              let symCount = dlsym(lib, "IOReportStateGetCount"),
              let symName = dlsym(lib, "IOReportStateGetNameForIndex"),
              let symRes = dlsym(lib, "IOReportStateGetResidency") else { return }

        api = IOReportAPI(
            copyChannels: unsafeBitCast(symCopy, to: IOReportCopyChannelsInGroupFunc.self),
            createSub: unsafeBitCast(symSub, to: IOReportCreateSubscriptionFunc.self),
            createSamples: unsafeBitCast(symSamples, to: IOReportCreateSamplesFunc.self),
            createDelta: unsafeBitCast(symDelta, to: IOReportCreateSamplesDeltaFunc.self),
            iterate: unsafeBitCast(symIter, to: IOReportIterateFunc.self),
            getSubGroup: unsafeBitCast(symSubGrp, to: IOReportChannelGetSubGroupFunc.self),
            getChannelName: unsafeBitCast(symChan, to: IOReportChannelGetChannelNameFunc.self),
            getFormat: unsafeBitCast(symFmt, to: IOReportChannelGetFormatFunc.self),
            stateGetCount: unsafeBitCast(symCount, to: IOReportStateGetCountFunc.self),
            stateGetName: unsafeBitCast(symName, to: IOReportStateGetNameForIndexFunc.self),
            stateGetResidency: unsafeBitCast(symRes, to: IOReportStateGetResidencyFunc.self)
        )
    }

    private func loadDvfsTables() {
        var iter: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, "IODeviceTree", IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }

        var entry: io_object_t = 0
        while true {
            entry = IOIteratorNext(iter)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &name)
            guard String(cString: name) == "pmgr" else { continue }

            var props: Unmanaged<CFMutableDictionary>? = nil
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }

            func parseFreqs(_ key: String) -> [UInt32] {
                guard let data = dict[key] as? Data else { return [] }
                var result: [UInt32] = []
                data.withUnsafeBytes { ptr in
                    let u32s = ptr.bindMemory(to: UInt32.self)
                    for i in stride(from: 0, to: u32s.count, by: 2) {
                        let val = u32s[i]
                        if val > 100_000_000 {
                            result.append(val / 1_000_000)
                        } else if val > 100_000 {
                            result.append(val / 1_000)
                        }
                    }
                }
                return result
            }

            eCpuFreqs = parseFreqs("voltage-states1-sram")
            if eCpuFreqs.isEmpty { eCpuFreqs = parseFreqs("voltage-states1") }

            pCpuFreqs = parseFreqs("voltage-states5-sram")
            if pCpuFreqs.isEmpty { pCpuFreqs = parseFreqs("voltage-states5") }

            gpuFreqs = parseFreqs("voltage-states9")
            if gpuFreqs.isEmpty { gpuFreqs = parseFreqs("voltage-states9-sram") }
        }
    }

    private func detectH11ANEService() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("H11ANEIn"))
        if svc != 0 {
            hasH11ANEService = true
            IOObjectRelease(svc)
        }
    }

    private func isH11ANEPoweredOn() -> Bool {
        guard hasH11ANEService else { return false }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("H11ANEIn"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        guard let pm = IORegistryEntryCreateCFProperty(svc, "IOPowerManagement" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return false }
        return (pm["CurrentPowerState"] as? Int ?? 0) > 0
    }

    private func setupSubscriptions() {
        guard let api else { return }

        if let ch = api.copyChannels("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0)?.takeRetainedValue() {
            cpuSub = Subscription(channels: ch, api: api)
        }

        if let gch = api.copyChannels("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0)?.takeRetainedValue() {
            gpuSub = Subscription(channels: gch, api: api)
        }

        if let pmp = api.copyChannels("PMP" as CFString, nil, 0, 0)?.takeRetainedValue(),
           let filtered = filteredPmpANEChannels(from: pmp) {
            aneSub = Subscription(channels: filtered, api: api)
        }
    }

    private func filteredPmpANEChannels(from pmpDict: CFDictionary) -> CFDictionary? {
        guard let mutable = (pmpDict as NSDictionary).mutableCopy() as? NSMutableDictionary,
              let channels = mutable["IOReportChannels"] as? [[String: Any]] else { return nil }

        let aneOnly = channels.filter { ch in
            let subGroup = ch["IOReportSubGroupName"] as? String ?? ""
            let legend = ch["LegendChannel"] as? [Any]
            let chanName = (legend?.count ?? 0) > 2 ? "\(legend![2])" : ""
            return (subGroup == "SOC Floor" && chanName.hasPrefix("ANE"))
                || (subGroup == "SOC-NI Util BW" && chanName.contains("ANE"))
                || (subGroup == "AF BW" && chanName.hasPrefix("ANE") && chanName.contains("RD+WR"))
        }

        guard !aneOnly.isEmpty else { return nil }
        mutable["IOReportChannels"] = aneOnly
        return mutable as CFDictionary
    }

    private func initialANEReading() -> ANEReading? {
        guard aneSub != nil || hasH11ANEService else { return nil }
        return ANEReading(
            isSupported: true,
            isActive: isH11ANEPoweredOn() && aneSub == nil
        )
    }

    private func readStates(channel: CFDictionary, api: IOReportAPI) -> [(name: String, residency: UInt64)] {
        guard api.getFormat(channel) == 2 else { return [] }
        let count = api.stateGetCount(channel)
        var states: [(name: String, residency: UInt64)] = []
        states.reserveCapacity(Int(count))
        for i in 0..<count {
            let name = api.stateGetName(channel, i)?.takeUnretainedValue() as String? ?? ""
            let residency = api.stateGetResidency(channel, i)
            states.append((name: name, residency: residency))
        }
        return states
    }

    @discardableResult
    public func sample(now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Reading {
        guard let api else { return current }

        var pWeighted: UInt64 = 0, pTime: UInt64 = 0
        var eWeighted: UInt64 = 0, eTime: UInt64 = 0

        cpuSub?.sampleDelta { channel in
            let name = api.getChannelName(channel)?.takeUnretainedValue() as String? ?? ""
            let isP = name.hasPrefix("PCPU")
            let isE = name.hasPrefix("ECPU")
            guard isP || isE else { return }
            let freqs = isP ? self.pCpuFreqs : self.eCpuFreqs
            let count = Int(api.stateGetCount(channel))
            for i in 1..<count {
                let fIdx = i - 1
                guard fIdx < freqs.count else { break }
                let freq = UInt64(freqs[fIdx])
                let residency = api.stateGetResidency(channel, UInt32(i))
                if isP {
                    pWeighted += residency * freq
                    pTime += residency
                } else {
                    eWeighted += residency * freq
                    eTime += residency
                }
            }
        }

        var gWeighted: UInt64 = 0, gTime: UInt64 = 0

        gpuSub?.sampleDelta { channel in
            let count = Int(api.stateGetCount(channel))
            for i in 1..<count {
                let fIdx = i - 1
                guard fIdx < self.gpuFreqs.count else { break }
                let freq = UInt64(self.gpuFreqs[fIdx])
                let residency = api.stateGetResidency(channel, UInt32(i))
                gWeighted += residency * freq
                gTime += residency
            }
        }

        let aneReading = sampleANE(api: api, now: now)

        let pCpuMHz = pTime > 0 ? Int(pWeighted / pTime) : current.pCpuMHz
        let eCpuMHz = eTime > 0 ? Int(eWeighted / eTime) : current.eCpuMHz
        let totalCpuTime = pTime + eTime
        let cpuMHz = totalCpuTime > 0 ? Int((pWeighted + eWeighted) / totalCpuTime) : max(pCpuMHz, eCpuMHz)
        let gpuMHz = gTime > 0 ? Int(gWeighted / gTime) : current.gpuMHz

        current = Reading(
            cpuMHz: cpuMHz,
            gpuMHz: gpuMHz,
            pCpuMHz: pCpuMHz,
            eCpuMHz: eCpuMHz,
            maxCpuMHz: maxCpuMHz,
            maxGpuMHz: maxGpuMHz,
            ane: aneReading
        )
        return current
    }

    private func sampleANE(api: IOReportAPI, now: TimeInterval) -> ANEReading? {
        let supported = aneSub != nil || hasH11ANEService
        guard supported else { return nil }

        var floorStates: [(name: String, residency: UInt64)] = []
        var niStates: [(name: String, residency: UInt64)] = []
        var afStates: [(name: String, residency: UInt64)] = []

        aneSub?.sampleDelta { channel in
            let subGroup = api.getSubGroup(channel)?.takeUnretainedValue() as String? ?? ""
            let chanName = api.getChannelName(channel)?.takeUnretainedValue() as String? ?? ""

            if subGroup == "SOC Floor" && chanName.hasPrefix("ANE") {
                let parsed = self.readStates(channel: channel, api: api)
                // Prefer ANE-AF-BW if multiple SOC Floor ANE channels exist
                if chanName == "ANE-AF-BW" || floorStates.isEmpty {
                    floorStates = parsed
                }
            } else if subGroup == "SOC-NI Util BW" && chanName.contains("ANE") {
                niStates = self.readStates(channel: channel, api: api)
            } else if subGroup == "AF BW" && chanName.hasPrefix("ANE") {
                afStates = self.readStates(channel: channel, api: api)
            }
        }

        let fallbackActive = (aneSub == nil) ? isH11ANEPoweredOn() : false
        var reading = Self.summarizeANE(
            floorStates: floorStates,
            niStates: niStates,
            afStates: afStates,
            hasDriverFallbackActive: fallbackActive,
            isSupported: true
        )

        recordANEHistory(reading, now: now)
        let (maxPct, maxBW) = recentANEPeaks(now: now)
        reading.recentMaxActivePercent = maxPct
        reading.recentPeakBandwidthGBs = maxBW
        return reading
    }

    private func recordANEHistory(_ reading: ANEReading, now: TimeInterval) {
        if let last = aneHistory.last, now < last.timestamp {
            aneHistory.removeAll(keepingCapacity: true)
        }
        if reading.isActive {
            let entry = ANEHistoryEntry(
                timestamp: now,
                activePercent: reading.activePercent,
                peakBandwidthGBs: reading.peakBandwidthGBs
            )
            if let last = aneHistory.last, (now - last.timestamp) < 0.5 {
                aneHistory[aneHistory.count - 1] = ANEHistoryEntry(
                    timestamp: now,
                    activePercent: max(last.activePercent, entry.activePercent),
                    peakBandwidthGBs: max(last.peakBandwidthGBs, entry.peakBandwidthGBs)
                )
            } else {
                aneHistory.append(entry)
            }
        }
        pruneANEHistory(now: now)
    }

    private func pruneANEHistory(now: TimeInterval) {
        let cutoff = now - Config.Timing.thermalHistoryWindow
        if let firstValid = aneHistory.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstValid > 0 { aneHistory.removeFirst(firstValid) }
        } else if !aneHistory.isEmpty {
            aneHistory.removeAll(keepingCapacity: true)
        }

        let maxCount = Int(Config.Timing.thermalHistoryWindow * 2) + 60
        if aneHistory.count > maxCount {
            aneHistory.removeFirst(aneHistory.count - maxCount)
        }
    }

    private func recentANEPeaks(now: TimeInterval) -> (maxPercent: Double, maxBandwidthGBs: Int) {
        pruneANEHistory(now: now)
        var maxPct = 0.0
        var maxBW = 0
        for entry in aneHistory {
            if entry.activePercent > maxPct { maxPct = entry.activePercent }
            if entry.peakBandwidthGBs > maxBW { maxBW = entry.peakBandwidthGBs }
        }
        return (maxPct, maxBW)
    }
}
