import Testing
@testable import SCCore

struct ClickSoundTests {
    @Test func recordedClickDecodes() {
        let s = ClickSound.samples
        #expect(s.count > 4000 && s.count < 10000)
        let peak = s.map(abs).max() ?? 0
        #expect(peak > 0.5 && peak < 0.7)
        // The hit is at the very start, so clicks line up with the cursor.
        #expect(s.prefix(480).map(abs).max()! > 0.1)
    }
}
