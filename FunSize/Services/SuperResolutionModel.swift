import Foundation
import Observation
import VideoToolbox

/// Tracks Apple's 4× enhancement model, which the system downloads once before first use.
@Observable
final class SuperResolutionModel {
    enum Status: Equatable {
        case unknown
        case unsupported
        case needsDownload
        case downloading(Double)
        case ready
        case failed(String)
    }

    static let shared = SuperResolutionModel()

    private(set) var status: Status = .unknown

    func refresh(for size: CGSize) {
        guard let config = configuration(for: size) else {
            status = .unsupported
            return
        }
        switch config.configurationModelStatus {
        case .ready: status = .ready
        case .downloading: watch(config)
        default: if case .downloading = status {} else { status = .needsDownload }
        }
    }

    func download(for size: CGSize) {
        guard let config = configuration(for: size) else {
            status = .unsupported
            return
        }
        status = .downloading(0)
        config.downloadConfigurationModel { error in
            let message = error?.localizedDescription
            Task { @MainActor in
                if let message {
                    SuperResolutionModel.shared.status = .failed(message)
                } else {
                    SuperResolutionModel.shared.status = .ready
                }
            }
        }
        watch(config)
    }

    /// Updates download progress until it finishes.
    private func watch(_ config: VTSuperResolutionScalerConfiguration) {
        status = .downloading(Double(config.configurationModelPercentageAvailable))
        Task {
            while case .downloading = status {
                try? await Task.sleep(for: .milliseconds(500))
                guard case .downloading = status else { break }
                if config.configurationModelStatus == .ready {
                    status = .ready
                } else {
                    status = .downloading(Double(config.configurationModelPercentageAvailable))
                }
            }
        }
    }

    private func configuration(for size: CGSize) -> VTSuperResolutionScalerConfiguration? {
        let even = Enhancer.evenSize(size)
        return Enhancer.bestScalerConfiguration(width: Int(even.width), height: Int(even.height))
    }
}
