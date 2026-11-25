#include "MezclaDSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define RELAXED memory_order_relaxed

/// Time constant of the gain smoother. Gain moves 63 % of the way in 12 ms and settles in ~50 ms.
static const double MZSmoothingTimeConstant = 0.012;
/// Ducking time constants: lowering for a call is quick, coming back is gentle.
static const double MZDuckAttackTimeConstant = 0.08;
static const double MZDuckReleaseTimeConstant = 0.4;
/// Below this distance the smoother snaps to the target, so steady state costs nothing extra.
static const float MZSettledDistance = 1.0e-5f;
/// Boost limiter: grabs a peak in about a millisecond, holds the reduction for a bass cycle so low notes
/// are not modulated, then lets go gently.
static const double MZLimiterAttackTimeConstant = 0.0008;
static const double MZLimiterHoldTime = 0.05;
static const double MZLimiterReleaseTimeConstant = 0.15;
/// The limiter aims for -1.5 dBFS, where the soft clipper starts, so the clipper only catches the
/// first instant of a sudden peak instead of shaping every loud sample.
static const float MZLimiterThreshold = 0.841395142f; // -1.5 dBFS

struct MZGainKernel {
    _Atomic(float) targetGain;
    _Atomic(UInt32) tapChannelCount;
    _Atomic(UInt32) outputLeft;
    _Atomic(UInt32) outputRight;
    _Atomic(bool) meteringEnabled;
    _Atomic(float) peak;
    _Atomic(UInt64) cycleCount;
    _Atomic(float) smoothingCoefficient;
    _Atomic(float) targetDuck;
    _Atomic(float) duckAttackCoefficient;
    _Atomic(float) duckReleaseCoefficient;
    _Atomic(float) limiterAttackCoefficient;
    _Atomic(float) limiterReleaseCoefficient;
    _Atomic(UInt32) limiterHoldFrames;
    float appliedGain;      // Owned by the IO thread.
    float appliedDuck;      // Owned by the IO thread.
    float limiterGain;      // Owned by the IO thread. 1 = no reduction.
    UInt32 limiterHoldLeft; // Owned by the IO thread.
};

typedef struct {
    float *samples;
    UInt32 stride;
    UInt32 frames;
} MZChannel;

static float MZCoefficient(double timeConstant, double sampleRate) {
    return (float)(1.0 - exp(-1.0 / (timeConstant * sampleRate)));
}

static void MZStoreCoefficients(MZGainKernel *kernel, double sampleRate) {
    atomic_store_explicit(&kernel->smoothingCoefficient, MZCoefficient(MZSmoothingTimeConstant, sampleRate), RELAXED);
    atomic_store_explicit(&kernel->duckAttackCoefficient, MZCoefficient(MZDuckAttackTimeConstant, sampleRate), RELAXED);
    atomic_store_explicit(&kernel->duckReleaseCoefficient, MZCoefficient(MZDuckReleaseTimeConstant, sampleRate), RELAXED);
    atomic_store_explicit(&kernel->limiterAttackCoefficient, MZCoefficient(MZLimiterAttackTimeConstant, sampleRate), RELAXED);
    atomic_store_explicit(&kernel->limiterReleaseCoefficient, MZCoefficient(MZLimiterReleaseTimeConstant, sampleRate), RELAXED);
    atomic_store_explicit(&kernel->limiterHoldFrames, (UInt32)(MZLimiterHoldTime * sampleRate), RELAXED);
}

MZGainKernel *MZGainKernelCreate(float startGain, float targetGain) {
    MZGainKernel *kernel = calloc(1, sizeof *kernel);
    if (kernel == NULL) {
        abort();
    }
    atomic_init(&kernel->targetGain, targetGain);
    atomic_init(&kernel->tapChannelCount, 2);
    atomic_init(&kernel->outputLeft, 0);
    atomic_init(&kernel->outputRight, 1);
    atomic_init(&kernel->meteringEnabled, false);
    atomic_init(&kernel->peak, 0.0f);
    atomic_init(&kernel->cycleCount, 0);
    atomic_init(&kernel->smoothingCoefficient, 0.0f);
    atomic_init(&kernel->duckAttackCoefficient, 0.0f);
    atomic_init(&kernel->duckReleaseCoefficient, 0.0f);
    atomic_init(&kernel->targetDuck, 1.0f);
    atomic_init(&kernel->limiterAttackCoefficient, 0.0f);
    atomic_init(&kernel->limiterReleaseCoefficient, 0.0f);
    atomic_init(&kernel->limiterHoldFrames, 0);
    MZStoreCoefficients(kernel, 48000.0);
    kernel->limiterGain = 1.0f;
    kernel->appliedGain = startGain;
    kernel->appliedDuck = 1.0f;
    return kernel;
}

void MZGainKernelDestroy(MZGainKernel *kernel) {
    free(kernel);
}

void MZGainKernelSetGain(MZGainKernel *kernel, float gain) {
    atomic_store_explicit(&kernel->targetGain, isfinite(gain) && gain > 0.0f ? gain : 0.0f, RELAXED);
}

