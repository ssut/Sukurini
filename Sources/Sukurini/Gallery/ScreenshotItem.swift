import AppKit

final class ScreenshotItemView: NSView {

    var onDoubleClick: (() -> Void)?

    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            needsDisplay = true
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.55).cgColor
        layer.borderWidth = isActive ? 3 : 0
        layer.borderColor = isActive ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard event.clickCount == 2 else { return }
        onDoubleClick?()
    }
}

final class GallerySectionHeaderView: NSView, NSCollectionViewElement {

    static let identifier = NSUserInterfaceItemIdentifier("sukurini.sectionHeader")
    static let height: CGFloat = 30
    static let leadingInset: CGFloat = 20

    private let backdrop = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildSubviews()
    }

    override var isFlipped: Bool { true }

    func configure(title: String) {
        guard label.stringValue != title else { return }
        label.stringValue = title
    }

    private func buildSubviews() {
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .headerView
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        addSubview(backdrop)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GallerySectionHeaderView.leadingInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -GallerySectionHeaderView.leadingInset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }
}

final class ScreenshotItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("sukurini.screenshotItem")
    static let defaultSize = NSSize(width: 180, height: 124)
    static let imageInset: CGFloat = 5

    private enum Badge {
        static let size = NSSize(width: 24, height: 16)
        static let margin: CGFloat = 10
        static let glyphPointSize: CGFloat = 8
    }

    private(set) var representedURL: URL?
    private weak var loader: ThumbnailLoader?
    private var maxPixel: Int = 0
    private var videoBadge: NSView?

    var onOpen: ((URL) -> Void)?

    override func loadView() {
        let container = ScreenshotItemView(
            frame: NSRect(origin: .zero, size: ScreenshotItem.defaultSize)
        )
        container.wantsLayer = true

        let inset = ScreenshotItem.imageInset
        let thumbnail = NSImageView(frame: container.bounds.insetBy(dx: inset, dy: inset))
        thumbnail.autoresizingMask = [.width, .height]
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.imageAlignment = .alignCenter
        thumbnail.animates = false
        thumbnail.isEditable = false
        thumbnail.wantsLayer = true
        container.addSubview(thumbnail)

        let badge = makeVideoBadge()
        container.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Badge.margin),
            badge.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Badge.margin),
            badge.widthAnchor.constraint(equalToConstant: Badge.size.width),
            badge.heightAnchor.constraint(equalToConstant: Badge.size.height)
        ])
        videoBadge = badge

        container.onDoubleClick = { [weak self] in
            guard let self, let url = self.representedURL else { return }
            let name = url.lastPathComponent
            Log.gallery.info("item double clicked file=\(name, privacy: .public)")
            self.onOpen?(url)
        }

        view = container
        imageView = thumbnail
    }

    private func makeVideoBadge() -> NSView {
        let badge = NSView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.isHidden = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.layer?.cornerRadius = Badge.size.height / 2
        badge.layer?.cornerCurve = .continuous

        let glyph = NSImageView()
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Badge.glyphPointSize, weight: .bold)
        glyph.contentTintColor = .white
        badge.addSubview(glyph)

        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        return badge
    }

    override var isSelected: Bool {
        didSet { refreshActiveState() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { refreshActiveState() }
    }

    func configure(with url: URL, loader: ThumbnailLoader, maxPixel: Int) {
        representedURL = url
        self.loader = loader
        self.maxPixel = maxPixel
        videoBadge?.isHidden = !ScreenshotFile.isVideo(url)

        if let cached = loader.cachedThumbnail(for: url, maxPixel: maxPixel) {
            imageView?.image = cached
            return
        }

        imageView?.image = nil
        loader.thumbnail(for: url, maxPixel: maxPixel, lowPriority: false) { [weak self] responded, image in
            guard let self else { return }
            guard self.representedURL == responded else { return }
            self.imageView?.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let url = representedURL {
            loader?.cancel(url: url, maxPixel: maxPixel)
        }
        representedURL = nil
        imageView?.image = nil
        videoBadge?.isHidden = true
        refreshActiveState()
    }

    private func refreshActiveState() {
        guard let container = view as? ScreenshotItemView else { return }
        container.isActive = isSelected || highlightState == .forSelection
    }
}
