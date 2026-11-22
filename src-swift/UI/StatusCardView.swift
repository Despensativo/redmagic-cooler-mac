import AppKit

/// Unified Hardware Deck (Upper Half): Brand header, Mac thermal state, driving die
/// temperature, and rolling 10-minute telemetry table (CPU, GPU, Battery, SSD).
///
/// Shares a continuous rounded panel with `CoolerPanelView` directly below it,
/// forming a unified hardware status card with tabular monospaced alignment.
final class StatusCardView: PanelRowView {

    static let compactHeight: CGFloat = 68
    static var height: CGFloat { compactHeight }

    struct ViewModel {
        var dieTempC: Double?
        var thermalState: ThermalState = .nominal
        var cpuTempC: Double? = nil
        var gpuTempC: Double? = nil
        var socTempC: Double? = nil
        var batteryTempC: Double? = nil
        var storageTempC: Double? = nil
        var history: ThermalHistorySnapshot? = nil
    }

    private enum SensorKind {
        case cpu, gpu, battery, storage
    }

    private struct TableRow {
        let label: String
        let stats: ThermalStats
        let kind: SensorKind
    }

    private var model = ViewModel()
    private var tableRows: [TableRow] = []

    // ── Metrics ──────────────────────────────────────────────────────────────
    private static let pad = UIStyle.panelContentX
    private static let logoSize: CGFloat = 16
    private static let dividerY: CGFloat = 66
    private static let tableHeaderY: CGFloat = 72
    private static let tableFirstRowY: CGFloat = 87
    private static let tableRowPitch: CGFloat = 16
    private static let tableBottomPad: CGFloat = 7