float MZGainKernelGetGain(const MZGainKernel *kernel) {
    return atomic_load_explicit(&((MZGainKernel *)kernel)->targetGain, RELAXED);
}

void MZGainKernelSetSampleRate(MZGainKernel *kernel, double sampleRate) {
    if (sampleRate > 0.0) {
        MZStoreCoefficients(kernel, sampleRate);
    }
}

void MZGainKernelSetDuck(MZGainKernel *kernel, float duck) {
    atomic_store_explicit(&kernel->targetDuck, isfinite(duck) ? fminf(fmaxf(duck, 0.0f), 1.0f) : 1.0f, RELAXED);
}

float MZGainKernelGetDuck(const MZGainKernel *kernel) {
    return atomic_load_explicit(&((MZGainKernel *)kernel)->targetDuck, RELAXED);
}

void MZGainKernelSetRouting(MZGainKernel *kernel, UInt32 tapChannelCount, UInt32 outputLeft, UInt32 outputRight) {
    atomic_store_explicit(&kernel->tapChannelCount, tapChannelCount, RELAXED);
    atomic_store_explicit(&kernel->outputLeft, outputLeft, RELAXED);
    atomic_store_explicit(&kernel->outputRight, outputRight, RELAXED);
}

void MZGainKernelSetMeteringEnabled(MZGainKernel *kernel, bool enabled) {
    atomic_store_explicit(&kernel->meteringEnabled, enabled, RELAXED);
}

float MZGainKernelTakePeak(MZGainKernel *kernel) {
    return atomic_exchange_explicit(&kernel->peak, 0.0f, RELAXED);
}

UInt64 MZGainKernelCycleCount(const MZGainKernel *kernel) {
    return atomic_load_explicit(&((MZGainKernel *)kernel)->cycleCount, RELAXED);
}

// MARK: - Render path

/// Counts channels in buffers that carry data. Streams disabled through stream usage arrive with NULL data.
static inline UInt32 MZChannelCount(const AudioBufferList *list) {
    if (list == NULL) {
        return 0;
    }
    UInt32 count = 0;
    for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
        const AudioBuffer *buffer = &list->mBuffers[index];
        if (buffer->mData != NULL) {
            count += buffer->mNumberChannels;
        }
    }
    return count;
}

/// Locates a channel across interleaved or non-interleaved buffers, skipping disabled streams.
static inline bool MZChannelAt(const AudioBufferList *list, UInt32 channel, MZChannel *result) {
    for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
        const AudioBuffer *buffer = &list->mBuffers[index];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0) {
            continue;
        }
        if (channel < buffer->mNumberChannels) {
            result->samples = (float *)buffer->mData + channel;
            result->stride = buffer->mNumberChannels;
            result->frames = buffer->mDataByteSize / (UInt32)(sizeof(float) * buffer->mNumberChannels);
            return true;
        }
        channel -= buffer->mNumberChannels;
    }
    return false;
}

