import CoreAudio
import Foundation
import MezclaDSP
import Testing

/// Drives the real-time render callback with synthetic buffers, exactly as Core Audio would.
@Suite("GainKernel render path")
struct GainKernelTests {
    private static let sampleRate = 48_000.0
    private static let frames = 480 // One 10 ms IO cycle.

    /// Owns interleaved buffers laid out as an `AudioBufferList`.
    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []

        /// `channelsPerBuffer` describes each stream, e.g. `[1, 2]` = a mic stream followed by a stereo tap.
        init(channelsPerBuffer: [Int], frames: Int, fill: (_ channel: Int, _ frame: Int) -> Float = { _, _ in 0 }) {
            list = AudioBufferList.allocate(maximumBuffers: channelsPerBuffer.count)
            var channelBase = 0
            for (index, channels) in channelsPerBuffer.enumerated() {
                let samples = UnsafeMutablePointer<Float>.allocate(capacity: channels * frames)
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        samples[frame * channels + channel] = fill(channelBase + channel, frame)
                    }
                }
                storage.append(samples)
                list[index] = AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.size),
                    mData: samples
                )
                channelBase += channels
            }
        }

        deinit {
            storage.forEach { $0.deallocate() }
            list.unsafeMutablePointer.deallocate()
        }

        func sample(buffer: Int, channel: Int, frame: Int) -> Float {
            let channels = Int(list[buffer].mNumberChannels)
            return storage[buffer][frame * channels + channel]
        }
    }

    private func render(_ kernel: OpaquePointer, input: Buffers, output: Buffers) {
        var time = AudioTimeStamp()
        let status = MZGainKernelIOProc()(0, &time, input.list.unsafePointer, &time, output.list.unsafeMutablePointer, &time, UnsafeMutableRawPointer(kernel))
        #expect(status == noErr)
    }

    private func makeKernel(start: Float, target: Float) -> OpaquePointer {
        let kernel = MZGainKernelCreate(start, target)
        MZGainKernelSetSampleRate(kernel, Self.sampleRate)
        return kernel
    }

    @Test func unityGainIsBitExact() {
        let kernel = makeKernel(start: 1, target: 1)
        defer { MZGainKernelDestroy(kernel) }
        let input = Buffers(channelsPerBuffer: [2], frames: Self.frames) { channel, frame in sin(Float(frame + channel) * 0.1) * 0.7 }
        let output = Buffers(channelsPerBuffer: [2], frames: Self.frames)
        render(kernel, input: input, output: output)

        for frame in 0..<Self.frames {
            #expect(output.sample(buffer: 0, channel: 0, frame: frame) == input.sample(buffer: 0, channel: 0, frame: frame))
            #expect(output.sample(buffer: 0, channel: 1, frame: frame) == input.sample(buffer: 0, channel: 1, frame: frame))
        }
    }

    @Test func steadyGainScalesSamples() {
        let kernel = makeKernel(start: 0.25, target: 0.25)
        defer { MZGainKernelDestroy(kernel) }
        let input = Buffers(channelsPerBuffer: [2], frames: Self.frames) { _, _ in 0.5 }
        let output = Buffers(channelsPerBuffer: [2], frames: Self.frames)
        render(kernel, input: input, output: output)
        #expect(output.sample(buffer: 0, channel: 0, frame: 100) == 0.125)
    }

    @Test func gainChangesGlideWithoutJumps() {
        let kernel = makeKernel(start: 1, target: 0)
        defer { MZGainKernelDestroy(kernel) }
        let input = Buffers(channelsPerBuffer: [2], frames: Self.frames) { _, _ in 1 }

        var previous: Float = 1
        var largestStep: Float = 0
        var levelAfter50ms: Float = 1
        for cycle in 0..<5 { // 50 ms
            let output = Buffers(channelsPerBuffer: [2], frames: Self.frames)
            render(kernel, input: input, output: output)
            for frame in 0..<Self.frames {
                let sample = output.sample(buffer: 0, channel: 0, frame: frame)
                #expect(sample <= previous)
                largestStep = max(largestStep, previous - sample)
                previous = sample
            }
            if cycle == 4 { levelAfter50ms = previous }
        }
        #expect(largestStep < 0.002) // No audible step: the largest per-sample change is tiny.
        #expect(levelAfter50ms < 0.02) // Settled within about 50 ms (−34 dB).
    }

    @Test func boostIsSoftLimitedBelowFullScale() {
        let kernel = makeKernel(start: 2.25, target: 2.25)
        defer { MZGainKernelDestroy(kernel) }
        let input = Buffers(channelsPerBuffer: [2], frames: Self.frames) { _, _ in 0.9 }
        let output = Buffers(channelsPerBuffer: [2], frames: Self.frames)
        render(kernel, input: input, output: output)

        let sample = output.sample(buffer: 0, channel: 0, frame: 10)
        #expect(sample <= 0.966051) // Never above the -0.3 dBFS ceiling.
        #expect(sample > 0.95)

        let quietKernel = makeKernel(start: 2.25, target: 2.25)
        defer { MZGainKernelDestroy(quietKernel) }
        let quiet = Buffers(channelsPerBuffer: [2], frames: Self.frames) { _, _ in 0.2 }
        let quietOutput = Buffers(channelsPerBuffer: [2], frames: Self.frames)
        render(quietKernel, input: quiet, output: quietOutput)
        #expect(abs(quietOutput.sample(buffer: 0, channel: 0, frame: 10) - 0.45) < 1e-6) // Quiet audio is untouched.
    }

    /// Loud, already-mastered audio boosted to 150 % (gain 2.25) must get quieter as a whole rather than
    /// have every peak bent: once the limiter settles, the output is the input times one steady gain.
    @Test func boostedLoudAudioIsLimitedWithoutBendingTheWaveform() {
        let kernel = makeKernel(start: 2.25, target: 2.25)
        defer { MZGainKernelDestroy(kernel) }
        let period = 480 // 100 Hz at 48 kHz: one cycle per IO buffer.
        let input = Buffers(channelsPerBuffer: [2], frames: Self.frames) { _, frame in
            0.9 * sin(2 * .pi * Float(frame) / Float(period))
        }
        var output = Buffers(channelsPerBuffer: [2], frames: Self.frames)
        for _ in 0..<50 { // 0.5 s: past the attack, settled under the hold.
            output = Buffers(channelsPerBuffer: [2], frames: Self.frames)
            render(kernel, input: input, output: output)
        }

        var peak: Float = 0
        var ratios: [Float] = []
        for frame in 0..<Self.frames {
            let out = output.sample(buffer: 0, channel: 0, frame: frame)
            let source = input.sample(buffer: 0, channel: 0, frame: frame)
            peak = max(peak, abs(out))
            if abs(source) > 0.2 { ratios.append(out / source) }
        }
        #expect(peak <= 0.966051) // Never above the -0.3 dBFS ceiling.
        #expect(peak > 0.8) // Still as loud as it can be.
        let spread = (ratios.max() ?? 0) - (ratios.min() ?? 0)
        #expect(spread < 0.01 * (ratios.max() ?? 1)) // One gain for the whole cycle: the shape is intact.
    }

    @Test func limiterReleasesWhenAudioGetsQuietAgain() {
        let kernel = makeKernel(start: 2.25, target: 2.25)
        defer { MZGainKernelDestroy(kernel) }
        let loud = Buffers(channelsPerBuffer: [2], frames: Self.frames) { _, _ in 0.9 }
        for _ in 0..<10 { render(kernel, input: loud, output: Buffers(channelsPerBuffer: [2], frames: Self.frames)) }

        let quiet = Buffers(channelsPerBuffer: [2], frames: Self.frames) { _, _ in 0.2 }
        var last: Float = 0
        for _ in 0..<100 { // 1 s of quiet audio.
            let output = Buffers(channelsPerBuffer: [2], frames: Self.frames)
            render(kernel, input: quiet, output: output)
            last = output.sample(buffer: 0, channel: 0, frame: Self.frames - 1)
        }
        #expect(abs(last - 0.45) < 1e-3) // Back to the full boost.
    }

    @Test func microphoneStreamsAreIgnoredAndStereoPairIsHonored() {
        let kernel = makeKernel(start: 1, target: 1)
        defer { MZGainKernelDestroy(kernel) }
        MZGainKernelSetRouting(kernel, 2, 2, 3) // Tap is stereo; the device's stereo pair is channels 3/4.

        // Stream 0 is a headset mic (1 ch, value 9); stream 1 is the tap (L = 0.1, R = 0.2).
        let input = Buffers(channelsPerBuffer: [1, 2], frames: Self.frames) { channel, _ in [9, 0.1, 0.2][channel] }
        let output = Buffers(channelsPerBuffer: [4], frames: Self.frames) { _, _ in 0.33 }
        render(kernel, input: input, output: output)

        #expect(output.sample(buffer: 0, channel: 0, frame: 5) == 0) // Unused channels are silenced.
        #expect(output.sample(buffer: 0, channel: 1, frame: 5) == 0)
        #expect(output.sample(buffer: 0, channel: 2, frame: 5) == 0.1)
        #expect(output.sample(buffer: 0, channel: 3, frame: 5) == 0.2)
    }

    @Test func monoOutputReceivesTheAverage() {
        let kernel = makeKernel(start: 1, target: 1)
        defer { MZGainKernelDestroy(kernel) }
        let input = Buffers(channelsPerBuffer: [2], frames: Self.frames) { channel, _ in channel == 0 ? 0.2 : 0.4 }
        let output = Buffers(channelsPerBuffer: [1], frames: Self.frames)
        render(kernel, input: input, output: output)
        #expect(abs(output.sample(buffer: 0, channel: 0, frame: 7) - 0.3) < 1e-6)
    }

    @Test func duckingLowersQuicklyAndReturnsGently() {
        let kernel = makeKernel(start: 1, target: 1)
        defer { MZGainKernelDestroy(kernel) }
        let input = Buffers(channelsPerBuffer: [2], frames: Self.frames) { _, _ in 1 }

        func level(afterCycles cycles: Int) -> Float {
            var last: Float = 0
            for _ in 0..<cycles {
                let output = Buffers(channelsPerBuffer: [2], frames: Self.frames)
                render(kernel, input: input, output: output)
                last = output.sample(buffer: 0, channel: 0, frame: Self.frames - 1)
            }
            return last
        }

        MZGainKernelSetDuck(kernel, 0.1)
        #expect(level(afterCycles: 5) > 0.3) // Not a cut: 50 ms in, still on the way down.
        #expect(abs(level(afterCycles: 45) - 0.1) < 0.01) // Down within ~0.5 s.

        MZGainKernelSetDuck(kernel, 1)
        #expect(level(afterCycles: 30) < 0.6) // 0.3 s in, still rising gently.
        #expect(level(afterCycles: 220) > 0.99) // Back within ~2.5 s.
    }

    @Test func duckingStacksWithTheUsersGain() {
        let kernel = makeKernel(start: 0.5, target: 0.5)
        defer { MZGainKernelDestroy(kernel) }
        MZGainKernelSetDuck(kernel, 0.2)
        let input = Buffers(channelsPerBuffer: [2], frames: Self.frames) { _, _ in 1 }
        var last: Float = 0
        for _ in 0..<100 {
            let output = Buffers(channelsPerBuffer: [2], frames: Self.frames)
            render(kernel, input: input, output: output)
            last = output.sample(buffer: 0, channel: 0, frame: 0)
        }
        #expect(abs(last - 0.1) < 1e-3)
    }

    @Test func invalidGainIsTreatedAsSilence() {
        let kernel = makeKernel(start: 0, target: 0)
        defer { MZGainKernelDestroy(kernel) }
        MZGainKernelSetGain(kernel, .nan)
        #expect(MZGainKernelGetGain(kernel) == 0)
        MZGainKernelSetGain(kernel, -3)
        #expect(MZGainKernelGetGain(kernel) == 0)
    }
}
