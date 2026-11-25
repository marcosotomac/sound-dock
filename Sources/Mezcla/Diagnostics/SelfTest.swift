import CoreAudio
import Foundation
import MezclaCore

/// `Mezcla --selftest [app [percent]]` prints what Mezcla sees and, given an app name or bundle id, runs a
/// real tap on it (at 25 % unless a percentage up to 150 is given) for three seconds and reports the peak.
enum SelfTest {
    static func run(appFilter: String?, percent: Int? = nil) -> Never {
        print("Mezcla self-test")
        print("Permission:", SystemAudioCapturePermission().status())

        let defaultOutput = AudioSystem.defaultOutputDevice()
        print("\nOutput devices:")
        for device in AudioSystem.devices() where device.hasOutput && !device.isHidden {
            let marker = device.id == defaultOutput?.id ? "*" : " "
            let stereo = device.preferredStereoChannels.map { "\($0.left + 1)/\($0.right + 1)" } ?? "-"
            let inputs = device.streams(scope: kAudioObjectPropertyScopeInput).count
            print(" \(marker) [\(device.id)] \(device.name ?? "?")  stereo \(stereo)  input streams \(inputs)  volume \(device.mainVolume.map { String(format: "%.2f", $0) } ?? "-")")
        }

        let resolver = AppIdentityResolver(bundles: BundleMetadataCache())
        var groups: [AppID: (identity: AppIdentity, objects: [AudioObjectID], playing: Bool)] = [:]
        print("\nAudio processes:")
        for id in AudioSystem.processObjectIDs() {
            let process = AudioProcess(id: id)
            guard let pid = process.pid, pid > 0 else { continue }
            let identity = resolver.resolve(SystemProcessFacts.facts(pid: pid, coreAudioBundleID: process.bundleID))
            let playing = process.isRunningOutput
            print("  [\(id)] pid \(pid) \(playing ? "▶︎" : " ") \(process.bundleID ?? "-")  →  \(identity.name) (\(identity.id))")
            var group = groups[identity.id] ?? (identity, [], false)
            group.objects.append(id)
            group.playing = group.playing || playing
            groups[identity.id] = group
        }

        guard let appFilter else { exit(0) }
        guard let output = defaultOutput,
              let target = groups.values.first(where: {
                  $0.identity.name.localizedCaseInsensitiveContains(appFilter) || $0.identity.id.rawValue.localizedCaseInsensitiveContains(appFilter)
              })
        else {
            print("\nNo audio app matches “\(appFilter)”.")
            exit(1)
        }

        let level = Double(percent ?? 25) / 100
        print("\nTapping \(target.identity.name) (\(target.objects.count) processes, playing: \(target.playing)) at \(Int(level * 100)) % for 3 s…")
        do {
            let tap = try ProcessTap(configuration: .init(processObjects: target.objects, outputDevice: output, gain: VolumeCurve.gain(forLevel: level)))
            print("  topology: \(tap.topology)")
            tap.setMeteringEnabled(true)
            try tap.start()
            var peak: Float = 0
            for _ in 0..<30 {
                Thread.sleep(forTimeInterval: 0.1)
                peak = max(peak, tap.takePeak())
            }
            let decibels = peak > 0 ? String(format: "%.1f dBFS", 20 * log10(peak)) : "silence"
            print("  rendered \(tap.renderedCycles) IO cycles, output peak \(decibels)")
            print(peak > 0 ? "  ✅ audio flowed through the tap" : "  ⚠️ silence: the app was quiet or capture permission is missing")
            exit(0)
        } catch {
            print("  ❌ \(error)")
            exit(1)
        }
    }
}
