import AppKit

/// Unified Hardware Deck (Upper Half): Brand header, Mac thermal state and die temperature.
///
/// Shares a continuous rounded panel with `CoolerPanelView` directly below it,
/// forming a unified hardware status card with zero vertical clutter and no text collision.
final class StatusCardView: PanelRowView {

    static let cardHeight: CGFloat = 68
    static var height: CGFloat { cardHeight }

    struct ViewModel {
        var dieTempC: Double?
        var thermalState: ThermalState = .nominal
        var cpuTempC: Double? = nil
        var gpuTempC: Double? = nil
        var socTempC: Double? = nil
        var batteryTempC: Double? = nil
        var storageTempC: Double? = nil
    }

    private var model = ViewModel()

    // ── Metrics ──────────────────────────────────────────────────────────────
    private static let pad = UIStyle.panelContentX
    private static let logoSize: CGFloat = 16
    private static let headerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let tempFont = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .medium)
    private static let modelFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    private static let stateFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let subFont = NSFont.systemFont(ofSize: 10, weight: .regular)

    private static let versionText: String? =
        "v\((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "3.1")"

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.cardHeight))
        autoresizingMask = .width
        panelSegment = .top
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func update(_ model: ViewModel) {
        self.model = model
        var tipParts: [String] = []
        if let cpu = model.cpuTempC { tipParts.append("CPU: \(String(format: "%.1f°C", cpu))") }
        if let gpu = model.gpuTempC { tipParts.append("GPU: \(String(format: "%.1f°C", gpu))") }
        if let soc = model.socTempC { tipParts.append("SoC: \(String(format: "%.1f°C", soc))") }
        if let bat = model.batteryTempC { tipParts.append("Bateria: \(String(format: "%.1f°C", bat))") }
        if let ssd = model.storageTempC { tipParts.append("SSD: \(String(format: "%.1f°C", ssd))") }
        self.toolTip = tipParts.isEmpty ? nil : tipParts.joined(separator: "  ·  ")
        needsDisplay = true
    }

    // ── Drawing ──────────────────────────────────────────────────────────────

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let pad = Self.pad

        // 1. Top Header Row (y = 10): App Brand on left, Version on right
        let topY: CGFloat = 10
        RedMagicLogo.drawR(in: NSRect(x: pad, y: topY + 1, width: Self.logoSize, height: Self.logoSize))

        let title = UIStyle.text("Smart Cooler Control", Self.headerFont, .labelColor)
        let titleX = pad + Self.logoSize + 7
        title.draw(at: NSPoint(x: titleX, y: topY))

        if let versionText = Self.versionText {
            let version = UIStyle.text(versionText, Self.subFont, .tertiaryLabelColor)
            let vX = bounds.width - pad - version.size().width
            version.draw(at: NSPoint(x: vX, y: topY + 1))
        }

        // 2. Metrics Row (y = 30): Large Temp on left, Mac Model & State stacked on right
        let tempY: CGFloat = 30
        let tempStr = SystemInfo.formatTemp(model.dieTempC)
        let tempColor = UIStyle.textHeatColor(model.dieTempC)
        let tempText = UIStyle.text(tempStr, Self.tempFont, tempColor)
        tempText.draw(at: NSPoint(x: pad, y: tempY))

        let tempWidth = tempText.size().width
        let labelX = pad + tempWidth + 8

        if let cpu = model.cpuTempC, let gpu = model.gpuTempC {
            // Dual Silicon Telemetry (Apple Silicon Package):
            let isGpuHotter = gpu > cpu + 1.0
            let headerText = isGpuHotter ? "GPU Peak" : "SoC / Die"
            let headerColor: NSColor = isGpuHotter ? .systemOrange : .tertiaryLabelColor
            UIStyle.text(headerText, Self.subFont, headerColor).draw(at: NSPoint(x: labelX, y: tempY + 1))

            let cpuInt = Int(round(cpu))
            let gpuInt = Int(round(gpu))
            let breakdown = "CPU \(cpuInt)° · GPU \(gpuInt)°"
            UIStyle.text(breakdown, Self.subFont, .secondaryLabelColor).draw(at: NSPoint(x: labelX, y: tempY + 15))
        } else {
            let labelY = tempY + 10
            let tempLabel = UIStyle.text("Die / CPU", Self.subFont, .tertiaryLabelColor)
            tempLabel.draw(at: NSPoint(x: labelX, y: labelY))
        }

        // Right side: Mac Model (top) and Thermal State dot (bottom)
        let modelText = UIStyle.text(SystemInfo.macModel, Self.modelFont, .secondaryLabelColor)
        let modelX = bounds.width - pad - modelText.size().width
        modelText.draw(at: NSPoint(x: modelX, y: tempY + 2))

        let stateColor = thermalColor(model.thermalState)
        let stateStr = "● \(model.thermalState.rawValue.capitalized)"
        let stateText = UIStyle.text(stateStr, Self.stateFont, stateColor)
        let stateX = bounds.width - pad - stateText.size().width
        stateText.draw(at: NSPoint(x: stateX, y: tempY + 16))
    }

    private func thermalColor(_ state: ThermalState) -> NSColor {
        switch state {
        case .nominal:  return .systemGreen
        case .fair:     return .systemYellow
        case .serious:  return .systemOrange
        case .critical: return .systemRed
        }
    }
}
