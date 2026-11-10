import AppKit

/// A menu row holding a caption, the current value and a slider. Values snap to `step`.
@MainActor
final class SliderRow: NSView {
    /// Called with the snapped value on every movement of the slider.
    var onChange: ((Int) -> Void)?

    private let caption: NSTextField
    private let readout = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private let step: Int
    private let format: (Int) -> String

    /// Where AppKit puts the titles of the menu's other items (the menu has a checkmark
    /// column), and where its separators end on the right.
    private static let leading: CGFloat = 28
    private static let trailing: CGFloat = 14

    init(title: String, range: ClosedRange<Int>, step: Int, format: @escaping (Int) -> String) {
        caption = NSTextField(labelWithString: title)
        slider = NSSlider(
            value: Double(range.lowerBound), minValue: Double(range.lowerBound),
            maxValue: Double(range.upperBound), target: nil, action: nil)
        self.step = step
        self.format = format
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 48))
        autoresizingMask = .width

        let inner = NSRect(
            x: Self.leading, y: 0, width: bounds.width - Self.leading - Self.trailing,
            height: bounds.height)
        caption.font = .menuFont(ofSize: 0)
        caption.frame = NSRect(x: inner.minX, y: 26, width: inner.width / 2, height: 18)
        caption.autoresizingMask = .maxXMargin

        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        readout.frame = NSRect(x: inner.midX, y: 26, width: inner.width / 2, height: 18)
        readout.autoresizingMask = .minXMargin

        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        slider.frame = NSRect(x: inner.minX, y: 4, width: inner.width, height: 20)
        slider.autoresizingMask = .width
        slider.setAccessibilityLabel(title)

        addSubview(caption)
        addSubview(readout)
        addSubview(slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `value` (nil while it isn't known yet) without reporting a change.
    func show(_ value: Int?, enabled: Bool) {
        slider.isEnabled = enabled
        caption.textColor = enabled ? .labelColor : .disabledControlTextColor
        guard let value else {
            readout.stringValue = "—"
            return
        }
        let snapped = snap(Double(value))
        slider.doubleValue = Double(snapped)
        readout.stringValue = format(snapped)
    }

    private func snap(_ value: Double) -> Int {
        let snapped = Int((value / Double(step)).rounded()) * step
        return min(max(snapped, Int(slider.minValue)), Int(slider.maxValue))
    }

    @objc private func moved() {
        let value = snap(slider.doubleValue)
        guard format(value) != readout.stringValue else { return }   // same step as last time
        readout.stringValue = format(value)
        onChange?(value)
    }
}
