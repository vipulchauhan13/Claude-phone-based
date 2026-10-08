import CoreMedia

enum SampleBufferTiming {
    /// Returns a copy of `sampleBuffer` whose presentation timestamp is replaced by `presentationTime`.
    /// Used to move microphone samples onto the host clock that ScreenCaptureKit already uses,
    /// so every track in the output file shares one timeline.
    static func retimed(_ sampleBuffer: CMSampleBuffer, to presentationTime: CMTime) -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr, let copy else { return sampleBuffer }
        return copy
    }

    static func hostTimeNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }
}
