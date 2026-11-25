import Foundation
import MezclaCore
import Testing

@Suite("AppVolume")
struct AppVolumeTests {
    @Test func unityIsNeutralAndTransparent() {
        #expect(AppVolume.unity.isNeutral)
        #expect(AppVolume.unity.gain == 1)
    }

    @Test func mutedIsNeverNeutral() {
        let muted = AppVolume(level: 1, isMuted: true)
        #expect(!muted.isNeutral)
        #expect(muted.gain == 0)
    }

    @Test(arguments: [(0.5, -12.04), (0.25, -24.08), (1.5, 7.04)])
    func curveFollowsSquareLaw(level: Double, expectedDecibels: Double) {
        let decibels = 20 * log10(Double(VolumeCurve.gain(forLevel: level)))
        #expect(abs(decibels - expectedDecibels) < 0.01)
    }

    @Test func curveClampsOutOfRangeLevels() {
        #expect(VolumeCurve.gain(forLevel: -1) == 0)
        #expect(VolumeCurve.gain(forLevel: 9) == VolumeCurve.gain(forLevel: AppVolume.maximumBoostLevel))
    }

    @Test func volumesSurviveARoundTripThroughJSON() throws {
        let volumes: [AppID: AppVolume] = ["com.spotify.client": .init(level: 0.4), "exe:/usr/bin/afplay": .init(level: 1, isMuted: true)]
        let decoded = try JSONDecoder().decode([AppID: AppVolume].self, from: JSONEncoder().encode(volumes))
        #expect(decoded == volumes)
    }
}
