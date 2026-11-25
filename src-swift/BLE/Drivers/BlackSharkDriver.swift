import Foundation
import CoreBluetooth

/// Dedicated driver for the Black Shark cooler family:
///  - Black Shark MagCooler 4 Pro (27W TEC)
///  - Black Shark MagCooler 5 Pro (35W TEC, BR42/BR52)
///  - Black Shark MagCooler 6 Max (40W TEC, BR64)
///
/// Implements the reverse-engineered protocol from BlackSharkLib / Moblin / Shark Arsenal (`cooler_br64`):
/// Service: `0000A0A0-3C17-D293-8E48-14FE2E4DA212`
/// Write:   `0000A001-0000-1000-8000-00805F9B34FB` (.withoutResponse)
/// Read:    `0000A002-0000-1000-8000-00805F9B34FB`
final class BlackSharkDriver: CoolerDriver {

    let profile: DeviceProfile

    enum BR64WorkMode: UInt8, Equatable {
        case overclock = 0x01
        case ai = 0x02
        case silent = 0x03
        case custom = 0x04
    }

    let serviceUUID = CBUUID(string: "0000A0A0-3C17-D293-8E48-14FE2E4DA212")

    let writeCharacteristicUUID = CBUUID(string: "0000A001-3C17-D293-8E48-14FE2E4DA212")
    let readCharacteristicUUID  = CBUUID(string: "0000A002-3C17-D293-8E48-14FE2E4DA212")

    private static let sigWriteCharacteristicUUID = CBUUID(string: "0000A001-0000-1000-8000-00805F9B34FB")
    private static let sigReadCharacteristicUUID  = CBUUID(string: "0000A002-0000-1000-8000-00805F9B34FB")

    var notifyingUUIDs: Set<CBUUID> {
        [readCharacteristicUUID, Self.sigReadCharacteristicUUID, CBUUID(string: "A002")]
    }
    var writableUUIDs: Set<CBUUID> {
        [writeCharacteristicUUID, Self.sigWriteCharacteristicUUID, CBUUID(string: "A001")]
    }

    private var writeChar: CBCharacteristic?
    private var readChar: CBCharacteristic?
    private var pendingWorkItem: DispatchWorkItem?
    private var pendingLightWorkItem: DispatchWorkItem?
    private var initQueryWorkItems: [DispatchWorkItem] = []
    private var telemetryPollTimer: Timer?
    private weak var peripheral: CBPeripheral?
    private var lastAppliedCommands: [[UInt8]]?
    private var lastLightingModeByte: UInt8?
    private(set) var latestInputVoltsTier: Int?
    private(set) var reportedWorkMode: BR64WorkMode?
    private(set) var reportedWorkGear: UInt8?

    private var is5Pro: Bool {
        profile.id.contains("5pro") || profile.modelName.contains("5 Pro")
    }

    private var is6Max: Bool {
        profile.id.contains("6max") || profile.modelName.contains("6 Max")
    }

    /// 5 Pro (`BR42`/`BR52`) and 6 Max (`BR64`) share the A0A0 v2 command framing.
    private var usesV2Protocol: Bool {
        is5Pro || is6Max
    }

    init(profile: DeviceProfile) {
        self.profile = profile
    }

    func didConnect(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }

    func didDiscoverCharacteristics(characteristics: [CBUUID: CBCharacteristic], peripheral: CBPeripheral) {
        self.peripheral = peripheral
        for (uuid, char) in characteristics {
            let str = uuid.uuidString.lowercased()
            if uuid == writeCharacteristicUUID || uuid == Self.sigWriteCharacteristicUUID || str.contains("a001") {
                writeChar = char
            }
            if uuid == readCharacteristicUUID || uuid == Self.sigReadCharacteristicUUID || str.contains("a002") {
                readChar = char
            }
        }

        // Start active telemetry polling timer (every 2.0s)
        startTelemetryPolling()

        if is6Max {
            sendBR64InitialQueries(peripheral: peripheral)
        }
    }

