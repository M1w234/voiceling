import AppKit
import Combine

/// Compact in-menu volume control for Yaprflow's start/stop confirmation
/// sounds. NSSound's volume is per sound, so this never changes system volume.
@MainActor
final class SoundVolumeMenuItemView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "Volume")
    private let slider = NSSlider(
        value: Double(AppState.shared.soundEffectsVolume),
        minValue: 0,
        maxValue: 1,
        target: nil,
        action: nil
    )
    private let valueField = NSTextField(labelWithString: "")
    private var cancellable: AnyCancellable?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        autoresizingMask = [.width]
        setupLayout()

        cancellable = AppState.shared.$soundEffectsVolume
            .receive(on: RunLoop.main)
            .sink { [weak self] volume in
                self?.refresh(volume)
            }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 34)
    }

    private func setupLayout() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(
            systemSymbolName: "speaker.wave.2",
            accessibilityDescription: "Sound effect volume"
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .regular
        )
        addSubview(iconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.menuFont(ofSize: 0)
        addSubview(titleField)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.controlSize = .small
        slider.isContinuous = true
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = false
        slider.target = self
        slider.action = #selector(volumeChanged(_:))
        slider.toolTip = "Changes only Yaprflow's start and stop sounds."
        slider.setAccessibilityLabel("Sound effect volume")
        addSubview(slider)

        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        valueField.textColor = .secondaryLabelColor
        valueField.alignment = .right
        addSubview(valueField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.widthAnchor.constraint(equalToConstant: 48),

            slider.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),

            valueField.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.widthAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func refresh(_ volume: Float) {
        let clamped = min(max(volume, 0), 1)
        if abs(slider.floatValue - clamped) > 0.001 {
            slider.floatValue = clamped
        }
        valueField.stringValue = "\(Int((clamped * 100).rounded()))%"
        slider.setAccessibilityValue(valueField.stringValue)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        AppState.shared.soundEffectsVolume = sender.floatValue
    }
}
