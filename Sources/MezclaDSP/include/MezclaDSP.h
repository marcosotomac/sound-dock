#ifndef MEZCLA_DSP_H
#define MEZCLA_DSP_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

CF_ASSUME_NONNULL_BEGIN

/// Real-time gain processor driven by a Core Audio IOProc.
///
/// The render path is allocation-free, lock-free and never calls into Objective-C or Swift.
/// Every setter is a relaxed atomic store, so it may be called from any thread while audio runs.
typedef struct MZGainKernel MZGainKernel;

/// Creates a kernel that glides from `startGain` to `targetGain` once audio starts, e.g. from the
/// level an app was playing at to the level the user picked.
MZGainKernel *MZGainKernelCreate(float startGain, float targetGain);
void MZGainKernelDestroy(MZGainKernel *kernel);

/// Linear amplitude. The applied gain follows it through a one-pole smoother (about 50 ms to settle),
/// so slider moves and mutes sound soft and never click. Values above 1 engage a peak limiter (about 1 ms
/// attack, 50 ms hold, 150 ms release, aiming at -1.5 dBFS) followed by a soft clipper with a -0.3 dBFS
/// ceiling, so boosted audio gets louder without distorting and never clips.
void MZGainKernelSetGain(MZGainKernel *kernel, float gain);
float MZGainKernelGetGain(const MZGainKernel *kernel);

/// Ducking: a second gain stage, independent of the user's volume, used to lower an app during calls.
/// It moves slowly and asymmetrically like a broadcast ducker: down in ~0.4 s, back up in ~1.8 s.
void MZGainKernelSetDuck(MZGainKernel *kernel, float duck);
float MZGainKernelGetDuck(const MZGainKernel *kernel);

/// Sample rate of the device the kernel renders for; sets the smoothers' time constants.
void MZGainKernelSetSampleRate(MZGainKernel *kernel, double sampleRate);

/// Describes where audio comes from and goes to.
/// - tapChannelCount: channels delivered by the tap. They are the last input channels of the aggregate
///   device, after any input channels of the output device itself.
/// - outputLeft / outputRight: zero-based output channels of the device's preferred stereo pair.
void MZGainKernelSetRouting(MZGainKernel *kernel, UInt32 tapChannelCount, UInt32 outputLeft, UInt32 outputRight);

/// Peak metering is off by default; it exists for diagnostics.
void MZGainKernelSetMeteringEnabled(MZGainKernel *kernel, bool enabled);
/// Returns the peak since the previous call and resets it.
float MZGainKernelTakePeak(MZGainKernel *kernel);
/// Number of IO cycles rendered so far.
UInt64 MZGainKernelCycleCount(const MZGainKernel *kernel);

/// The IOProc to register with `AudioDeviceCreateIOProcID`, passing the kernel as client data.
AudioDeviceIOProc MZGainKernelIOProc(void);

/// Sets `kAudioDevicePropertyIOProcStreamUsage` for the input scope, so an IOProc only receives the
/// streams it needs. Used to keep the output device's microphone off.
OSStatus MZSetInputStreamUsage(AudioObjectID device,
                               AudioDeviceIOProcID ioProc,
                               const UInt32 *enabledFlags,
                               UInt32 streamCount);

CF_ASSUME_NONNULL_END

#endif
