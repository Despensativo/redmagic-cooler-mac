import Foundation
import IOKit

/// Sudoless hardware frequency telemetry monitor for Apple Silicon (CPU P/E clusters and GPU).
///
/// Discovers Dynamic Voltage and Frequency Scaling (DVFS) operating points from IODeviceTree (`pmgr`),
/// and samples core residency deltas via macOS private `libIOReport.dylib`.
/// Computes real-time weighted average operating clock frequencies in MHz.
public final class FrequencyMonitor {

    public static let shared = FrequencyMonitor()

    public struct Reading: Equatable {
        public var cpuMHz: Int
        public var gpuMHz: Int
        public var pCpuMHz: Int
        public var eCpuMHz: Int

        public var cpuFormatted: String {
            FrequencyMonitor.formatFreq(cpuMHz)
        }

        public var gpuFormatted: String {
            FrequencyMonitor.formatFreq(gpuMHz)
        }
    }

    public static func formatFreq(_ mhz: Int) -> String {
        guard mhz > 0 else { return "" }
        if mhz >= 1000 {
            return String(format: "%.1f GHz", Double(mhz) / 1000.0)
        }
        return "\(mhz) MHz"
    }

    private var eCpuFreqs: [UInt32] = []
    private var pCpuFreqs: [UInt32] = []
    private var gpuFreqs: [UInt32] = []

