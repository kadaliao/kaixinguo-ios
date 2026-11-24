import AVFoundation
import MediaToolbox
import Synchronization

/// AudioBoost turns the sound of the episode up past what the system's
/// volume does at its loudest, up to `AudioBoost.most`: a gain on its
/// samples, through an audio tap on the item, the loudest of them rounded
/// off rather than clipped. It plays only on this device: AirPlay takes the
/// sound before it.
final class AudioBoost: Sendable {
    /// The most it turns the sound up by.
    static let most: Float = 1.5

    private let gain = Atomic<UInt32>(Float(1).bitPattern)
    fileprivate let float = Atomic<Bool>(false) // whether the tap's samples are 32-bit floats

    var value: Float {
        get { Float(bitPattern: gain.load(ordering: .relaxed)) }
        set { gain.store(min(max(newValue, 1), Self.most).bitPattern, ordering: .relaxed) }
    }

    /// Puts the tap on the item's sound, once its tracks are known.
    @MainActor func attach(to item: AVPlayerItem) async {
        guard item.audioMix == nil,
              let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
              let tap = makeTap() else { return }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    private func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: nil, process: tapProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged.passUnretained(self).release() // the tap that would have
            return nil
        }
        return tap
    }

    fileprivate static func from(_ tap: MTAudioProcessingTap) -> AudioBoost {
        Unmanaged<AudioBoost>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storage in
    storage.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<AudioBoost>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let f = format.pointee
    AudioBoost.from(tap).float.store(f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        && f.mBitsPerChannel == 32, ordering: .relaxed)
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, buffers, framesOut, flagsOut in
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
    let boost = AudioBoost.from(tap)
    let g = boost.value
    guard g > 1.001, boost.float.load(ordering: .relaxed) else { return }
    for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
        guard let p = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        for i in 0..<n {
            p[i] = soften(p[i] * g)
        }
    }
}

/// A sample turned up, its loudest rounded off toward full scale instead
/// of clipped: unchanged up to the knee, then bending into ±1.
@inline(__always) func soften(_ x: Float) -> Float {
    let knee: Float = 0.8
    let a = abs(x)
    guard a > knee else { return x }
    let over = (a - knee) / (1 - knee)
    let y = knee + (1 - knee) * tanh(over)
    return x < 0 ? -y : y
}
