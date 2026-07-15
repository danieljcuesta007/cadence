// WavLoader — audio file → 16 kHz mono i16, for the WAV-injection selftest path.

import AVFoundation

enum WavLoader {
    static func load16kMono(_ path: String) throws -> [Int16] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else {
            throw CocoaError(.fileReadUnknown)
        }
        try file.read(into: inBuf)
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                interleaved: true),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw CocoaError(.fileReadUnknown) }
        let outCapacity =
            AVAudioFrameCount(Double(frames) * 16_000 / inFormat.sampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity)
        else { throw CocoaError(.fileReadUnknown) }
        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, let ch = outBuf.int16ChannelData else {
            throw convError ?? CocoaError(.fileReadUnknown)
        }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}