    // Function pointers to libIOReport.dylib
    private typealias IOReportCopyChannelsInGroupFunc = @convention(c) (CFString?, CFString?, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias IOReportCreateSubscriptionFunc = @convention(c) (UnsafeMutableRawPointer?, CFDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias IOReportCreateSamplesFunc = @convention(c) (UnsafeMutableRawPointer, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IOReportCreateSamplesDeltaFunc = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IOReportIterateFunc = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Int32
    private typealias IOReportChannelGetChannelNameFunc = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IOReportStateGetCountFunc = @convention(c) (CFDictionary) -> UInt32
    private typealias IOReportStateGetResidencyFunc = @convention(c) (CFDictionary, UInt32) -> UInt64

    private var copyChannels: IOReportCopyChannelsInGroupFunc?
    private var createSub: IOReportCreateSubscriptionFunc?
    private var createSamples: IOReportCreateSamplesFunc?
    private var createDelta: IOReportCreateSamplesDeltaFunc?
    private var iterate: IOReportIterateFunc?
    private var getChannelName: IOReportChannelGetChannelNameFunc?
    private var stateGetCount: IOReportStateGetCountFunc?
    private var stateGetResidency: IOReportStateGetResidencyFunc?

    private var cpuSub: UnsafeMutableRawPointer?
    private var cpuChannels: CFDictionary?
    private var prevCpuSample: CFDictionary?

    private var gpuSub: UnsafeMutableRawPointer?
    private var gpuChannels: CFDictionary?
    private var prevGpuSample: CFDictionary?

    public private(set) var current: Reading = Reading(cpuMHz: 0, gpuMHz: 0, pCpuMHz: 0, eCpuMHz: 0)

    public init() {
        loadLibIOReport()
        loadDvfsTables()
        setupSubscriptions()
    }

    private func loadLibIOReport() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        if let sym = dlsym(lib, "IOReportCopyChannelsInGroup") {
            copyChannels = unsafeBitCast(sym, to: IOReportCopyChannelsInGroupFunc.self)
        }
        if let sym = dlsym(lib, "IOReportCreateSubscription") {
            createSub = unsafeBitCast(sym, to: IOReportCreateSubscriptionFunc.self)
        }
        if let sym = dlsym(lib, "IOReportCreateSamples") {
            createSamples = unsafeBitCast(sym, to: IOReportCreateSamplesFunc.self)
        }
        if let sym = dlsym(lib, "IOReportCreateSamplesDelta") {
            createDelta = unsafeBitCast(sym, to: IOReportCreateSamplesDeltaFunc.self)
        }
        if let sym = dlsym(lib, "IOReportIterate") {
            iterate = unsafeBitCast(sym, to: IOReportIterateFunc.self)
        }
        if let sym = dlsym(lib, "IOReportChannelGetChannelName") {
            getChannelName = unsafeBitCast(sym, to: IOReportChannelGetChannelNameFunc.self)
        }
        if let sym = dlsym(lib, "IOReportStateGetCount") {
            stateGetCount = unsafeBitCast(sym, to: IOReportStateGetCountFunc.self)
        }
        if let sym = dlsym(lib, "IOReportStateGetResidency") {
            stateGetResidency = unsafeBitCast(sym, to: IOReportStateGetResidencyFunc.self)
        }
    }

    private func loadDvfsTables() {
        var iter: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, "IODeviceTree", IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return }
        var entry: io_object_t = 0
        while true {
            entry = IOIteratorNext(iter)
            if entry == 0 { break }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &name)
            if String(cString: name) == "pmgr" {
                var props: Unmanaged<CFMutableDictionary>? = nil
                if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
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
            IOObjectRelease(entry)
        }
        IOObjectRelease(iter)
    }

    private func setupSubscriptions() {
        guard let copyChannels, let createSub, let createSamples else { return }

        if let ch = copyChannels("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0)?.takeRetainedValue() {
            var subDict: Unmanaged<CFMutableDictionary>? = nil
            if let s = createSub(nil, ch, &subDict, 0, nil) {
                cpuSub = s
                cpuChannels = ch
                prevCpuSample = createSamples(s, ch, nil)?.takeRetainedValue()
            }
        }

        if let gch = copyChannels("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0)?.takeRetainedValue() {
            var subDict: Unmanaged<CFMutableDictionary>? = nil
            if let s = createSub(nil, gch, &subDict, 0, nil) {
                gpuSub = s
                gpuChannels = gch
                prevGpuSample = createSamples(s, gch, nil)?.takeRetainedValue()
            }
        }
    }

    @discardableResult
    public func sample() -> Reading {
        guard let createSamples, let createDelta, let iterate,
              let getChannelName, let stateGetCount, let stateGetResidency else {
            return current
        }

        var pWeighted: UInt64 = 0, pTime: UInt64 = 0
        var eWeighted: UInt64 = 0, eTime: UInt64 = 0

        if let sub = cpuSub, let ch = cpuChannels, let prev = prevCpuSample {
            if let current = createSamples(sub, ch, nil)?.takeRetainedValue() {
                if let delta = createDelta(prev, current, nil)?.takeRetainedValue() {
                    _ = iterate(delta) { channel in
                        let name = getChannelName(channel)?.takeUnretainedValue() as String? ?? ""
                        let isP = name.hasPrefix("PCPU")
                        let isE = name.hasPrefix("ECPU")
                        guard isP || isE else { return 0 }
                        let freqs = isP ? self.pCpuFreqs : self.eCpuFreqs
                        let count = Int(stateGetCount(channel))
                        for i in 1..<count {
                            let fIdx = i - 1
                            guard fIdx < freqs.count else { break }
                            let freq = UInt64(freqs[fIdx])
                            let residency = stateGetResidency(channel, UInt32(i))
                            if isP {
                                pWeighted += residency * freq
                                pTime += residency
                            } else {
                                eWeighted += residency * freq
                                eTime += residency
                            }
                        }
                        return 0
                    }
                }
                prevCpuSample = current
            }
        }

        var gWeighted: UInt64 = 0, gTime: UInt64 = 0

        if let sub = gpuSub, let ch = gpuChannels, let prev = prevGpuSample {
            if let current = createSamples(sub, ch, nil)?.takeRetainedValue() {
                if let delta = createDelta(prev, current, nil)?.takeRetainedValue() {
                    _ = iterate(delta) { channel in
                        let count = Int(stateGetCount(channel))
                        for i in 1..<count {
                            let fIdx = i - 1
                            guard fIdx < self.gpuFreqs.count else { break }
                            let freq = UInt64(self.gpuFreqs[fIdx])
                            let residency = stateGetResidency(channel, UInt32(i))
                            gWeighted += residency * freq
                            gTime += residency
                        }
                        return 0
                    }
                }
                prevGpuSample = current
            }
        }

        let pCpuMHz = pTime > 0 ? Int(pWeighted / pTime) : current.pCpuMHz
        let eCpuMHz = eTime > 0 ? Int(eWeighted / eTime) : current.eCpuMHz
        let totalCpuTime = pTime + eTime
        let cpuMHz = totalCpuTime > 0 ? Int((pWeighted + eWeighted) / totalCpuTime) : max(pCpuMHz, eCpuMHz)
        let gpuMHz = gTime > 0 ? Int(gWeighted / gTime) : current.gpuMHz

        current = Reading(
            cpuMHz: cpuMHz,
            gpuMHz: gpuMHz,
            pCpuMHz: pCpuMHz,
            eCpuMHz: eCpuMHz
        )
        return current
    }
}
