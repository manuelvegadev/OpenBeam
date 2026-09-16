//
//  AudioLevel.swift
//  OpenBeam
//
//  The level meter's one definition of "how loud is this".
//
//  Four audio paths feed the same meter — a microphone, a tapped output, a
//  received stream and the preview's proxy stream — and they arrive in three
//  different memory layouts. What the meter means is a property of the meter,
//  not of any one of them, so the peak is computed here and the clamp lives in
//  one place rather than four.
//

import AVFoundation
import Accelerate

enum AudioLevel {

    /// Peak sample magnitude, 0…1. Above 1 is possible — a tap is taken before
    /// the output's own limiting — and is clamped rather than reported, because
    /// the meter's scale ends there.
    static func peak(planar data: UnsafePointer<Float>, frames: Int, channels: Int, channelStride: Int) -> Float {
        var peak: Float = 0
        for channel in 0..<channels {
            var channelPeak: Float = 0
            vDSP_maxmgv(data + channel * channelStride, 1, &channelPeak, vDSP_Length(frames))
            if channelPeak > peak { peak = channelPeak }
        }
        return min(peak, 1)
    }

    /// For an interleaved buffer, where the channels cannot be told apart
    /// without walking them — and need not be, for a peak.
    static func peak(_ bufferList: UnsafePointer<AudioBufferList>) -> Float {
        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList)) {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var bufferPeak: Float = 0
            vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &bufferPeak, vDSP_Length(count))
            if bufferPeak > peak { peak = bufferPeak }
        }
        return min(peak, 1)
    }

    static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        peak(buffer.audioBufferList)
    }
}
