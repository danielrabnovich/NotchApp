import NotchKit
import Testing

struct LinkCleanerTests {
    @Test func campaignTagsComeOff() {
        let r = LinkCleaner.clean("https://example.com/page?id=4&utm_source=news&utm_medium=email&fbclid=abc")
        #expect(r?.link == "https://example.com/page?id=4")
        #expect(r?.removed == 3)
    }

    @Test func cleanLinkIsLeftAlone() {
        #expect(LinkCleaner.clean("https://example.com/page?id=4") == nil)
        #expect(LinkCleaner.clean("not a link") == nil)
        #expect(LinkCleaner.clean("ftp://example.com/?utm_source=x") == nil)
    }

    @Test func siteSpecificNamesOnlyOnThatSite() {
        #expect(LinkCleaner.clean("https://www.youtube.com/watch?v=abc&si=xyz")?.link == "https://www.youtube.com/watch?v=abc")
        // "si" means nothing elsewhere.
        #expect(LinkCleaner.clean("https://example.com/?si=xyz") == nil)
    }

    @Test func redirectsUnwrap() {
        let r = LinkCleaner.clean("https://www.google.com/url?q=https://example.com/a?utm_source=g&sa=D")
        #expect(r?.link == "https://example.com/a")
        #expect(r?.removed == 2)
    }

    @Test func keptParametersKeepTheirEncoding() {
        #expect(LinkCleaner.clean("https://example.com/?q=a%20b&utm_source=x")?.link == "https://example.com/?q=a%20b")
    }

    @Test func amazonRefPath() {
        #expect(LinkCleaner.clean("https://www.amazon.co.uk/dp/B000/ref=sr_1_1?qid=1")?.link == "https://www.amazon.co.uk/dp/B000")
    }
}
