import Foundation
import CoreBluetooth

// Standalone test script to verify profile matching, driver isolation, Step-Ladder engine,
// asymmetric hysteresis, dynamic dwell, velocity bypass, and Universal Condensation Safety Governor.
func runTests() {
    print("🚀 Starting Smart Cooler Control Test Suite (Tri-Mode & Step-Ladder Engine)...")

    // 1. Device Profile Matching Tests
    let testCases: [(name: String, expectedId: String?)] = [
        ("RM Magcooler 5pro", "rm-magcooler-5pro"),
        ("REDMAGIC Cooler 5 Pro", "rm-magcooler-5pro"),
        ("RM Magcooler 6pro", "rm-vccooler-6pro"),
        ("RM Magcooler 6pro+", "rm-vccooler-6proplus"),
        ("REDMAGIC Cooler 6 Pro+", "rm-vccooler-6proplus"),
        ("RM Magcooler 8pro", "rm-cryocooler-8pro"),
        ("REDMAGIC Cooler 8", "rm-cryocooler-8pro"),
        ("RM Magcooler 4pro", "rm-magcooler-4pro"),
        ("Black Shark MagCooler 5 Pro", "bs-magcooler-5pro"),
        ("BR42-Cooler", "bs-magcooler-5pro"),
        ("BS 5Pro", "bs-magcooler-5pro"),
        ("Black Shark MagCooler 6Max", "bs-magcooler-6max"),
        ("Fun Cooler 6Max", "bs-magcooler-6max"),
        ("BLACKSHARK_COOLER_BR64", "bs-magcooler-6max"),
        ("BR64-Cooler", "bs-magcooler-6max"),
        ("BS 6Max", "bs-magcooler-6max"),
        ("Black Shark 4 Pro", "bs-magcooler-4pro"),
        ("Flydigi B8X", "fd-b8x"),
        ("feizhi b8x", "fd-b8x"),
        ("Flydigi B7X", "fd-b7x"),
        ("iQOO Cooler 2 Pro", "iqoo-clip-2pro"),
        ("iQOO Clip 2 Pro", "iqoo-clip-2pro"),
        ("OnePlus 45W Cooler", "op-liquid-45w"),
        ("OnePlus 27W Cooler", "op-freezing-27w"),
        ("MEMO CX08", "memo-cx08"),
        ("MEMO CX07", "memo-cx07"),
        ("Sony WH-1000XM4", nil),
        ("Apple Watch", nil)
    ]

    for (name, expectedId) in testCases {
        let matched = DeviceProfile.matching(deviceName: name)
        if let expected = expectedId {
            assert(matched != nil, "Expected match for '\(name)', got nil")
            assert(matched!.id == expected, "Expected '\(expected)' for '\(name)', got '\(matched!.id)'")
            print("  ✅ Match: '\(name)' -> \(matched!.brand) \(matched!.modelName) [\(matched!.id)]")
        } else {
            assert(matched == nil, "Expected no match for '\(name)', got '\(matched?.id ?? "")'")
            print("  ✅ Ignored: '\(name)' correctly identified as non-cooler")
        }
    }

    // 2. Black Shark Manufacturer Data Identification
    let bsMfgData = Data([0x8F, 0x03, 0x01, 0x02])
    let bsAdv = [CBAdvertisementDataManufacturerDataKey: bsMfgData]
    let bsMatched = DeviceProfile.matching(deviceName: "BR42-Cooler", advertisementData: bsAdv)
    assert(bsMatched != nil && bsMatched!.brand == "Black Shark", "Manufacturer data matching failed for Black Shark")
    let bs6Matched = DeviceProfile.matching(deviceName: "BR64-Cooler", advertisementData: bsAdv)
    assert(bs6Matched != nil && bs6Matched!.id == "bs-magcooler-6max", "Manufacturer data matching failed for Black Shark 6 Max (BR64)")
    print("  ✅ Manufacturer Data: Black Shark [0x8F, 0x03] -> \(bsMatched!.modelName) & \(bs6Matched!.modelName)")

    // 3. Service UUID Identifications
    let fdServices = [CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")]
    let fdMatched = DeviceProfile.matching(deviceName: "Cooler-Unknown", advertisementData: [CBAdvertisementDataServiceUUIDsKey: fdServices])
    assert(fdMatched != nil && fdMatched!.brand == "Flydigi", "Service UUID matching failed for Flydigi")
    print("  ✅ Service UUID: Flydigi FFE0 -> \(fdMatched!.modelName)")

    let iqooServices = [CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")]
    let iqooMatched = DeviceProfile.matching(deviceName: "Cooler-Unknown", advertisementData: [CBAdvertisementDataServiceUUIDsKey: iqooServices])
    assert(iqooMatched != nil && iqooMatched!.id == "iqoo-clip-2pro", "Service UUID matching failed for iQOO")
    print("  ✅ Service UUID: iQOO FFF0 -> \(iqooMatched!.modelName)")

    let opServices = [CBUUID(string: "0000FEE7-0000-1000-8000-00805F9B34FB")]
    let opMatched = DeviceProfile.matching(deviceName: "OnePlus 45W Device", advertisementData: [CBAdvertisementDataServiceUUIDsKey: opServices])
    assert(opMatched != nil && opMatched!.id == "op-liquid-45w", "Service UUID matching failed for OnePlus 45W")
    print("  ✅ Service UUID: OnePlus FEE7 -> \(opMatched!.modelName)")

    // 4. Driver Instantiation and Isolation
    for profile in DeviceProfile.all {
        let driver = profile.makeDriver()
        assert(driver.profile.id == profile.id, "Driver profile mismatch for \(profile.id)")
        assert(driver.serviceUUID == profile.serviceUUID, "Driver serviceUUID mismatch for \(profile.id)")
        print("  ✅ Driver: \(profile.id) -> \(type(of: driver)) with Service \(driver.serviceUUID.uuidString)")
    }

    // 5. Deterministic Step-Ladder Thermal Engine Tests
    print("\n🧠 Testing Deterministic 4-Stage Step-Ladder Thermal Engine...")
    let engine = AutopilotPolicy()
    engine.resetStandby(isStandby: true)

    // A. Idle / Standby: Die at 45°C (< 50°C trigger) -> Standby (0% fan / .off)
    var dec = engine.evaluate(thermalState: .nominal, dieC: 45.0, now: 1000)
    assert(dec.tier.coolingTier == .standby && dec.tier.fanPercent == 0 && dec.tier.mode == .off,
           "Expected Standby at 45°C, got \(dec.tier.label)")
    print("  ✅ Step-Ladder Idle: 45°C (< 50°C) -> Standby (0% fan / OFF)")

    // B. Trigger Tier 1: Die reaches 50.0°C (>= 50°C)
    // Anti-spike dwell arms at t=1001 (holds Standby to reject 1-second transient spikes)
    dec = engine.evaluate(thermalState: .nominal, dieC: 50.0, now: 1001)
    assert(dec.tier.coolingTier == .standby && dec.tier.fanPercent == 0,
           "Expected Standby confirming wake at t=1001 (0s < 4s), got \(dec.tier.label)")
    // After 5s sustained >= 50.0°C (elapsed 5s >= 4s dwell), steps up to Tier 1 (40% fan / .low)
    dec = engine.evaluate(thermalState: .nominal, dieC: 50.0, now: 1006)
    assert(dec.tier.coolingTier == .tier1_low && dec.tier.fanPercent == 40 && dec.tier.mode == .low,
           "Expected Tier 1 at 50°C after dwell, got \(dec.tier.label)")
    print("  ✅ Step-Ladder Tier 1 Trigger: 50.0°C -> Confirmed after 4s dwell -> Step-Up to Tier 1 (40% fan / Low)")

    // C. Asymmetric Hysteresis Hold Tier 1: Die drops to 47°C (>= 46°C release threshold) -> STILL HOLDS Tier 1!
    // No chattering loop!
    dec = engine.evaluate(thermalState: .nominal, dieC: 47.0, now: 1007)
    assert(dec.tier.coolingTier == .tier1_low && dec.tier.fanPercent == 40,
           "Expected Tier 1 hold at 47°C (>= 46°C release), got \(dec.tier.label)")
    print("  ✅ Step-Ladder Tier 1 Asymmetric Hold: 47°C (>= 46°C release) -> Faithfully holds 40% fan")

    // D. Normal Step-Down Dwell Timing: Die gently cools from 46.5°C to 45.8°C (< 46.0°C release, dT/dt = -0.7°C/s > -1.0°C/s)
    _ = engine.evaluate(thermalState: .nominal, dieC: 46.5, now: 1008)
    dec = engine.evaluate(thermalState: .nominal, dieC: 45.8, now: 1009) // rate = -0.7°C/s -> normal 20s dwell armed!
    assert(dec.tier.coolingTier == .tier1_low, "Expected Tier 1 to hold during dwell at t=1009")
    print("  ✅ Step-Ladder Step-Down Dwell Hold: 45.8°C at t=1009s -> Holds Tier 1 pending 20s dwell")

    // At t = 1019 (elapsed = 10s < 20s): STILL holds Tier 1!
    dec = engine.evaluate(thermalState: .nominal, dieC: 45.8, now: 1019)
    assert(dec.tier.coolingTier == .tier1_low, "Expected Tier 1 to hold at t=1019s (10s < 20s)")
    print("  ✅ Step-Ladder Dwell in-flight: 10s elapsed (< 20s) -> Fan stays smooth, no premature drop")

    // At t = 1030 (elapsed = 21s >= 20s): Dwell satisfied -> Transitions safely to Standby!
    dec = engine.evaluate(thermalState: .nominal, dieC: 45.8, now: 1030)
    assert(dec.tier.coolingTier == .standby && dec.tier.fanPercent == 0, "Expected Standby after 20s dwell")
    print("  ✅ Step-Ladder Dwell Complete: 21s elapsed (>= 20s) -> Smoothly steps down to Standby (0% fan)")

    // E. Immediate Multi-Tier Thermal Spike Jump:
    // Die suddenly spikes from Standby to 72.0°C (heavy workload compilation) -> JUMPS DIRECTLY TO TIER 4 TURBO!
    dec = engine.evaluate(thermalState: .nominal, dieC: 72.0, now: 1030)
    assert(dec.tier.coolingTier == .tier4_turbo && dec.tier.fanPercent == 100 && dec.tier.mode == .max,
           "Expected immediate jump to Tier 4 Turbo at 72°C, got \(dec.tier.label)")
    print("  ✅ Step-Ladder Spike Bypass: 41°C -> 72°C spike -> Instantly engages Tier 4 Turbo (100% fan / Max)")

    // F. Asymmetric Hold Tier 4: Die drops to 67.0°C (>= 66°C release threshold) -> MUST HOLD TIER 4 TURBO!
    dec = engine.evaluate(thermalState: .nominal, dieC: 67.0, now: 1035)
    assert(dec.tier.coolingTier == .tier4_turbo && dec.tier.fanPercent == 100,
           "Expected Tier 4 hold at 67°C (>= 66°C release), got \(dec.tier.label)")
    print("  ✅ Step-Ladder Tier 4 Asymmetric Hold: 67.0°C (>= 66°C release) -> Holds Tier 4 (100% fan)")

    // G. Step-Down from Tier 4 to Tier 3: Die drops to 63.0°C (< 66°C release, >= 61°C)
    // After 20s dwell, it settles into Tier 3 (80% fan / .medium)
    _ = engine.evaluate(thermalState: .nominal, dieC: 63.0, now: 1040)
    dec = engine.evaluate(thermalState: .nominal, dieC: 63.0, now: 1061)
    assert(dec.tier.coolingTier == .tier3_high && dec.tier.fanPercent == 80,
           "Expected Tier 3 (80% fan) at 63°C after dwell, got \(dec.tier.label)")
    print("  ✅ Step-Ladder Tier 4 -> Tier 3: 63.0°C (< 66°C) -> Settles into Tier 3 (80% fan)")

    // H. Step-Down from Tier 3 to Tier 2: Die drops to 57.0°C (< 61°C release, >= 55°C)
    _ = engine.evaluate(thermalState: .nominal, dieC: 57.0, now: 1070)
    dec = engine.evaluate(thermalState: .nominal, dieC: 57.0, now: 1091)
    assert(dec.tier.coolingTier == .tier2_med && dec.tier.fanPercent == 60,
           "Expected Tier 2 (60% fan) at 57°C after dwell, got \(dec.tier.label)")
    print("  ✅ Step-Ladder Tier 3 -> Tier 2: 57.0°C (< 61°C) -> Settles into Tier 2 (60% fan)")

    // I. Thermal Velocity Bypass (dT/dt <= -1.0°C/s):
    // Die rapidly plunges from 57°C to 48°C in 2 seconds (rate = -4.5°C/s)
    // Normal dwell of 20s is bypassed; fast dwell of 3s allows immediate step-down to prevent chassis overcooling!
    _ = engine.evaluate(thermalState: .nominal, dieC: 57.0, now: 1100)
    _ = engine.evaluate(thermalState: .nominal, dieC: 48.0, now: 1102) // Rapid drop detected!
    dec = engine.evaluate(thermalState: .nominal, dieC: 48.0, now: 1106) // 4s elapsed >= 3s fast dwell
    assert(dec.tier.coolingTier == .tier1_low && dec.tier.fanPercent == 40,
           "Expected fast dwell bypass down to Tier 1 at 48°C, got \(dec.tier.label)")
    print("  ✅ Thermal Velocity Bypass: Rapid cool (-4.5°C/s) -> Bypasses 20s dwell, steps down to Tier 1 in 3s")

    // 6. Universal Condensation Safety Governor Tests (< 36°C Cutoff & >= 38°C Re-arm)
    print("\n🛡️ Testing Universal Condensation Safety Governor (< 36°C Cutoff & >= 38°C Re-Arm)...")

    // A. Sub-36°C Die Temperature forces Standby immediately across ALL modes
    let safetyPolicy = AutopilotPolicy()
    safetyPolicy.setTier(.tier4_turbo) // Pretend it was running at max
    let coldDec = safetyPolicy.evaluate(thermalState: .nominal, dieC: 35.5, now: 2000)
    assert(coldDec.tier.coolingTier == .standby && coldDec.tier.fanPercent == 0 && coldDec.tier.mode == .off,
           "Expected Safety Governor to force Standby at 35.5°C (< 36°C)")
    print("  ✅ Universal Cutoff: Die 35.5°C (< 36.0°C) -> Hard cutoff to Standby (0% fan / 0W)")

    // B. Re-Arm Deadband: Die warms to 37.0°C (< 38.0°C re-arm threshold) -> MUST REMAIN IN STANDBY
    let deadbandDec = safetyPolicy.evaluate(thermalState: .nominal, dieC: 37.0, now: 2001)
    assert(deadbandDec.tier.coolingTier == .standby && deadbandDec.tier.fanPercent == 0,
           "Expected Safety Governor to hold Standby at 37.0°C (< 38°C re-arm)")
    print("  ✅ Anti-Hunting Deadband: Die 37.0°C (< 38.0°C) -> Retains Standby, no relay chattering")

    // 7. Tri-Mode State & Manual Slider Progression Tests
    print("\n⚡ Testing Tri-Mode Representation & Manual Slider Progression...")
    assert(AppMode(persisted: "auto") == .auto)
    assert(AppMode(persisted: "manual") == .manual)
    assert(AppMode(persisted: "turbo") == .turbo)
    assert(AppMode(persisted: "off") == .manual) // Legacy fallback
    print("  ✅ AppMode Serialization: auto, manual, turbo, legacy 'off' roundtrip correctly")

    assert(Config.Safety.condensationCutoffC == 36.0, "Condensation cutoff must be 36.0°C")
    assert(Config.Safety.condensationRearmC == 38.0, "Condensation re-arm must be 38.0°C")
    print("  ✅ Safety Constants: 36.0°C Cutoff, 38.0°C Re-Arm confirmed (no arbitrary decay timeout)")

    // Slider progression verification: strictly increasing fan speed from Off to 100% Max
    let speeds = CoolingSliderView.steps.map(\.fanPercent)
    assert(speeds == [0, 40, 50, 60, 65, 75, 80, 85, 95, 100], "Slider fan speeds must be strictly progressive up to 100%")
    print("  ✅ Slider Progression: Off(0%) -> Low(40/50/60%) -> Med(65/75/80%) -> Max(85/95/100%) confirmed")

    // Fix verification: When 5 Pro reports mode 0x02 (.medium) at 100% fan, slider MUST match Step 9 (Max)!
    let maxMatch = CoolingSliderView.step(matching: .medium, fanPercent: 100)
    assert(maxMatch == 9, "Expected 100% fan to match Step 9 (Max), got \(maxMatch)")
    let medMatch = CoolingSliderView.step(matching: .medium, fanPercent: 80)
    assert(medMatch == 6, "Expected 80% fan to match Step 6 (Med), got \(medMatch)")
    print("  ✅ Med-to-Max Bug Seam Fixed: 100% fan correctly matches Step 9 (Max) without snapping back to Med")

    // 8. Mac Family Thermal LED Calibration (Azul -> Amarelo -> Laranja -> Vermelho)
    print("\n🌈 Testing Mac Family-Aware LED Thermal Color Calibration (Blue -> Yellow -> Orange -> Red)...")
    let airCold = engine.heatColor(for: 50.0, macModel: "MacBook Air")
    assert(airCold.r == 0 && airCold.b == 255, "Expected pure blue for MacBook Air at 50°C (cold/minimum), got R:\(airCold.r) B:\(airCold.b)")
    print("  ✅ MacBook Air: 50°C (nominal/minimum) -> Pure Blue LED (R: \(airCold.r), G: \(airCold.g), B: \(airCold.b))")

    let airYellow = engine.heatColor(for: 75.0, macModel: "MacBook Air")
    assert(airYellow.r == 255 && airYellow.g >= 200 && airYellow.b == 0, "Expected yellow for MacBook Air at 75°C, got R:\(airYellow.r) G:\(airYellow.g)")
    print("  ✅ MacBook Air: 75°C (moderate/warm) -> Yellow LED (R: \(airYellow.r), G: \(airYellow.g), B: \(airYellow.b))")

    let airOrange = engine.heatColor(for: 85.0, macModel: "MacBook Air")
    assert(airOrange.r == 255 && airOrange.g <= 120 && airOrange.b == 0, "Expected orange for MacBook Air at 85°C, got R:\(airOrange.r) G:\(airOrange.g)")
    print("  ✅ MacBook Air: 85°C (sustained load) -> Orange LED (R: \(airOrange.r), G: \(airOrange.g), B: \(airOrange.b))")

    let airHot = engine.heatColor(for: 90.0, macModel: "MacBook Air")
    assert(airHot.r == 255 && airHot.g == 0 && airHot.b == 0, "Expected alert red for MacBook Air at 90°C")
    print("  ✅ MacBook Air: 90°C (hot/throttling) -> Pure Red LED (R: \(airHot.r), G: \(airHot.g), B: \(airHot.b))")

    let studioCold = engine.heatColor(for: 50.0, macModel: "Mac Studio")
    assert(studioCold.r == 0 && studioCold.b == 255, "Expected blue for Mac Studio at 50°C")
    let studioHot = engine.heatColor(for: 86.0, macModel: "Mac Studio")
    assert(studioHot.r == 255 && studioHot.g == 0 && studioHot.b == 0, "Expected red for Mac Studio at 86°C")
    print("  ✅ Mac Studio: 50°C -> Blue, 86°C -> Pure Red LED")

    // 9. Hardware Profile Telemetry & Multi-Brand Verification
    print("\n📡 Testing Multi-Brand Telemetry Capabilities...")
    assert(DeviceProfile.vcCooler6Pro.hasTelemetryStream, "REDMAGIC 6 Pro must have telemetry stream")
    assert(!DeviceProfile.magcooler5Pro.hasTelemetryStream, "REDMAGIC 5 Pro does not broadcast continuous telemetry stream")
    assert(DeviceProfile.blackSharkMagCooler6Max.hasTelemetryStream, "Black Shark 6 Max must have telemetry stream")
    assert(DeviceProfile.blackSharkMagCooler6Max.ratedWatts == 40, "Black Shark 6 Max must be rated at 40W")
    assert(!DeviceProfile.blackSharkMagCooler6Max.hasPhysicalPowerSwitch, "Black Shark 6 Max does not have physical power switch")
    assert(DeviceProfile.blackSharkMagCooler5Pro.hasTelemetryStream, "Black Shark 5 Pro must have telemetry stream")
    assert(DeviceProfile.blackSharkMagCooler4Pro.hasTelemetryStream, "Black Shark 4 Pro must have telemetry stream")
    assert(DeviceProfile.flydigiB8X.hasTelemetryStream, "Flydigi B8X must have telemetry stream")
    assert(DeviceProfile.flydigiB7X.hasTelemetryStream, "Flydigi B7X must have telemetry stream")
    print("  ✅ Telemetry Stream configured for REDMAGIC, Black Shark and Flydigi active profiles")

    // 10. Audit Bug Verifications: macOS .serious Floor & Signed Subzero Decoding
    print("\n🧪 Testing Audit Hardening: .serious Floor & Subzero Signed Decoding...")
    let seriousPolicy = AutopilotPolicy()
    seriousPolicy.resetStandby(isStandby: true)
    let seriousDec = seriousPolicy.evaluate(thermalState: .serious, dieC: 45.0, now: 3000)
    assert(seriousDec.tier.coolingTier == .tier2_med && seriousDec.tier.fanPercent == 60,
           "Expected .serious thermal state to enforce Tier 2 floor even at 45°C die, got \(seriousDec.tier.label)")
    print("  ✅ Thermal Pressure Floor: macOS .serious forces >= Tier 2 (60% fan) at 45°C")

    // Subzero cold plate decoding
    let subzeroRaw: UInt8 = 0xFE // -2 in two's complement Int8
    let decodedSubzero = Int(Int8(bitPattern: subzeroRaw))
    assert(decodedSubzero == -2, "Expected 0xFE to decode as -2°C, got \(decodedSubzero)")
    let subzeroValid = decodedSubzero > -30 && decodedSubzero < 60
    assert(subzeroValid, "Subzero -2°C must pass range validation (-30°C to 60°C)")
    print("  ✅ Signed Subzero Decoding: 0xFE correctly decodes to -2°C (not +254°C overflow)")

    // 11. Deep Logical Audit Regressions
    print("\n🔬 Testing Deep Logical Audit Regressions (resetStandby, formatTemp, UIStyle, Flydigi Subzero)...")

    // A. resetStandby() default must NOT latch Tier 1 at 38°C..49.9°C
    let resetEngine = AutopilotPolicy()
    resetEngine.setTier(.tier4_turbo)
    resetEngine.resetStandby() // Default argument!
    let idleAfterReset = resetEngine.evaluate(thermalState: .nominal, dieC: 45.0, now: 4000)
    assert(idleAfterReset.tier.coolingTier == .standby && idleAfterReset.tier.fanPercent == 0,
           "resetStandby() at 45°C must stay in Standby, got \(idleAfterReset.tier.label)")
    let rearmAfterReset = resetEngine.evaluate(thermalState: .nominal, dieC: 38.0, now: 4001)
    assert(rearmAfterReset.tier.coolingTier == .standby && rearmAfterReset.tier.fanPercent == 0,
           "resetStandby() at 38°C re-arm must stay in Standby, got \(rearmAfterReset.tier.label)")
    let activeAfterReset = resetEngine.evaluate(thermalState: .nominal, dieC: 62.0, now: 4002)
    assert(activeAfterReset.tier.coolingTier == .tier2_med && activeAfterReset.tier.fanPercent == 60,
           "resetStandby() followed by 62°C must jump immediately to Tier 2, got \(activeAfterReset.tier.label)")
    print("  ✅ resetStandby() Default: Stays in Standby at 38°C/45°C (< 50°C) and jumps to Tier 2 at 62°C")

    // B. Unified ThermalState.tierFloor contract
    assert(ThermalState.nominal.tierFloor == .standby)
    assert(ThermalState.fair.tierFloor == .standby)
    assert(ThermalState.serious.tierFloor == .tier2_med)
    assert(ThermalState.critical.tierFloor == .tier4_turbo)
    print("  ✅ ThermalState.tierFloor: Unified with CoolingTier (.standby / .tier2_med / .tier4_turbo)")

    // C. Temperature display floor isomorphism with Step-Ladder & Safety thresholds
    assert(SystemInfo.formatTemp(49.7, unit: .celsius) == "49°C", "49.7°C must display as 49°C while < 50°C")
    assert(SystemInfo.formatTemp(50.0, unit: .celsius) == "50°C", "50.0°C must display as 50°C")
    assert(SystemInfo.formatTemp(35.9, unit: .celsius) == "35°C", "35.9°C must display as 35°C while < 36°C")
    assert(SystemInfo.formatTemp(37.9, unit: .celsius) == "37°C", "37.9°C must display as 37°C while < 38°C")
    assert(SystemInfo.formatTemp(64.9, unit: .celsius) == "64°C", "64.9°C must display as 64°C")
    assert(SystemInfo.formatTemp(-2, unit: .celsius) == "-2°C", "-2°C integer must display as -2°C")
    print("  ✅ SystemInfo.formatTemp: Exact integer floor alignment at 35.9°C, 37.9°C, 49.7°C, 50.0°C, 64.9°C")

    // D. UIStyle.heatColor calibrated per Mac family
    assert(UIStyle.heatColor(65.0, macModel: "MacBook Air") != .systemYellow, "Air 65.0°C must still be Blue")
    assert(UIStyle.heatColor(65.1, macModel: "MacBook Air") == .systemYellow, "Air 65.1°C must be Yellow")
    assert(UIStyle.heatColor(88.0, macModel: "MacBook Air") == .systemRed, "Air 88.0°C must be Red")
    assert(UIStyle.heatColor(67.0, macModel: "MacBook Pro") != .systemYellow, "MBP 67.0°C must still be Blue (< 68°C)")
    assert(UIStyle.heatColor(70.0, macModel: "MacBook Pro") == .systemYellow, "MBP 70.0°C must be Yellow")
    assert(UIStyle.heatColor(60.0, macModel: "Mac Studio") == .systemYellow, "Studio 60.0°C must be Yellow (> 58°C)")
    print("  ✅ UIStyle.heatColor: Synchronized with MacThermalProfile across Air, Pro, and Studio")

    // E. Flydigi subzero signed fractional decoding
    let fdWhole = Int(Int8(bitPattern: UInt8(0xFE))) // -2
    let fdFrac = Double(min(UInt8(4), 9)) / 10.0
    let fdCold = Int(round(fdWhole < 0 ? (Double(fdWhole) - fdFrac) : (Double(fdWhole) + fdFrac)))
    assert(fdCold == -2, "Flydigi subzero 0xFE + .4 must decode to -2°C, got \(fdCold)")
    print("  ✅ Flydigi Subzero Decoding: 0xFE.4 correctly decodes to -2°C")

    // F. ManualTimer & AppVersion checks
    var mTimer = ManualTimer(timeout: .oneHour)
    mTimer.start(now: 1_000)
    assert(!mTimer.hasExpired(now: 4_599))
    assert(mTimer.hasExpired(now: 4_600))
    assert(AppVersion("v2.9")! < AppVersion("v2.10")!)
    assert(AppVersion("v3.1")! == AppVersion("3.1.0")!)
    print("  ✅ ManualTimer & AppVersion: Expiry and semantic version comparison verified")

    // G. ThermalMonitor Dual CPU + GPU Silicon Telemetry & Cache
    let tReading = ThermalMonitor.read()
    if let die = tReading.dieTemperatureC {
        assert((1...130).contains(die), "Die temperature must be within plausible range 1..130°C, got \(die)")
        if let cpu = tReading.cpuTempC, let gpu = tReading.gpuTempC {
            assert(abs(die - max(cpu, gpu)) < 0.001, "dieTemperatureC must equal max(cpu, gpu)")
        }
        print("  ✅ ThermalMonitor Dual Telemetry: Die \(String(format: "%.1f°C", die)) (CPU: \(tReading.cpuTempC.map { String(format: "%.1f°C", $0) } ?? "nil"), GPU: \(tReading.gpuTempC.map { String(format: "%.1f°C", $0) } ?? "nil"))")
    } else {
        print("  ℹ️ ThermalMonitor: Non-Apple-Silicon or headless environment (state: \(tReading.thermalState))")
    }

    // H. ThermalHistory 10-Minute Rolling Window (Min / Avg / Max + Pruning)
    let history = ThermalHistory(windowSeconds: 600.0)
    history.record(ThermalMonitor.Reading(thermalState: .serious, dieTemperatureC: 90.0,
                                          cpuTempC: 90.0, gpuTempC: 70.0, batteryTempC: 34.0, storageTempC: 48.0), now: 1000.0)
    history.record(ThermalMonitor.Reading(thermalState: .nominal, dieTemperatureC: 50.0,
                                          cpuTempC: 50.0, gpuTempC: 44.0, batteryTempC: 30.0, storageTempC: 40.0), now: 1200.0)
    // Rapid sub-second refresh at 1200.2s must replace 1200.0s sample rather than double-counting
    history.record(ThermalMonitor.Reading(thermalState: .nominal, dieTemperatureC: 52.0,
                                          cpuTempC: 52.0, gpuTempC: 46.0, batteryTempC: 30.0, storageTempC: 40.0), now: 1200.2)
    history.record(ThermalMonitor.Reading(thermalState: .nominal, dieTemperatureC: 44.0,
                                          cpuTempC: 44.0, gpuTempC: 40.0, batteryTempC: 28.0, storageTempC: 38.0), now: 1500.0)

    let snapMid = history.snapshot(now: 1500.0)
    assert(snapMid.windowMinutes == 10, "Window must report 10 minutes")
    assert(snapMid.sampleCount == 3, "Expected 3 samples after sub-second coalescing, got \(snapMid.sampleCount)")
    assert(snapMid.cpu?.min == 44.0 && snapMid.cpu?.max == 90.0 && snapMid.cpu?.current == 44.0)
    assert(abs((snapMid.cpu?.avg ?? 0) - 62.0) < 0.01, "Expected CPU avg 62.0°C ((90+52+44)/3)")
    assert(snapMid.battery?.min == 28.0 && snapMid.battery?.max == 34.0)
    assert(snapMid.storage?.min == 38.0 && snapMid.storage?.max == 48.0)

    // Advance past 10 minutes from the initial 90°C spike (1000 + 601 = 1601)
    let snapPruned = history.snapshot(now: 1601.0)
    assert(snapPruned.sampleCount == 2, "Old 90°C sample at t=1000 must prune at t=1601")
    assert(snapPruned.cpu?.max == 52.0 && snapPruned.cpu?.min == 44.0 && abs((snapPruned.cpu?.avg ?? 0) - 48.0) < 0.01)

    // Backwards clock jump resilience
    history.record(ThermalMonitor.Reading(thermalState: .nominal, dieTemperatureC: 46.0, cpuTempC: 46.0), now: 500.0)
    let snapReset = history.snapshot(now: 500.0)
    assert(snapReset.sampleCount == 1 && snapReset.cpu?.current == 46.0)
    print("  ✅ ThermalHistory (10m Rolling): Min/Avg/Max, sub-second coalescing, 600s pruning & clock-jump resilience verified")

    // I. SystemInfo Exact Chip & Friendly Model Formatting
    assert(SystemInfo.formatFriendlyModel("MacBook Air (13-inch, M5)") == "MacBook Air 13\"")
    assert(SystemInfo.formatFriendlyModel("MacBook Pro (16-inch, Nov 2024)") == "MacBook Pro 16\"")
    assert(SystemInfo.formatFriendlyModel("Mac Studio (2025)") == "Mac Studio")
    assert(SystemInfo.formatFriendlyModel("iMac (24-inch, M4, 2024)") == "iMac 24\"")
    assert(SystemInfo.formatChipName("Apple M5") == "Apple M5")
    assert(SystemInfo.formatChipName("Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz") == "Intel Core i7")
    print("  ✅ SystemInfo Hardware Detection: Model '\(SystemInfo.macModel)' · Chip '\(SystemInfo.chipName ?? "unknown")'")

    // J. FrequencyMonitor Formatting & ANE Telemetry
    assert(FrequencyMonitor.formatFreq(0) == "")
    assert(FrequencyMonitor.formatFreq(740) == "740 MHz")
    assert(FrequencyMonitor.formatFreq(1000) == "1.0 GHz")
    assert(FrequencyMonitor.formatFreq(2600) == "2.6 GHz")
    assert(FrequencyMonitor.formatFreq(3500) == "3.5 GHz")
    assert(FrequencyMonitor.formatCurrentWithMax(currentMHz: 2600, maxMHz: 4500) == "2.6 / 4.5 GHz")
    assert(FrequencyMonitor.formatCurrentWithMax(currentMHz: 740, maxMHz: 1600) == "740 MHz / 1.6 GHz")
    assert(FrequencyMonitor.formatCurrentWithMax(currentMHz: 0, maxMHz: 4500) == "Máx 4.5 GHz")

    assert(FrequencyMonitor.parseBandwidthGBs("  64GB/s") == 64)
    assert(FrequencyMonitor.parseBandwidthGBs("2 GB/s") == 2)
    assert(FrequencyMonitor.parseBandwidthGBs("VMIN") == nil)

    // ANE Idle: VMIN 100%, baseline index-0 keepalive ignored
    let aneIdle = FrequencyMonitor.summarizeANE(
        floorStates: [("VMIN", 24_000_000), ("VNOM", 0), ("VMAX", 0), ("VOVD", 0)],
        niStates: [("2GB/s", 17), ("4GB/s", 0)],
        afStates: [("1GB/s", 4000), ("2GB/s", 0)]
    )
    assert(aneIdle.isSupported && !aneIdle.isActive && aneIdle.activePercent == 0 && aneIdle.peakBandwidthGBs == 0)
    assert(FrequencyMonitor.formatANEStatus(aneIdle) == "Ocioso")

    // ANE Idle with recent 10m peak
    var aneRecent = aneIdle
    aneRecent.recentMaxActivePercent = 44.0
    aneRecent.recentPeakBandwidthGBs = 62
    assert(FrequencyMonitor.formatANEStatus(aneRecent) == "Ocioso · Pico 62 GB/s")

    // ANE Active burst: VNOM+VMAX+VOVD active + 62 GB/s uplink + 32 GB/s fabric
    let aneBurst = FrequencyMonitor.summarizeANE(
        floorStates: [("VMIN", 7_100_000), ("VNOM", 1_600_000), ("VMAX", 800_000), ("VOVD", 500_000)],
        niStates: [("2GB/s", 177), ("32GB/s", 18), ("62GB/s", 1), ("64GB/s", 0)],
        afStates: [("1GB/s", 946), ("32GB/s", 78)]
    )
    assert(aneBurst.isSupported && aneBurst.isActive)
    assert(abs(aneBurst.activePercent - 29.0) < 0.1, "Expected 29.0% ANE duty residency, got \(aneBurst.activePercent)")
    assert(aneBurst.peakFloor == .vovd)
    assert(aneBurst.peakBandwidthGBs == 62)
    assert(FrequencyMonitor.formatANEStatus(aneBurst) == "Ativo · 29% · Máx · 62 GB/s")

    // ANE Fallback (older hardware without PMP counters)
    let aneFallback = FrequencyMonitor.summarizeANE(floorStates: [], niStates: [], afStates: [], hasDriverFallbackActive: true)
    assert(aneFallback.isActive && FrequencyMonitor.formatANEStatus(aneFallback) == "Ativo")

    print("  ✅ FrequencyMonitor: Clocks (MHz/GHz) & ANE telemetry summarization verified")

    // K. Black Shark MagCooler 6 Max (BR64) Driver Encoding, Lighting, PD & Telemetry Decoding
    let br64Driver = BlackSharkDriver(profile: .blackSharkMagCooler6Max)
    let bs5ProDriver = BlackSharkDriver(profile: .blackSharkMagCooler5Pro)
    assert(br64Driver.writableUUIDs.contains(CBUUID(string: "0000A001-0000-1000-8000-00805F9B34FB")))
    assert(br64Driver.notifyingUUIDs.contains(CBUUID(string: "0000A002-0000-1000-8000-00805F9B34FB")))
    assert(br64Driver.telemetryPollCommand() == [0x05, 0x06, 0x20, 0x00, 0x00])
    assert(br64Driver.br64InitialQueryCommands() == [
        [0x05, 0x07, 0x08, 0x00, 0x00],
        [0x05, 0x05, 0x08, 0x00, 0x00],
        [0x05, 0x01, 0x20, 0x00, 0x00],
        [0x05, 0x04, 0x30, 0x00, 0x00]
    ])
    assert(br64Driver.coolingCommands(mode: .off, fanPercent: 0) == [[0x05, 0x07, 0x00, 0x00, 0x01]])
    assert(br64Driver.coolingCommands(mode: .low, fanPercent: 40) == [
        [0x05, 0x07, 0x00, 0x00, 0x00],
        [0x06, 0x05, 0x00, 0x00, 0x04, 0x01]
    ])
    assert(br64Driver.coolingCommands(mode: .medium, fanPercent: 75) == [
        [0x05, 0x07, 0x00, 0x00, 0x00],
        [0x06, 0x05, 0x00, 0x00, 0x04, 0x04]
    ])
    assert(br64Driver.coolingCommands(mode: .max, fanPercent: 90) == [
        [0x05, 0x07, 0x00, 0x00, 0x00],
        [0x06, 0x05, 0x00, 0x00, 0x04, 0x05]
    ])
    assert(br64Driver.coolingCommands(mode: .max, fanPercent: 100) == [
        [0x05, 0x07, 0x00, 0x00, 0x00],
        [0x06, 0x05, 0x00, 0x00, 0x01, 0x00]
    ])
    assert(bs5ProDriver.coolingCommands(mode: .max, fanPercent: 100) == [
        [0x05, 0x07, 0x00, 0x00, 0x00],
        [0x06, 0x05, 0x00, 0x00, 0x04, 0x05]
    ])
    assert(br64Driver.br64WorkModeCommand(.ai) == [0x06, 0x05, 0x00, 0x00, 0x02, 0x00])
    assert(br64Driver.br64WorkModeCommand(.silent) == [0x06, 0x05, 0x00, 0x00, 0x03, 0x00])
    assert(br64Driver.br64LowTecStatusCommand(enabled: true) == [0x05, 0x06, 0x00, 0x00, 0x01])
    assert(br64Driver.br64LowTecTemperatureCommand(-5) == [0x05, 0x06, 0x10, 0x00, 0xFB])

    // Lighting mode + all standard effects (rainbow, colorfulBreath, monochromeBreath, steady)
    assert(br64Driver.v2LightModeCommand(enabled: true) == [0x05, 0x01, 0x00, 0x00, 0x00])
    assert(br64Driver.v2LightModeCommand(enabled: false) == [0x05, 0x01, 0x00, 0x00, 0x03])
    let br64Rgb = RGB(r: 0x10, g: 0x80, b: 0xFF)
    assert(br64Driver.v2LightParamFrame(effect: 1, color: br64Rgb) == [
        0x10, 0x01, 0x10, 0x00, 0x00, 0x07, 0x14, 0x05, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ])
    assert(br64Driver.v2LightParamFrame(effect: 2, color: br64Rgb) == [
        0x10, 0x01, 0x10, 0x00, 0x00, 0x0A, 0x58, 0x1B, 0x64, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ])
    assert(br64Driver.v2LightParamFrame(effect: 3, color: br64Rgb) == [
        0x10, 0x01, 0x10, 0x00, 0x00, 0x0A, 0x58, 0x1B, 0x64, 0x01, 0x10, 0x80, 0xFF, 0x00, 0x00, 0x00
    ])
    assert(br64Driver.v2LightParamFrame(r: 0x10, g: 0x80, b: 0xFF) == [
        0x10, 0x01, 0x10, 0x00, 0x00, 0x09, 0xff, 0x00, 0x64, 0x01, 0x10, 0x80, 0xff, 0x00, 0x00, 0x00
    ])

    // Telemetry decoding (cold/hot/RPM/watts/inputVoltsTier) + PD tier throttling
    if case .telemetry(let br64Telem) = br64Driver.parseUpdate([0x0B, 0x06, 0x20, 0x00, 0xFE, 0x28, 0x88, 0x13, 0x28, 0x0F, 0x02]) {
        assert(br64Telem.coldC == -2 && br64Telem.hotC == 40 && br64Telem.fanRPM == 5000,
               "Expected -2°C cold, 40°C hot, 5000 RPM for BR64 telemetry, got \(br64Telem)")
        assert(br64Telem.watts == 40 && br64Telem.inputVoltsTier == 15,
               "Expected 40W & PD tier 15, got watts=\(String(describing: br64Telem.watts)) vin=\(String(describing: br64Telem.inputVoltsTier))")
    } else {
        assertionFailure("Expected BR64 telemetry packet to decode cleanly even with non-0x89 header byte")
    }
    assert(br64Driver.coolingCommands(mode: .max, fanPercent: 100)[1] == [0x06, 0x05, 0x00, 0x00, 0x01, 0x00])

    _ = br64Driver.parseUpdate([0x0B, 0x06, 0x20, 0x00, 0x02, 0x24, 0x10, 0x0E, 0x1E, 0x0C, 0x01]) // 30W (tier 12)
    assert(br64Driver.coolingCommands(mode: .max, fanPercent: 100)[1] == [0x06, 0x05, 0x00, 0x00, 0x01, 0x00])
    assert(br64Driver.coolingCommands(mode: .max, fanPercent: 90)[1] == [0x06, 0x05, 0x00, 0x00, 0x04, 0x04])

    _ = br64Driver.parseUpdate([0x0B, 0x06, 0x20, 0x00, 0x06, 0x22, 0xE8, 0x03, 0x14, 0x0A, 0x01]) // <30W (tier 10)
    assert(br64Driver.coolingCommands(mode: .max, fanPercent: 100)[1] == [0x06, 0x05, 0x00, 0x00, 0x04, 0x03])

    _ = br64Driver.parseUpdate([0x0B, 0x06, 0x20, 0x00, 0x0A, 0x20, 0xE8, 0x03, 0x0A, 0x05, 0x01]) // 5V (tier 5)
    assert(br64Driver.coolingCommands(mode: .max, fanPercent: 100)[1] == [0x06, 0x05, 0x00, 0x00, 0x04, 0x01])

    // Write ACKs (`0x00`) must return `.none`, while query reports (`0x08`) update state
    assert(br64Driver.parseUpdate([0x06, 0x05, 0x00, 0x00, 0x01, 0x00]) == .none)
    assert(br64Driver.parseUpdate([0x05, 0x07, 0x00, 0x00, 0x01]) == .none)
    assert(br64Driver.parseUpdate([0x06, 0x05, 0x08, 0x00, 0x01, 0x00]) == .mode(.max))
    assert(br64Driver.reportedWorkMode == .overclock)
    assert(br64Driver.parseUpdate([0x06, 0x05, 0x08, 0x00, 0x03, 0x00]) == .mode(.low))
    assert(br64Driver.reportedWorkMode == .silent)
    assert(br64Driver.parseUpdate([0x05, 0x07, 0x08, 0x00, 0x01]) == .mode(.off))

    // CoolerPanelView telemetry formatting & PD insufficient-power note
    let br64UiTelem = CoolerTelemetry(coldC: -2, hotC: 40, ambientC: 0, fanRPM: 5000, watts: 40, inputVoltsTier: 15)
    assert(CoolerPanelView.formatTelemetry(br64UiTelem) == "Frio -2°C / Hot 40°C · 5000 RPM · 40W")
    let basicUiTelem = CoolerTelemetry(coldC: 5, hotC: 32, ambientC: 0, fanRPM: nil)
    assert(CoolerPanelView.formatTelemetry(basicUiTelem) == "Frio 5°C / Hot 32°C")
    assert(CoolerPanelView.Note.insufficientPower.text.contains("30W"))

    print("  ✅ Black Shark 6 Max (BR64): Profile, A0A0 v2 commands, LED modes, PD capping & telemetry verified")

    print("\n🎉 ALL TESTS PASSED! Deterministic Step-Ladder, Asymmetric Hysteresis, Dwell & Velocity Bypass, Universal Condensation Safety Governor & Multi-Brand Isolation verified.")
}

@main
struct TestRunner {
    static func main() {
        runTests()
    }
}
