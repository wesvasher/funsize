import Testing
@testable import SwiftCut

struct TimelineLayoutTests {
    // Two clips: 10 s drawn 300 wide, then 2 s drawn 60 wide, with a 4-point gap, starting at 12.
    let layout = TimelineLayout(durations: [10, 2], widths: [300, 60], spacing: 4, start: 12)

    @Test func placesTheTimeInsideTheRightClip() {
        #expect(layout.x(at: 0) == 12)
        #expect(layout.x(at: 5) == 162)
        // The second clip starts after the first clip and the gap.
        #expect(layout.x(at: 10) == 316)
        #expect(layout.x(at: 11) == 346)
        #expect(layout.x(at: 12) == 376)
        #expect(layout.x(at: 99) == 376)
    }

    @Test func positionAndTimeRoundTrip() {
        for seconds in [0.0, 2.5, 9.9, 10.5, 11.75] {
            #expect(abs(layout.time(at: layout.x(at: seconds)) - seconds) < 0.0001)
        }
    }

    @Test func dragPastTheEndsStopsAtTheEnds() {
        #expect(layout.time(at: -50) == 0)
        #expect(layout.time(at: 5000) == 12)
        // In the gap between clips: the start of the next clip.
        #expect(layout.time(at: 313) == 10)
    }
}

struct TimelineLayoutPlaybackTests {
    @Test func continuousPositionCoversTheGaps() {
        let layout = TimelineLayout(durations: [2, 2], widths: [100, 100], spacing: 4, start: 10)
        // Starts and ends match the exact mapping.
        #expect(layout.continuousX(at: 0) == 10)
        #expect(layout.continuousX(at: 2) == layout.x(at: 2))
        #expect(layout.continuousX(at: 4) == layout.x(at: 4))
        // Just before the second clip, it's almost across the gap instead of at the first clip's edge.
        #expect(abs(layout.continuousX(at: 1.999) - 114) < 0.2)
    }
}
