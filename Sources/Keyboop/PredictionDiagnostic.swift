import Foundation

extension Notification.Name {
    static let predictionDiagnosticChanged = Notification.Name("KeyboopPredictionDiagnosticChanged")
}

/// Main-thread status for the settings preview. Only fixed localization keys are retained.
final class PredictionDiagnostic {
    static let shared = PredictionDiagnostic()
    private(set) var lastKey = "prediction.idle"

    private(set) var geometryKey: String?

    func record(_ key: String, geometry: String? = nil) {
        let localizedSource = geometry.map { "prediction.geometry." + $0 }
        guard lastKey != key || geometryKey != localizedSource else { return }
        geometryKey = localizedSource
        lastKey = key
        NotificationCenter.default.post(name: .predictionDiagnosticChanged, object: self)
    }
}
