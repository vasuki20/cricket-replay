import UIKit
import AVKit

private final class ReplaySurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// The same player and controls survive layout/rotation; capture remains foreground.
final class RecordingPlayer: UIViewController {
    private let player: AVPlayer
    private let surface = ReplaySurface()
    private let playButton = UIButton(type: .system)
    private let fitButton = UIButton(type: .system)
    private let speedButton = UIButton(type: .system)
    private let position = UILabel()
    private let seek = UISlider()
    private var observation: NSKeyValueObservation?
    private var ticker: Any?
    private var timeout: DispatchWorkItem?
    private var completion: ((String?) -> Void)?
    private var closed: (() -> Void)?
    private var speed: Float
    private var dragging = false
    private var backgroundPlaying = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var ready = false
    private var closing = false
    private var frames: (() -> Void)?
    private var wantsFrames = false
    private var overlays: [UIView] = []
    private var hideControls: DispatchWorkItem?
    @objc private func toggleControls() {
        let show = overlays.first?.isHidden ?? true
        overlays.forEach { $0.isHidden = !show }
        if show { scheduleHide() } else { hideControls?.cancel() }
    }
    private func scheduleHide() {
        hideControls?.cancel()
        let task = DispatchWorkItem { [weak self] in guard let self, !self.dragging else { return }; self.overlays.forEach { $0.isHidden = true } }
        hideControls = task; DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: task)
    }
    @objc private func switchFrames() { wantsFrames = true; closePlayer() }


    init(url: URL, rate: Float = 1, closed: (() -> Void)? = nil, frames: (() -> Void)? = nil, completion: @escaping (String?) -> Void) {
        player = AVPlayer(url: url); speed = rate; self.completion = completion; self.closed = closed; self.frames = frames
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError("Use init(url:completion:)") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }
    override func viewDidLoad() {
        super.viewDidLoad()
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.backgroundPlaying = self.player.rate != 0; self.player.pause()
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; if self.backgroundPlaying { self.player.playImmediately(atRate: self.speed) }; self.backgroundPlaying = false
        })
        view.backgroundColor = UIColor(red: 0.04, green: 0.07, blue: 0.05, alpha: 1)
        surface.backgroundColor = .black; surface.playerLayer.player = player; surface.playerLayer.videoGravity = .resizeAspect
        let title = UILabel(); title.text = "Video"; title.textColor = .white; title.font = .boldSystemFont(ofSize: 18)
        let close = UIButton(type: .system); close.setTitle("Close", for: .normal); close.addTarget(self, action: #selector(closePlayer), for: .touchUpInside)
        fitButton.setTitle("Fill", for: .normal); fitButton.addTarget(self, action: #selector(toggleFit), for: .touchUpInside)
        playButton.setTitle("Pause", for: .normal); playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        speedButton.setTitle("\(speed)×", for: .normal); speedButton.addTarget(self, action: #selector(changeSpeed), for: .touchUpInside)
        for button in [close, fitButton, playButton, speedButton] { button.tintColor = .white; button.backgroundColor = UIColor(red: 0.06, green: 0.14, blue: 0.11, alpha: 0.8); button.layer.cornerRadius = 22; button.layer.borderWidth = 1; button.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor; button.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true }
        position.textColor = .white; position.textAlignment = .center; position.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        let frameButton = UIButton(type: .system); frameButton.setTitle("Frames", for: .normal); frameButton.isHidden = frames == nil; frameButton.tintColor = .white; frameButton.backgroundColor = UIColor.black.withAlphaComponent(0.65); frameButton.layer.cornerRadius = 22; frameButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true; frameButton.addTarget(self, action: #selector(switchFrames), for: .touchUpInside)
        let top = UIStackView(arrangedSubviews: [title, frameButton, fitButton, close]); top.axis = .horizontal; top.alignment = .fill; top.spacing = 8
        let bottom = UIStackView(arrangedSubviews: [playButton, position, speedButton]); bottom.axis = .horizontal; bottom.alignment = .fill; bottom.spacing = 8
        seek.minimumValue = 0; seek.maximumValue = 1; seek.isEnabled = false; seek.accessibilityLabel = "Replay position"
        seek.addTarget(self, action: #selector(beginSeek), for: .touchDown)
        seek.addTarget(self, action: #selector(updateSeekLabel), for: .valueChanged)
        seek.addTarget(self, action: #selector(endSeek), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        overlays = [top, seek, bottom]
        for overlay in overlays { overlay.backgroundColor = UIColor.black.withAlphaComponent(0.65) }
        surface.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleControls)))
        for child in [surface, top, seek, bottom] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: safe.topAnchor), top.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16), top.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16), top.heightAnchor.constraint(equalToConstant: 48),
            surface.topAnchor.constraint(equalTo: view.topAnchor), surface.leadingAnchor.constraint(equalTo: view.leadingAnchor), surface.trailingAnchor.constraint(equalTo: view.trailingAnchor), surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            seek.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16), seek.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16), seek.heightAnchor.constraint(equalToConstant: 40), seek.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8), bottom.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8), bottom.bottomAnchor.constraint(equalTo: safe.bottomAnchor), bottom.heightAnchor.constraint(equalToConstant: 48)
        ])
        scheduleHide()
        observation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, !self.closing else { return }
                if item.status == .readyToPlay {
                    guard self.speed == 1 || item.canPlaySlowForward else { self.settle("Decoder does not support slow playback"); self.closePlayer(); return }
                    self.ready = true; self.seek.isEnabled = true; self.player.playImmediately(atRate: self.speed); self.settle(nil)
                } else if item.status == .failed { self.settle(item.error?.localizedDescription ?? "Recording playback failed"); self.closePlayer() }
            }
        }
        ticker = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in self?.updateControls() }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard completion != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.settle("Recording playback preparation timed out"); self?.closePlayer() }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }
    private var duration: Double { let seconds = player.currentItem?.duration.seconds ?? 0; return seconds.isFinite && seconds > 0 ? seconds : 0 }
    private func time(_ seconds: Double) -> String { let value = seconds.isFinite ? max(0, Int(seconds)) : 0; return String(format: "%d:%02d", value / 60, value % 60) }
    private func updateControls() {
        guard ready else { return }
        playButton.setTitle(player.rate == 0 ? "Play" : "Pause", for: .normal)
        guard !dragging else { return }
        let current = player.currentTime().seconds
        seek.value = duration > 0 && current.isFinite ? Float(current / duration) : 0
        position.text = "\(time(current)) / \(time(duration))"
    }
    @objc private func togglePlay() {
        scheduleHide()
        guard ready else { return }
        if player.rate != 0 { player.pause() }
        else {
            if player.currentTime().seconds >= duration - 0.05 { player.seek(to: .zero) }
            player.playImmediately(atRate: speed)
        }
        updateControls()
    }
    @objc private func toggleFit() {
        scheduleHide()
        let fill = surface.playerLayer.videoGravity == .resizeAspect
        surface.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        surface.clipsToBounds = true; fitButton.setTitle(fill ? "Fit" : "Fill", for: .normal)
    }
    @objc private func changeSpeed() {
        scheduleHide()
        guard ready else { return }
        let next: Float = speed == 1 ? 0.5 : speed == 0.5 ? 0.25 : 1
        guard next == 1 || player.currentItem?.canPlaySlowForward == true else { return }
        let playing = player.rate != 0; speed = next; speedButton.setTitle("\(speed)×", for: .normal)
        if playing { player.playImmediately(atRate: speed) }
    }
    @objc private func beginSeek() { dragging = true; hideControls?.cancel() }
    @objc private func updateSeekLabel() { position.text = "\(time(Double(seek.value) * duration)) / \(time(duration))" }
    @objc private func endSeek() {
        guard ready else { dragging = false; return }
        scheduleHide()
        player.seek(to: CMTime(seconds: Double(seek.value) * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in DispatchQueue.main.async { self?.dragging = false; self?.updateControls() } }
    }
    @objc private func closePlayer() {
        closing = true; player.pause()
        let presenter = presentingViewController
        dismiss(animated: true) {
            if let controller = presenter as? FeasibilityViewController, !controller.fullscreen, !self.wantsFrames {
                controller.updateOrientationPolicy()
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        closing = true; player.pause(); observation = nil
        if let ticker { player.removeTimeObserver(ticker) }; ticker = nil
        settle("Recording playback closed before preparation"); hideControls?.cancel(); closed?(); closed = nil
        if wantsFrames { frames?() }; frames = nil
        if let controller = presentingViewController as? FeasibilityViewController { controller.updateOrientationPolicy() }
    }
    deinit { lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }; timeout?.cancel(); if let ticker { player.removeTimeObserver(ticker) } }
    private func settle(_ error: String?) { timeout?.cancel(); timeout = nil; let done = completion; completion = nil; done?(error) }
}
