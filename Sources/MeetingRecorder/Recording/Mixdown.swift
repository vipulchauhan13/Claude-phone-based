import AVFoundation

/// Produces a second MP4 whose single audio track mixes microphone and system audio.
///
/// The primary recording keeps the two audio sources on separate tracks (needed for
/// per-speaker transcription), but many players only play the first audio track.
/// The mixed copy is the one to share with colleagues.
enum Mixdown {
    static func exportMixed(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: duration)

        for track in try await asset.loadTracks(withMediaType: .video) {
            guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(fullRange, of: track, at: .zero)
        }
        // Every audio track inserted into the composition is summed into one output track by the export session.
        for track in try await asset.loadTracks(withMediaType: .audio) {
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(fullRange, of: track, at: .zero)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecorderError.exportFailed
        }
        try? FileManager.default.removeItem(at: destination)
        export.outputURL = destination
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        await export.export()
        if let error = export.error { throw error }
        guard export.status == .completed else { throw RecorderError.exportFailed }
    }
}
