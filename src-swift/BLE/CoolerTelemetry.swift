import Foundation

/// A unified telemetry frame from any supported cooler's notification or polling channel.
struct CoolerTelemetry: Equatable {
    /// Cold plate temperature in °C — the face against the Mac (signed integer).
    let coldC: Int

    /// Hot side temperature in °C — the fin stack the fan exhausts through.
    let hotC: Int

    /// Ambient temperature in °C (if reported by hardware, else 0).
    let ambientC: Int

    /// Fan speed in RPM (absent on some older models/firmware).
    let fanRPM: Int?

    /// Live power draw in whole Watts (reported by devices such as Black Shark 6 Max).
    let watts: Int?

    /// USB-PD input voltage/power tier reported by Black Shark 6 Max (`< 12` indicates < 30W supply).
    let inputVoltsTier: Int?

    init(
        coldC: Int,
        hotC: Int,
        ambientC: Int,
        fanRPM: Int?,
        watts: Int? = nil,
        inputVoltsTier: Int? = nil
    ) {
        self.coldC = coldC
        self.hotC = hotC
        self.ambientC = ambientC
        self.fanRPM = fanRPM
        self.watts = watts
        self.inputVoltsTier = inputVoltsTier
    }
}
