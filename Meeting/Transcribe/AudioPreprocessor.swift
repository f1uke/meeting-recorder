import Foundation
import Accelerate

// In-memory float-array preprocessing for the mic stream before it reaches
// WhisperKit. Used to (1) cancel speaker echo when the user records via
// loud-speakers (output.m4a → reference signal), and (2) normalize quiet
// mic recordings so Whisper's mel front-end has enough dynamic range.
enum AudioPreprocessor {
    /// Boost gain so the peak amplitude reaches `targetDBFS`. No-op if
    /// the audio is already at/above target or essentially silent.
    static func peakNormalize(
        _ audio: inout [Float],
        targetDBFS: Float = -3
    ) -> (preDB: Float, postDB: Float) {
        guard !audio.isEmpty else { return (0, 0) }
        var peak: Float = 0
        vDSP_maxmgv(audio, 1, &peak, vDSP_Length(audio.count))
        let preDB = peak > 0 ? 20 * log10(peak) : -120
        guard peak > 1e-4 else { return (preDB, preDB) }
        let target = pow(10, targetDBFS / 20)
        guard target > peak else { return (preDB, preDB) }
        var gain = target / peak
        vDSP_vsmul(audio, 1, &gain, &audio, 1, vDSP_Length(audio.count))
        return (preDB, targetDBFS)
    }

    /// Find the integer sample shift S such that `reference[i+S]` is the
    /// best match for `mic[i]`. Returned shift is negative when the
    /// reference array starts later in real time than mic (the typical
    /// case here, since the Core Audio Tap is the last capture stream
    /// to come online and therefore lags the mic by 50–300 ms).
    ///
    /// Returns `nil` when the best correlation lies at the search-window
    /// boundary or its strength is indistinguishable from background —
    /// both signal that no real correlation exists (e.g. mic and reference
    /// are at different effective rates because of a sample-rate-tag bug
    /// in the source file). The caller should skip AEC on `nil`; running
    /// NLMS with a phantom shift makes the filter chase noise and diverge.
    static func findReferenceShift(
        mic: [Float],
        reference: [Float],
        searchSeconds: Double = 0.5,
        analysisSeconds: Double = 8,
        sampleRate: Double = 16000
    ) -> Int? {
        let maxShift = Int(searchSeconds * sampleRate)
        let window = min(mic.count, Int(analysisSeconds * sampleRate))
        guard window > 1000,
              reference.count > window + 2 * maxShift else { return nil }

        var bestCorr: Float = 0
        var bestShift = 0
        var sumCorr: Double = 0
        var samples = 0
        mic.withUnsafeBufferPointer { mPtr in
            reference.withUnsafeBufferPointer { rPtr in
                for shift in -maxShift...maxShift {
                    let refStart = maxShift + shift
                    guard refStart >= 0,
                          refStart + window <= reference.count else { continue }
                    var corr: Float = 0
                    vDSP_dotpr(
                        mPtr.baseAddress!, 1,
                        rPtr.baseAddress!.advanced(by: refStart), 1,
                        &corr,
                        vDSP_Length(window)
                    )
                    let absCorr = abs(corr)
                    sumCorr += Double(absCorr)
                    samples += 1
                    if absCorr > bestCorr {
                        bestCorr = absCorr
                        bestShift = shift
                    }
                }
            }
        }
        // Reject if best landed at the search boundary — usually means
        // there is no real correlation peak inside the window.
        if abs(bestShift) >= maxShift { return nil }
        // Reject if the peak isn't materially above the average — same
        // signal: cross-correlation surface is flat, no echo path to lock onto.
        if samples > 0 {
            let mean = Float(sumCorr / Double(samples))
            if bestCorr < mean * 2.5 { return nil }
        }
        return bestShift
    }

    /// Subtract an adaptive estimate of `reference`'s acoustic contribution
    /// from `mic`, using a Normalized LMS filter. When the user records
    /// through speakers, the meeting's audio bleeds into the mic; with the
    /// far-end signal in hand (output.m4a captured by the Core Audio Tap)
    /// this filter learns the room's impulse response on the fly and
    /// subtracts it so Whisper sees the user's voice with the speaker echo
    /// removed.
    ///
    /// Headphone users have ~zero correlation between mic and reference,
    /// so weights stay near zero and `mic` is effectively unchanged — safe
    /// to run unconditionally.
    ///
    /// `referenceShift` should be the sample-offset returned by
    /// `findReferenceShift` so the filter can find correlation within its
    /// finite history window.
    static func subtractEcho(
        mic: inout [Float],
        reference: [Float],
        referenceShift: Int,
        filterLen: Int = 1024,
        stepSize: Float = 0.05
    ) {
        let micCount = mic.count
        let refCount = reference.count
        guard micCount > filterLen, refCount > filterLen else { return }

        var weights = [Float](repeating: 0, count: filterLen)
        let mu = stepSize
        // Larger eps on the energy denominator so quiet reference windows
        // don't push the step size into runaway territory. With raw eps=1e-6,
        // a near-silent ref (energy ≈ 0) caused mu*error/eps to spike weights
        // by hundreds in a single sample, which then drove the predicted echo
        // to wildly negative values — and on the next iteration the error
        // would be huge in the opposite direction. The output mic peak then
        // exploded to ~+40 dBFS and Whisper hung on the resulting NaN-adjacent
        // values. 0.01 corresponds to a ref window with RMS around -23 dBFS,
        // below which we effectively freeze adaptation rather than chase noise.
        let eps: Float = 0.01

        weights.withUnsafeMutableBufferPointer { wPtr in
            reference.withUnsafeBufferPointer { rPtr in
                mic.withUnsafeMutableBufferPointer { mPtr in
                    for i in filterLen..<micCount {
                        // Reference window aligned to mic[i]: account for the
                        // measured shift between the two streams.
                        let refIndex = i + referenceShift
                        let refWinStart = refIndex - filterLen
                        guard refWinStart >= 0,
                              refIndex <= refCount else { continue }

                        let refWin = rPtr.baseAddress!.advanced(by: refWinStart)

                        var echo: Float = 0
                        vDSP_dotpr(
                            wPtr.baseAddress!, 1,
                            refWin, 1,
                            &echo,
                            vDSP_Length(filterLen)
                        )
                        let error = mPtr[i] - echo
                        // Defense in depth: cap each output sample to a
                        // physically reasonable range so a weight transient
                        // doesn't propagate downstream and break Whisper's
                        // log-mel front-end. Real PCM is in [-1, 1].
                        mPtr[i] = max(-2.0, min(2.0, error))

                        var energy: Float = 0
                        vDSP_svesq(
                            refWin, 1,
                            &energy,
                            vDSP_Length(filterLen)
                        )
                        var scale = mu * error / (energy + eps)
                        vDSP_vsma(
                            refWin, 1,
                            &scale,
                            wPtr.baseAddress!, 1,
                            wPtr.baseAddress!, 1,
                            vDSP_Length(filterLen)
                        )
                    }
                }
            }
        }
    }
}
