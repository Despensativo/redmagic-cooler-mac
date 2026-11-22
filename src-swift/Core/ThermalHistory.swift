import Foundation

/// Rolling-window thermal statistics for a single hardware sensor category.
struct ThermalStats: Equatable {
    let current: Double
    let min: Double
    let avg: Double
    let max: Double
}

/// Immutable snapshot of rolling thermal statistics across all tracked Mac subsystems.
struct ThermalHistorySnapshot: Equatable {
    /// Configured window duration in whole minutes (e.g. 10).
    let windowMinutes: Int
    /// Number of valid samples currently inside the rolling window.
    let sampleCount: Int

    let die: ThermalStats?
    let cpu: ThermalStats?
    let gpu: ThermalStats?
    let battery: ThermalStats?
    let storage: ThermalStats?

    var hasComponentRows: Bool {
        cpu != nil || gpu != nil || battery != nil || storage != nil
    }
}

/// Tracks a rolling time window (default: 10 minutes / 600 seconds) of thermal samples
/// across CPU, GPU, Battery, SSD, and the effective driving Die temperature.
///
/// Designed for 1 Hz polling: 600 samples occupy ~48 KB and compute exact rolling
/// Min / Avg / Max in microseconds with zero drift from brief transient spikes.
final class ThermalHistory {

    private struct Sample {
        let timestamp: TimeInterval
        let die: Double?
        let cpu: Double?
        let gpu: Double?
        let battery: Double?
        let storage: Double?
    }

    let windowSeconds: TimeInterval
    private var samples: [Sample] = []

    /// Minimum spacing between distinct appended samples so rapid back-to-back refreshes
    /// within the same second update the latest sample instead of skewing time averages.
    private static let minSampleSpacing: TimeInterval = 0.5

    init(windowSeconds: TimeInterval = Config.Timing.thermalHistoryWindow) {
        self.windowSeconds = max(1.0, windowSeconds)
    }

    /// Appends a new thermal reading and prunes samples older than `windowSeconds`.
    func record(_ reading: ThermalMonitor.Reading,
                now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        // Protect against wall-clock jumps backwards (e.g. NTP sync):
        // if `now` precedes the newest recorded timestamp, clear stale future samples.
        if let last = samples.last, now < last.timestamp {
            samples.removeAll(keepingCapacity: true)
        }

        let entry = Sample(
            timestamp: now,
            die: reading.dieTemperatureC,
            cpu: reading.cpuTempC,
            gpu: reading.gpuTempC,
            battery: reading.batteryTempC,
            storage: reading.storageTempC
        )

        if let last = samples.last, (now - last.timestamp) < Self.minSampleSpacing {
            samples[samples.count - 1] = entry
        } else {
            samples.append(entry)
        }

        prune(now: now)
    }

    /// Clears all accumulated samples.
    func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Computes a consistent snapshot of Current / Min / Avg / Max over the rolling window.
    func snapshot(now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> ThermalHistorySnapshot {
        prune(now: now)

        return ThermalHistorySnapshot(
            windowMinutes: max(1, Int((windowSeconds / 60.0).rounded())),
            sampleCount: samples.count,
            die: stats(for: \.die),
            cpu: stats(for: \.cpu),
            gpu: stats(for: \.gpu),
            battery: stats(for: \.battery),
            storage: stats(for: \.storage)
        )
    }

    // ── Internals ────────────────────────────────────────────────────────────

    private func prune(now: TimeInterval) {
        let cutoff = now - windowSeconds
        if let firstValidIndex = samples.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstValidIndex > 0 {
                samples.removeFirst(firstValidIndex)
            }
        } else if !samples.isEmpty {
            samples.removeAll(keepingCapacity: true)
        }

        // Hard safety cap against pathological call rates
        let maxCount = Int(windowSeconds * 2) + 60
        if samples.count > maxCount {
            samples.removeFirst(samples.count - maxCount)
        }
    }

    private func stats(for keyPath: KeyPath<Sample, Double?>) -> ThermalStats? {
        var minVal = Double.greatestFiniteMagnitude
        var maxVal = -Double.greatestFiniteMagnitude
        var sum = 0.0
        var count = 0
        var latest: Double?

        for sample in samples {
            guard let val = sample[keyPath: keyPath], val.isFinite else { continue }
            if val < minVal { minVal = val }
            if val > maxVal { maxVal = val }
            sum += val
            count += 1
            latest = val
        }

        guard count > 0, let current = latest else { return nil }
        return ThermalStats(
            current: current,
            min: minVal,
            avg: sum / Double(count),
            max: maxVal
        )
    }
}
