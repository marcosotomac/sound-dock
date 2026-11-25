import MezclaDSP

/// Swift owner of the C real-time kernel. Must outlive the IOProc that renders with it.
final class GainKernel {
    let pointer: OpaquePointer

    init(startGain: Float, targetGain: Float) {
        pointer = MZGainKernelCreate(startGain, targetGain)
    }

    deinit {
        MZGainKernelDestroy(pointer)
    }

    var gain: Float {
        get { MZGainKernelGetGain(pointer) }
        set { MZGainKernelSetGain(pointer, newValue) }
    }

    var duck: Float {
        get { MZGainKernelGetDuck(pointer) }
        set { MZGainKernelSetDuck(pointer, newValue) }
    }

    func setSampleRate(_ sampleRate: Double) {
        MZGainKernelSetSampleRate(pointer, sampleRate)
    }

    func setRouting(tapChannels: UInt32, outputLeft: UInt32, outputRight: UInt32) {
        MZGainKernelSetRouting(pointer, tapChannels, outputLeft, outputRight)
    }

    func setMeteringEnabled(_ enabled: Bool) {
        MZGainKernelSetMeteringEnabled(pointer, enabled)
    }

    func takePeak() -> Float {
        MZGainKernelTakePeak(pointer)
    }

    var cycleCount: UInt64 {
        MZGainKernelCycleCount(pointer)
    }
}
