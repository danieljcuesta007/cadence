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

// WavWriter — 16 kHz mono i16 → in-memory WAV, for §24 retained-audio blobs. Kept
// dependency-free (44-byte canonical header + PCM) so encoding never touches AVFoundation
// on the store queue.
enum WavWriter {
    static func data(from samples: [Int16], sampleRate: UInt32 = 16_000) -> Data {
        let dataBytes = UInt32(samples.count * 2)
        var out = Data(capacity: 44 + Int(dataBytes))
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataBytes)
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        u32(16)                       // PCM fmt chunk size
        u16(1)                        // PCM
        u16(1)                        // mono
        u32(sampleRate)
        u32(sampleRate * 2)           // byte rate
        u16(2)                        // block align
        u16(16)                       // bits per sample
        out.append(contentsOf: Array("data".utf8))
        u32(dataBytes)
        samples.withUnsafeBufferPointer { buf in
            buf.baseAddress.map { out.append(UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), count: Int(dataBytes)) }
        }
        return out
    }
}
