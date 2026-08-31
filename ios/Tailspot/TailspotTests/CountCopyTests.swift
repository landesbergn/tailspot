import Testing
@testable import Tailspot

@Suite("Count copy")
struct CountCopyTests {
    @Test func regularNounsUseTheSingularOnlyForOne() {
        #expect(CountCopy.phrase(0, singular: "catch", plural: "catches") == "0 catches")
        #expect(CountCopy.phrase(1, singular: "catch", plural: "catches") == "1 catch")
        #expect(CountCopy.phrase(2, singular: "catch", plural: "catches") == "2 catches")
    }

    @Test func defaultPluralAppendsS() {
        #expect(CountCopy.phrase(1, singular: "sighting") == "1 sighting")
        #expect(CountCopy.phrase(2, singular: "sighting") == "2 sightings")
    }
}