    private static let headerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let tempFont = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .medium)
    private static let modelFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    private static let stateFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let subFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    private static let subMediumFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let subMonoFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)

    private static let colHeaderFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    private static let rowLabelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let rowCurrentFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let rowAvgFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private static let rowStatFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    private static let versionText: String? =
        "v\((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "3.1")"

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.compactHeight))
        autoresizingMask = .width
        panelSegment = .top
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func update(_ model: ViewModel) {
        self.model = model
        self.tableRows = buildRows(from: model)

        let targetHeight = Self.height(forRowCount: tableRows.count)
        if abs(frame.size.height - targetHeight) > 0.5 {
            frame.size.height = targetHeight
        }

        var tipParts: [String] = []
        if let cpu = model.cpuTempC { tipParts.append("CPU: \(String(format: "%.1f°C", cpu))") }
        if let gpu = model.gpuTempC { tipParts.append("GPU: \(String(format: "%.1f°C", gpu))") }
        if let soc = model.socTempC { tipParts.append("SoC: \(String(format: "%.1f°C", soc))") }
        if let bat = model.batteryTempC { tipParts.append("Bateria: \(String(format: "%.1f°C", bat))") }
        if let ssd = model.storageTempC { tipParts.append("SSD: \(String(format: "%.1f°C", ssd))") }
        self.toolTip = tipParts.isEmpty ? nil : tipParts.joined(separator: "  ·  ")
        needsDisplay = true
    }

    private static func height(forRowCount count: Int) -> CGFloat {
        guard count > 0 else { return compactHeight }
        return tableFirstRowY + CGFloat(count) * tableRowPitch + tableBottomPad
    }

    private func buildRows(from model: ViewModel) -> [TableRow] {
        var rows: [TableRow] = []

        func resolve(_ stat: ThermalStats?, fallback: Double?) -> ThermalStats? {
            if let stat { return stat }
            guard let fallback else { return nil }
            return ThermalStats(current: fallback, min: fallback, avg: fallback, max: fallback)
        }

        if let s = resolve(model.history?.cpu, fallback: model.cpuTempC) {
            rows.append(TableRow(label: "CPU", stats: s, kind: .cpu))
        }
        if let s = resolve(model.history?.gpu, fallback: model.gpuTempC) {
            rows.append(TableRow(label: "GPU", stats: s, kind: .gpu))
        }
        if let s = resolve(model.history?.battery, fallback: model.batteryTempC) {
            rows.append(TableRow(label: "Bateria", stats: s, kind: .battery))
        }
        if let s = resolve(model.history?.storage, fallback: model.storageTempC) {
            rows.append(TableRow(label: "SSD", stats: s, kind: .storage))
        }
        return rows
    }

    // ── Drawing ──────────────────────────────────────────────────────────────

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let pad = Self.pad
        let rightEdge = bounds.width - pad

        // 1. Top Header Row (y = 10): App Brand on left, Version on right
        let topY: CGFloat = 10
        RedMagicLogo.drawR(in: NSRect(x: pad, y: topY + 1, width: Self.logoSize, height: Self.logoSize))

        let title = UIStyle.text("Smart Cooler Control", Self.headerFont, .labelColor)
        let titleX = pad + Self.logoSize + 7
        title.draw(at: NSPoint(x: titleX, y: topY))

        if let versionText = Self.versionText {
            let version = UIStyle.text(versionText, Self.subFont, .tertiaryLabelColor)
            version.draw(at: NSPoint(x: rightEdge - version.size().width, y: topY + 1))
        }

        // 2. Metrics Row (y = 29): Large Temp on left, Mac Model & State stacked on right
        let tempY: CGFloat = 29
        let tempStr = SystemInfo.formatTemp(model.dieTempC)
        let tempColor = UIStyle.textHeatColor(model.dieTempC)
        let tempText = UIStyle.text(tempStr, Self.tempFont, tempColor)
        tempText.draw(at: NSPoint(x: pad, y: tempY))

        let labelX = pad + tempText.size().width + 8
        let isGpuHotter: Bool = {
            guard let cpu = model.cpuTempC, let gpu = model.gpuTempC else { return false }
            return gpu > cpu + 1.0
        }()

        let chipLabel: String
        if isGpuHotter {
            chipLabel = SystemInfo.shortChipName.map { "\($0) · GPU" } ?? "GPU"
        } else {
            chipLabel = SystemInfo.chipName ?? "CPU"
        }

        if let dieStats = model.history?.die {
            let roleColor: NSColor = isGpuHotter ? .systemOrange : .secondaryLabelColor
            let roleFont = isGpuHotter ? Self.stateFont : Self.subMediumFont
            UIStyle.text(chipLabel, roleFont, roleColor)
                .draw(at: NSPoint(x: labelX, y: tempY + 3))

            let avgStr = SystemInfo.formatTemp(dieStats.avg, degreeOnly: true)
            let winMin = model.history?.windowMinutes ?? 10
            UIStyle.text("Méd \(avgStr) · \(winMin)m", Self.subMonoFont, .tertiaryLabelColor)
                .draw(at: NSPoint(x: labelX, y: tempY + 16))
        } else {
            UIStyle.text(chipLabel, Self.subMediumFont, .secondaryLabelColor)
                .draw(at: NSPoint(x: labelX, y: tempY + 10))
        }

        // Right side: Mac Model (top) and Thermal State dot (bottom)
        let modelText = UIStyle.text(SystemInfo.macModel, Self.modelFont, .secondaryLabelColor)
        modelText.draw(at: NSPoint(x: rightEdge - modelText.size().width, y: tempY + 3))

        let stateColor = thermalColor(model.thermalState)
        let stateStr = "● \(model.thermalState.rawValue.capitalized)"
        let stateText = UIStyle.text(stateStr, Self.stateFont, stateColor)
        stateText.draw(at: NSPoint(x: rightEdge - stateText.size().width, y: tempY + 17))

        // 3. Rolling 10-Minute Sensor Table
        guard !tableRows.isEmpty else { return }

        let divRect = NSRect(x: pad, y: Self.dividerY, width: rightEdge - pad, height: 1)
        NSColor.separatorColor.withAlphaComponent(0.10).setFill()
        divRect.fill()

        // Column right-aligned anchors (46pt pitch guarantees generous whitespace)
        let colMaxX = rightEdge
        let colAvgX = rightEdge - 46
        let colMinX = rightEdge - 92
        let colCurX = rightEdge - 140

        let winMin = model.history?.windowMinutes ?? 10
        UIStyle.text("Sensor (\(winMin)m)", Self.colHeaderFont, .tertiaryLabelColor)
            .draw(at: NSPoint(x: pad, y: Self.tableHeaderY))
        drawRightAligned("Atual", Self.colHeaderFont, .tertiaryLabelColor, rightX: colCurX, y: Self.tableHeaderY)
        drawRightAligned("Mín", Self.colHeaderFont, .tertiaryLabelColor, rightX: colMinX, y: Self.tableHeaderY)
        drawRightAligned("Méd", Self.colHeaderFont, .tertiaryLabelColor, rightX: colAvgX, y: Self.tableHeaderY)
        drawRightAligned("Máx", Self.colHeaderFont, .tertiaryLabelColor, rightX: colMaxX, y: Self.tableHeaderY)

        for (index, row) in tableRows.enumerated() {
            let y = Self.tableFirstRowY + CGFloat(index) * Self.tableRowPitch

            UIStyle.text(row.label, Self.rowLabelFont, .secondaryLabelColor)
                .draw(at: NSPoint(x: pad, y: y))

            let curStr = SystemInfo.formatTemp(row.stats.current, degreeOnly: true)
            let minStr = SystemInfo.formatTemp(row.stats.min, degreeOnly: true)
            let avgStr = SystemInfo.formatTemp(row.stats.avg, degreeOnly: true)
            let maxStr = SystemInfo.formatTemp(row.stats.max, degreeOnly: true)

            drawRightAligned(curStr, Self.rowCurrentFont, currentColor(for: row.kind, valueC: row.stats.current),
                             rightX: colCurX, y: y)
            drawRightAligned(minStr, Self.rowStatFont, .tertiaryLabelColor,
                             rightX: colMinX, y: y)
            drawRightAligned(avgStr, Self.rowAvgFont, .secondaryLabelColor,
                             rightX: colAvgX, y: y)
            drawRightAligned(maxStr, Self.rowStatFont, maxColor(for: row.kind, valueC: row.stats.max),
                             rightX: colMaxX, y: y)
        }
    }

    private func drawRightAligned(_ string: String, _ font: NSFont, _ color: NSColor,
                                  rightX: CGFloat, y: CGFloat) {
        let attr = UIStyle.text(string, font, color)
        attr.draw(at: NSPoint(x: rightX - attr.size().width, y: y))
    }

    private func currentColor(for kind: SensorKind, valueC: Double) -> NSColor {
        switch kind {
        case .cpu, .gpu:
            return valueC > 65.0 ? UIStyle.textHeatColor(valueC) : .labelColor
        case .battery:
            if valueC >= 43.0 { return .systemRed }
            if valueC >= 38.0 { return .systemOrange }
            return .labelColor
        case .storage:
            if valueC >= 68.0 { return .systemRed }
            if valueC >= 55.0 { return .systemOrange }
            return .labelColor
        }
    }

    private func maxColor(for kind: SensorKind, valueC: Double) -> NSColor {
        switch kind {
        case .cpu, .gpu:
            return valueC >= 75.0 ? UIStyle.textHeatColor(valueC) : .tertiaryLabelColor
        case .battery:
            return valueC >= 40.0 ? .systemOrange : .tertiaryLabelColor
        case .storage:
            return valueC >= 60.0 ? .systemOrange : .tertiaryLabelColor
        }
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
