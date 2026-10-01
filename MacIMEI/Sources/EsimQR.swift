import Foundation
import Vision

enum EsimQR {
    static func read(_ url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 32 * 1024 * 1024 else { throw EsimFailure.invalidInput }
        let data = try Data(contentsOf: url)
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]; request.usesCPUOnly = true
        try VNImageRequestHandler(data: data, options: [:]).perform([request])
        let results = request.results ?? []
        guard results.allSatisfy({ $0.payloadStringValue != nil }) else { throw EsimFailure.invalidInput }
        return try EsimValidation.uniqueQR(results.compactMap(\.payloadStringValue))
    }
}
