//
//  PlanarAudio.swift
//  OpenBeam
//
//  The shape audio travels in between the network and the speakers.
//

import Foundation

/// One block of planar float audio, valid only for the duration of the call
/// that hands it over. It is the shape libndi delivers, described here so that
/// nothing about NDI reaches into the audio engine.
struct PlanarAudio {
    let data: UnsafePointer<Float>
    let frameCount: Int
    let channelCount: Int
    /// Distance between one channel and the next, in samples.
    let channelStride: Int
    let sampleRate: Double
}
