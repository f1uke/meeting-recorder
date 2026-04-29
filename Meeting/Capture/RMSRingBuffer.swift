import Foundation
import AVFoundation
import os

/// Lock-protected ring of recent normalized-RMS samples (0...1).
///
/// Audio render threads push samples; SwiftUI views call `snapshot()` each
/// frame from the main thread. `OSAllocatedUnfairLock` keeps the critical
/// section tight enough that the audio thread never blocks meaningfully —
/// the lock is held only for a couple of array operations.
final class RMSRingBuffer: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<[Float]>
    let capacity: Int

    init(capacity: Int = 96) {
        self.capacity = capacity
        self.lock = OSAllocatedUnfairLock(initialState: Array(repeating: 0, count: capacity))
    }

    /// Append a new sample, dropping the oldest. Called from audio threads.
    func push(_ value: Float) {
        lock.withLock { samples in
            samples.removeFirst()
            samples.append(value)
        }
    }

    /// Read the current buffer. Pass `last:` to take only the most recent
    /// N samples (e.g. 24 for popover, 96 for the recording window).
    func snapshot(last n: Int? = nil) -> [Float] {
        lock.withLock { samples in
            guard let n, n < samples.count else { return samples }
            return Array(samples.suffix(n))
        }
    }

    /// Zero out the ring — called at the start of every recording so the
    /// previous session's tail doesn't bleed into the new visualization.
    func reset() {
        lock.withLock { samples in
            for i in samples.indices { samples[i] = 0 }
        }
    }

    /// Peak in dB across the current buffer — for the small "−12dB" readout
    /// next to each waveform.
    func peakDB() -> Float {
        let peak = snapshot().max() ?? 0
        guard peak > 0.0001 else { return -60 }
        // The buffer holds normalized-to-0...1 values from `computeNormalized`.
        // Inverting: db = (peak * 60) - 60.
        return peak * 60 - 60
    }

    /// Compute a normalized 0...1 RMS value from a PCM buffer. The mapping is
    /// log-scaled (−60 dB → 0, 0 dB → 1) so quiet voice still shows a bar
    /// instead of bottoming out near zero.
    static func computeNormalized(buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        let channelCount = Int(buffer.format.channelCount)
        var sumSquares: Float = 0
        var samples: Int = 0
        for c in 0..<channelCount {
            let ch = channels[c]
            for i in 0..<frameCount {
                let v = ch[i]
                sumSquares += v * v
            }
            samples += frameCount
        }
        guard samples > 0 else { return 0 }
        let rms = sqrt(sumSquares / Float(samples))
        return Self.normalize(rms: rms)
    }

    /// Compute normalized RMS from a raw 16-bit interleaved PCM buffer
    /// (int16 little-endian) — convenience for taps that don't expose a
    /// Float32 PCMBuffer directly.
    static func computeNormalized(int16Bytes ptr: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sumSquares: Float = 0
        let scale: Float = 1.0 / Float(Int16.max)
        for i in 0..<count {
            let v = Float(ptr[i]) * scale
            sumSquares += v * v
        }
        let rms = sqrt(sumSquares / Float(count))
        return Self.normalize(rms: rms)
    }

    private static func normalize(rms: Float) -> Float {
        let safe = max(rms, 1e-6)
        let db = 20 * log10(safe)
        return max(0, min(1, (db + 60) / 60))
    }
}
