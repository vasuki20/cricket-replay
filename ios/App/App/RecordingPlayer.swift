import UIKit
import AVKit

// Fullscreen controller keeps UIApplication active so foreground camera capture can continue.
final class RecordingPlayer: AVPlayerViewController {
    private var observation: NSKeyValueObservation?
    private var timeout: DispatchWorkItem?
    private var completion: ((String?) -> Void)?
    init(url: URL, completion: @escaping (String?) -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        let item = AVPlayerItem(url: url); player = AVPlayer(playerItem: item)
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.status == .readyToPlay { self.player?.play(); self.settle(nil) }
                else if item.status == .failed { self.settle(item.error?.localizedDescription ?? "Recording playback failed"); self.dismiss(animated: true) }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(url:completion:)") }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard completion != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.settle("Recording playback preparation timed out"); self?.dismiss(animated: true) }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); player?.pause(); observation = nil; settle("Recording playback closed before preparation")
    }
    private func settle(_ error: String?) { timeout?.cancel(); timeout = nil; let done = completion; completion = nil; done?(error) }
}
