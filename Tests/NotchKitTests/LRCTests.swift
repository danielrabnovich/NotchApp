import NotchKit
import Testing

struct LRCTests {
    @Test func stampsAndTagsParse() {
        let lines = LRC.parse("[ar: Someone]\n[00:12.50] First line\n[01:02.00][02:10.25] Chorus\nno stamp\n[00:20.00]")
        #expect(lines.map(\.time) == [12.5, 20, 62, 130.25])
        #expect(lines.map(\.text) == ["First line", "", "Chorus", "Chorus"])
    }

    @Test func positionRunsThroughEachLine() {
        let lines = [LRC.Line(time: 10, text: "a"), LRC.Line(time: 20, text: "b")]
        #expect(LRC.position(in: lines, at: 5) == nil)
        #expect(LRC.position(in: lines, at: 15)?.index == 0)
        #expect(LRC.position(in: lines, at: 15)?.progress == 0.5)
        #expect(LRC.position(in: lines, at: 22)?.index == 1)
        #expect(LRC.position(in: lines, at: 30)?.progress == 1)
    }
}