static inline void MZSilence(AudioBufferList *list) {
    if (list == NULL) {
        return;
    }
    for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
        AudioBuffer *buffer = &list->mBuffers[index];
        if (buffer->mData != NULL) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

/// Safety stage after the limiter. Transparent below -1.5 dBFS, then bends smoothly towards a -0.3 dBFS
/// ceiling, which leaves room for inter-sample peaks so boosted audio never clips in the DAC.
static inline float MZSoftLimit(float sample) {
    const float threshold = MZLimiterThreshold;
    const float ceiling = 0.966050879f;   // -0.3 dBFS
    const float knee = ceiling - threshold;
    const float magnitude = fabsf(sample);
    if (magnitude <= threshold) {
        return sample;
    }
    return copysignf(threshold + knee * tanhf((magnitude - threshold) / knee), sample);
}

static inline UInt32 MZMin(UInt32 a, UInt32 b) {
    return a < b ? a : b;
}

static OSStatus MZGainKernelRender(AudioObjectID device,
                                   const AudioTimeStamp *now,
                                   const AudioBufferList *input,
                                   const AudioTimeStamp *inputTime,
                                   AudioBufferList *output,
                                   const AudioTimeStamp *outputTime,
                                   void *clientData) {
    (void)device;
    (void)now;
    (void)inputTime;
    (void)outputTime;

    MZGainKernel *kernel = clientData;
    atomic_fetch_add_explicit(&kernel->cycleCount, 1, RELAXED);

    // We own every output channel of the aggregate: start from silence so unused channels stay quiet.
    MZSilence(output);

    const UInt32 inputChannels = MZChannelCount(input);
    const UInt32 outputChannels = MZChannelCount(output);
    if (inputChannels == 0 || outputChannels == 0) {
        return noErr;
    }

    UInt32 tapChannels = atomic_load_explicit(&kernel->tapChannelCount, RELAXED);
    if (tapChannels == 0 || tapChannels > inputChannels) {
        tapChannels = inputChannels;
    }
    const UInt32 firstTapChannel = inputChannels - tapChannels;

    UInt32 left = atomic_load_explicit(&kernel->outputLeft, RELAXED);
    UInt32 right = atomic_load_explicit(&kernel->outputRight, RELAXED);
    if (left >= outputChannels) {
        left = 0;
    }
    if (right >= outputChannels) {
        right = outputChannels > 1 ? 1 : 0;
    }

    MZChannel inLeft, inRight, outLeft, outRight;
    if (!MZChannelAt(input, firstTapChannel, &inLeft) ||
        !MZChannelAt(input, firstTapChannel + (tapChannels > 1 ? 1 : 0), &inRight) ||
        !MZChannelAt(output, left, &outLeft) ||
        !MZChannelAt(output, right, &outRight)) {
        return noErr;
    }

    const UInt32 frames = MZMin(MZMin(inLeft.frames, inRight.frames), MZMin(outLeft.frames, outRight.frames));
    if (frames == 0) {
        return noErr;
    }

    const float target = atomic_load_explicit(&kernel->targetGain, RELAXED);
    const float coefficient = atomic_load_explicit(&kernel->smoothingCoefficient, RELAXED);
    float gain = kernel->appliedGain;
    const bool limit = target > 1.0f || gain > 1.0f;
    const float duckTarget = atomic_load_explicit(&kernel->targetDuck, RELAXED);
    float duck = kernel->appliedDuck;
    const float duckCoefficient = duckTarget < duck
        ? atomic_load_explicit(&kernel->duckAttackCoefficient, RELAXED)
        : atomic_load_explicit(&kernel->duckReleaseCoefficient, RELAXED);
    const float limiterAttack = atomic_load_explicit(&kernel->limiterAttackCoefficient, RELAXED);
    const float limiterRelease = atomic_load_explicit(&kernel->limiterReleaseCoefficient, RELAXED);
    const UInt32 limiterHold = atomic_load_explicit(&kernel->limiterHoldFrames, RELAXED);
    float limiterGain = kernel->limiterGain;
    UInt32 holdLeft = kernel->limiterHoldLeft;
    const bool mono = outLeft.samples == outRight.samples;
    const bool metering = atomic_load_explicit(&kernel->meteringEnabled, RELAXED);
    float peak = 0.0f;

    for (UInt32 frame = 0; frame < frames; ++frame) {
        gain += (target - gain) * coefficient;
        duck += (duckTarget - duck) * duckCoefficient;
        const float level = gain * duck;
        float l = inLeft.samples[frame * inLeft.stride] * level;
        float r = inRight.samples[frame * inRight.stride] * level;
        if (mono) {
            l = 0.5f * (l + r);
            r = l;
        }
        if (limit || limiterGain < 1.0f) {
            // Gain the loudest channel needs to stay at the threshold; both channels share it so the
            // stereo image does not shift.
            const float magnitude = fmaxf(fabsf(l), fabsf(r));
            const float needed = limit && magnitude > MZLimiterThreshold ? MZLimiterThreshold / magnitude : 1.0f;
            if (needed < limiterGain) {
                limiterGain += (needed - limiterGain) * limiterAttack;
                holdLeft = limiterHold;
            } else if (holdLeft > 0) {
                --holdLeft;
            } else {
                limiterGain += (needed - limiterGain) * limiterRelease;
                if (1.0f - limiterGain < MZSettledDistance) {
                    limiterGain = 1.0f;
                }
            }
            l = MZSoftLimit(l * limiterGain);
            r = MZSoftLimit(r * limiterGain);
        }
        outLeft.samples[frame * outLeft.stride] = l;
        if (!mono) {
            outRight.samples[frame * outRight.stride] = r;
        }
        if (metering) {
            peak = fmaxf(peak, fmaxf(fabsf(l), fabsf(r)));
        }
    }

    kernel->appliedGain = fabsf(target - gain) < MZSettledDistance ? target : gain;
    kernel->appliedDuck = fabsf(duckTarget - duck) < MZSettledDistance ? duckTarget : duck;
    kernel->limiterGain = limiterGain;
    kernel->limiterHoldLeft = holdLeft;
    if (metering && peak > atomic_load_explicit(&kernel->peak, RELAXED)) {
        atomic_store_explicit(&kernel->peak, peak, RELAXED);
    }
    return noErr;
}

AudioDeviceIOProc MZGainKernelIOProc(void) {
    return MZGainKernelRender;
}

OSStatus MZSetInputStreamUsage(AudioObjectID device,
                               AudioDeviceIOProcID ioProc,
                               const UInt32 *enabledFlags,
                               UInt32 streamCount) {
    const size_t size = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + sizeof(UInt32) * streamCount;
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (usage == NULL) {
        return kAudio_MemFullError;
    }
    usage->mIOProc = (void *)ioProc;
    usage->mNumberStreams = streamCount;
    memcpy(usage->mStreamIsOn, enabledFlags, sizeof(UInt32) * streamCount);

    const AudioObjectPropertyAddress address = {
        kAudioDevicePropertyIOProcStreamUsage,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain,
    };
    const OSStatus status = AudioObjectSetPropertyData(device, &address, 0, NULL, (UInt32)size, usage);
    free(usage);
    return status;
}