    private func startTelemetryPolling() {
        telemetryPollTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollTelemetry()
        }
        RunLoop.main.add(timer, forMode: .common)
        telemetryPollTimer = timer
        // Immediate first poll
        pollTelemetry()
    }

    func br64InitialQueryCommands() -> [[UInt8]] {
        [
            [0x05, 0x07, 0x08, 0x00, 0x00], // getTableWorkModeCmd
            [0x05, 0x05, 0x08, 0x00, 0x00], // getWorkModeCmd
            [0x05, 0x01, 0x20, 0x00, 0x00], // getLightingParametersCmd
            [0x05, 0x04, 0x30, 0x00, 0x00], // getFirmwareVersionCmd
        ]
    }

    private func sendBR64InitialQueries(peripheral: CBPeripheral) {
        initQueryWorkItems.forEach { $0.cancel() }
        initQueryWorkItems.removeAll()

        for (idx, cmd) in br64InitialQueryCommands().enumerated() {
            let work = DispatchWorkItem { [weak self, weak peripheral] in
                guard let self, let peripheral, let writeChar = self.writeChar else { return }
                peripheral.writeValue(Data(cmd), for: writeChar, type: .withoutResponse)
            }
            initQueryWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 + Double(idx) * 0.06, execute: work)
        }
    }

    func telemetryPollCommand() -> [UInt8] {
        // MagCooler 5 Pro (BR42/BR52) & 6 Max (BR64): [0x05, 0x06, 0x20, 0x00, 0x00]
        // MagCooler 4 Pro: [0x05, 0x06, 0x00, 0x00, 0x00]
        usesV2Protocol ? [0x05, 0x06, 0x20, 0x00, 0x00] : [0x05, 0x06, 0x00, 0x00, 0x00]
    }

    func br64TableModeCommand(enabled: Bool) -> [UInt8] {
        [0x05, 0x07, 0x00, 0x00, enabled ? 0x01 : 0x00]
    }

    func br64WorkModeCommand(_ workMode: BR64WorkMode, gear: UInt8 = 0) -> [UInt8] {
        [0x06, 0x05, 0x00, 0x00, workMode.rawValue, gear]
    }

    func br64LowTecStatusCommand(enabled: Bool) -> [UInt8] {
        [0x05, 0x06, 0x00, 0x00, enabled ? 0x01 : 0x00]
    }

    func br64LowTecTemperatureCommand(_ tempC: Int) -> [UInt8] {
        let clamped = max(-20, min(30, tempC))
        return [0x05, 0x06, 0x10, 0x00, UInt8(bitPattern: Int8(clamped))]
    }

    /// Maximum custom gear allowed by BR64 firmware based on `bytes[9]` USB-PD voltage tier.
    func br64MaxCustomGear(forInputVoltsTier tier: Int?) -> UInt8 {
        guard let tier else { return 5 }
        if tier >= 15 { return 5 }
        if tier >= 12 { return 4 }
        if tier >= 9  { return 3 }
        return 1
    }

    /// Whether BR64 firmware permits Overclock (`0x01 0x00`) at the reported USB-PD tier (`>= 12`, i.e. 30W+).
    func br64AllowsOverclock(forInputVoltsTier tier: Int?) -> Bool {
        guard let tier else { return true }
        return tier >= 12
    }

    func v2Intensity(for mode: CoolingMode, fanPercent: UInt8) -> UInt8 {
        let targetSpeed: UInt8 = mode.isOn ? min(fanPercent, 100) : 0
        switch mode.zone {
        case .off:    return 1
        case .low:    return (targetSpeed > 50) ? 2 : 1
        case .medium: return (targetSpeed > 60) ? 4 : 3
        case .max:    return 5 // Gear 5: peak 35W on 5 Pro / 40W on 6 Max
        }
    }

    /// Builds ordered BLE write frames for a cooling mode + fan speed change.
    func coolingCommands(mode: CoolingMode, fanPercent: UInt8) -> [[UInt8]] {
        let targetSpeed: UInt8 = mode.isOn ? min(fanPercent, 100) : 0
        if usesV2Protocol {
            // Desk mode (`setTableMode`): [0x05, 0x07, 0x00, 0x00, 0x01] pauses TEC Peltier.
            if mode == .off {
                return [br64TableModeCommand(enabled: true)]
            }
            if is6Max {
                if mode == .max && targetSpeed >= 95 && br64AllowsOverclock(forInputVoltsTier: latestInputVoltsTier) {
                    return [
                        br64TableModeCommand(enabled: false),
                        br64WorkModeCommand(.overclock, gear: 0)
                    ]
                }
                let rawGear = v2Intensity(for: mode, fanPercent: targetSpeed)
                let cappedGear = min(rawGear, br64MaxCustomGear(forInputVoltsTier: latestInputVoltsTier))
                return [
                    br64TableModeCommand(enabled: false),
                    br64WorkModeCommand(.custom, gear: cappedGear)
                ]
            }
            let intensity = v2Intensity(for: mode, fanPercent: targetSpeed)
            return [
                [0x05, 0x07, 0x00, 0x00, 0x00],
                [0x06, 0x05, 0x00, 0x00, 0x04, intensity]
            ]
        }

        // Black Shark MagCooler 4 Pro (27W):
        // Independent Peltier power and fan speed (0-100 inverted, 0 = 0xFB)
        let fanVal: UInt8 = (targetSpeed == 0 || !mode.isOn) ? 0xFB : UInt8(100 - targetSpeed)
        let coolVal: UInt8
        if mode == .off {
            coolVal = 0xFB
        } else {
            switch mode.zone {
            case .off:    coolVal = 0xFB
            case .low:    coolVal = 0x4B // ~25%
            case .medium: coolVal = 0x28 // ~60%
            case .max:    coolVal = 0x00 // 100% full Peltier
            }
        }
        return [
            [0x05, 0x05, 0x00, 0x00, coolVal],
            [0x05, 0x02, 0x00, 0x00, fanVal]
        ]
    }

    /// Encodes the 16-byte V2 standard RGB parameter frame (`setLightingParams` for BR52 & BR64).
    /// Maps `LedEffect.DeviceEffect` (`1=rainbow`, `2=colorfulBreath`, `3=monochromeBreath`, `4=steady`).
    func v2LightParamFrame(effect: UInt8, color: RGB) -> [UInt8] {
        switch effect {
        case 1:
            // Rotating Rainbow (`mode = 0x07`, speed `1300 = 0x0514`, full-color slot `0x00`)
            return [
                0x10, 0x01, 0x10, 0x00,
                0x00, 0x07, 0x14, 0x05,
                0x64, 0x00,
                0x00, 0x00, 0x00,
                0x00, 0x00, 0x00
            ]
        case 2:
            // Dynamic Multi-Color Breath (`mode = 0x0A`, speed `7000 = 0x1B58`, dynamic slot `0x09`)
            return [
                0x10, 0x01, 0x10, 0x00,
                0x00, 0x0A, 0x58, 0x1B,
                0x64, 0x09,
                0x00, 0x00, 0x00,
                0x00, 0x00, 0x00
            ]
        case 3:
            // Monochrome Breath (`mode = 0x0A`, speed `7000 = 0x1B58`, single color slot `0x01`)
            return [
                0x10, 0x01, 0x10, 0x00,
                0x00, 0x0A, 0x58, 0x1B,
                0x64, 0x01,
                color.r, color.g, color.b,
                0x00, 0x00, 0x00
            ]
        default:
            // Steady Solid Glow (`mode = 0x09`, speed `255 = 0x00FF`, single color slot `0x01`)
            let r: UInt8 = (effect == 0) ? 0 : color.r
            let g: UInt8 = (effect == 0) ? 0 : color.g
            let b: UInt8 = (effect == 0) ? 0 : color.b
            return [
                0x10, 0x01, 0x10, 0x00,
                0x00, 0x09, 0xFF, 0x00,
                0x64, 0x01,
                r, g, b,
                0x00, 0x00, 0x00
            ]
        }
    }

    /// Convenience solid-color encoder (`LedEffect.DeviceEffect.steady`).
    func v2LightParamFrame(r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        v2LightParamFrame(effect: 4, color: RGB(r: r, g: g, b: b))
    }

    /// Encodes V2 lighting mode switch (`0x00` standard, `0x03` off).
    func v2LightModeCommand(enabled: Bool) -> [UInt8] {
        [0x05, 0x01, 0x00, 0x00, enabled ? 0x00 : 0x03]
    }

    private func pollTelemetry() {
        guard let peripheral, let writeChar else { return }
        peripheral.writeValue(Data(telemetryPollCommand()), for: writeChar, type: .withoutResponse)
    }

    private var desiredMode: CoolingMode?
    private var desiredFanPercent: UInt8?

    func apply(mode: CoolingMode, fanPercent: UInt8, peripheral: CBPeripheral) {
        guard let writeChar else { return }
        let targetSpeed: UInt8 = mode.isOn ? min(fanPercent, 100) : 0
        desiredMode = mode
        desiredFanPercent = targetSpeed

        let frames = coolingCommands(mode: mode, fanPercent: targetSpeed)
        guard frames != lastAppliedCommands else { return }
        writeCoolingFrames(frames, writeChar: writeChar, peripheral: peripheral)
    }

    private func writeCoolingFrames(_ frames: [[UInt8]], writeChar: CBCharacteristic, peripheral: CBPeripheral) {
        lastAppliedCommands = frames

        // Cancel any in-flight deferred command so a rapid off-command cannot be
        // overwritten 50ms later by an earlier power-on write.
        pendingWorkItem?.cancel()
        pendingWorkItem = nil

        guard let first = frames.first else { return }
        peripheral.writeValue(Data(first), for: writeChar, type: .withoutResponse)

        if frames.count > 1 {
            let second = Data(frames[1])
            let work = DispatchWorkItem { [weak self, weak peripheral] in
                guard let self, let peripheral, let writeChar = self.writeChar else { return }
                peripheral.writeValue(second, for: writeChar, type: .withoutResponse)
            }
            pendingWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }

    private func reapplyDesiredCoolingIfNeeded(peripheral: CBPeripheral) {
        guard is6Max, let desiredMode, let desiredFanPercent, let writeChar else { return }
        let frames = coolingCommands(mode: desiredMode, fanPercent: desiredFanPercent)
        guard frames != lastAppliedCommands else { return }
        writeCoolingFrames(frames, writeChar: writeChar, peripheral: peripheral)
    }

    func setLight(effect: UInt8, color: RGB, peripheral: CBPeripheral) {
        guard let writeChar else { return }

        let r = (effect == 0) ? 0 : color.r
        let g = (effect == 0) ? 0 : color.g
        let b = (effect == 0) ? 0 : color.b

        pendingLightWorkItem?.cancel()
        pendingLightWorkItem = nil

        if is6Max {
            let targetModeByte: UInt8 = (effect == 0) ? 0x03 : 0x00
            let paramFrame = Data(v2LightParamFrame(effect: effect, color: color))
            if lastLightingModeByte != targetModeByte {
                lastLightingModeByte = targetModeByte
                peripheral.writeValue(Data(v2LightModeCommand(enabled: effect != 0)), for: writeChar, type: .withoutResponse)
                if effect != 0 {
                    let work = DispatchWorkItem { [weak self, weak peripheral] in
                        guard let self, let peripheral, let writeChar = self.writeChar else { return }
                        peripheral.writeValue(paramFrame, for: writeChar, type: .withoutResponse)
                    }
                    pendingLightWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
                }
            } else if effect != 0 {
                peripheral.writeValue(paramFrame, for: writeChar, type: .withoutResponse)
            }
        } else if is5Pro {
            // 16-byte frame for 5 Pro
            peripheral.writeValue(Data(v2LightParamFrame(effect: effect, color: color)), for: writeChar, type: .withoutResponse)
        } else {
            // 47-byte frame for 4 Pro
            var bytes = [UInt8](repeating: 0, count: 47)
            bytes[0] = 0x2f
            bytes[1] = 0x01
            bytes[2] = 0x20
            bytes[4] = (effect == 0) ? 0x01 : 0x06 // Mode: 0x01 off, 0x06 steady color
            bytes[6] = 0xff
            bytes[7] = 0xff
            bytes[8] = 0xff
            bytes[10] = 0x01
            bytes[11] = r
            bytes[12] = g
            bytes[13] = b
            peripheral.writeValue(Data(bytes), for: writeChar, type: .withoutResponse)
        }
    }

    /// Parses raw notification bytes from `0xA002`.
    func parseUpdate(_ bytes: [UInt8]) -> DriverUpdate {
        guard bytes.count > 2 else { return .none }

        // 1. V2 Telemetry frame (`BR64` 6 Max matches `bytes[1]==0x06 && bytes[2]==0x20`;
        //    `5 Pro` keeps `bytes[0]==0x89 && bytes[1]==0x06`)
        // Framing: <hdr> 06 20 00 <cold> <hot> <rpm-lo> <rpm-hi> [<power>] [<vin>] [<skin>]
        let isBR64Telemetry = is6Max && bytes[1] == 0x06 && bytes[2] == 0x20 && bytes.count >= 8
        let is5ProTelemetry = is5Pro && bytes[0] == 0x89 && bytes[1] == 0x06 && bytes.count > 8
        if isBR64Telemetry || is5ProTelemetry {
            let coldC = Int(Int8(bitPattern: bytes[4]))
            let hotC = Int(Int8(bitPattern: bytes[5]))
            let fanRPM = Int(bytes[6]) | (Int(bytes[7]) << 8)
            let watts: Int? = (isBR64Telemetry && bytes.count > 8) ? Int(bytes[8]) : nil
            let vinTier: Int? = (isBR64Telemetry && bytes.count > 9) ? Int(bytes[9]) : nil
            if let vinTier {
                latestInputVoltsTier = vinTier
            }

            let telemetry = CoolerTelemetry(
                coldC: coldC,
                hotC: hotC,
                ambientC: 0,
                fanRPM: fanRPM,
                watts: watts,
                inputVoltsTier: vinTier
            )
            return .telemetry(telemetry)
        }

        // 2. BR64 query state reports (`bytes[2] == 0x08` only; `0x00` frames are write ACKs)
        if is6Max {
            if bytes[1] == 0x05 && bytes[2] == 0x08 && bytes.count >= 6 {
                let modeByte = bytes[4]
                let gear = bytes[5]
                reportedWorkMode = BR64WorkMode(rawValue: modeByte)
                reportedWorkGear = gear
                switch modeByte {
                case BR64WorkMode.overclock.rawValue:
                    return .mode(.max)
                case BR64WorkMode.ai.rawValue:
                    return .mode(.medium)
                case BR64WorkMode.silent.rawValue:
                    return .mode(.low)
                case BR64WorkMode.custom.rawValue:
                    if gear >= 5 { return .mode(.max) }
                    if gear >= 3 { return .mode(.medium) }
                    return .mode(.low)
                default:
                    return .none
                }
            }
            if bytes[1] == 0x07 && bytes[2] == 0x08 && bytes.count >= 5 {
                return bytes[4] == 0x01 ? .mode(.off) : .none
            }
        }

        // 3. MagCooler 4 Pro Telemetry frame (06 00)
        if !usesV2Protocol && bytes[1] == 0x06 && bytes[2] == 0x00 {
            guard bytes.count > 7 else { return .none }
            let coldC = Int(Int8(bitPattern: bytes[5]))
            let hotC = Int(Int8(bitPattern: bytes[7]))

            let telemetry = CoolerTelemetry(
                coldC: coldC,
                hotC: hotC,
                ambientC: 0,
                fanRPM: nil
            )
            return .telemetry(telemetry)
        }

        // 4. Fan status report (02 10)
        if bytes[1] == 0x02 && bytes[2] == 0x10, bytes.count > 4 {
            let speed = max(0, min(100, 100 - Int(bytes[4])))
            return .fan(UInt8(speed))
        }

        return .none
    }

    func handleCharacteristicUpdate(characteristic: CBCharacteristic, peripheral: CBPeripheral) -> DriverUpdate {
        let isReadChar = characteristic.uuid == readCharacteristicUUID
            || characteristic.uuid == Self.sigReadCharacteristicUUID
            || characteristic.uuid.uuidString.lowercased().contains("a002")
        guard isReadChar, let data = characteristic.value else { return .none }
        let update = parseUpdate([UInt8](data))
        if case .telemetry = update {
            reapplyDesiredCoolingIfNeeded(peripheral: peripheral)
        }
        return update
    }

    func disconnect() {
        telemetryPollTimer?.invalidate()
        telemetryPollTimer = nil
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingLightWorkItem?.cancel()
        pendingLightWorkItem = nil
        initQueryWorkItems.forEach { $0.cancel() }
        initQueryWorkItems.removeAll()
        desiredMode = nil
        desiredFanPercent = nil
        lastAppliedCommands = nil
        lastLightingModeByte = nil
        latestInputVoltsTier = nil
        reportedWorkMode = nil
        reportedWorkGear = nil
        writeChar = nil
        readChar = nil
        peripheral = nil
    }
}
