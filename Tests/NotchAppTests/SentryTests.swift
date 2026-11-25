import Foundation
import Testing
@testable import NotchApp

/// Sentry's issues as the card and Prompts read them.
@MainActor
struct SentryTests {
    @Test func issueParsesFromTheAPI() throws {
        let json = """
        {"id":"4242","shortId":"SHOP-1F","title":"TypeError: cart is undefined","culprit":"app/cart.ts in total",
         "permalink":"https://acme.sentry.io/issues/4242/","level":"error","count":"1532","userCount":87,
         "firstSeen":"2026-11-25T21:04:05.123456Z","lastSeen":"2026-11-25T22:10:00Z",
         "project":{"id":"1","slug":"shop-web","name":"Shop Web"},
         "stats":{"24h":[[1764100800,3],[1764104400,5],[1764108000,12]]}}
        """
        let o = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let issue = try #require(SentryService.issue(o))
        #expect(issue.shortID == "SHOP-1F")
        #expect(issue.project == "shop-web")
        #expect(issue.events == 1532)
        #expect(issue.users == 87)
        #expect(issue.hourly == [3, 5, 12])
        #expect(issue.isError)
        #expect(issue.url?.absoluteString == "https://acme.sentry.io/issues/4242/")
        let first = try #require(SentryService.date("2026-11-25T21:04:05.123456Z"))
        #expect(Int(first.timeIntervalSince1970) == 1_795_640_645)
        #expect(SentryService.date("2026-11-25T22:10:00Z") != nil)
    }

    @Test func spikesNeedVolumeAndAJump() {
        // Quiet, then 40 in the last hour: a spike.
        #expect(SentryService.isSpiking([2, 1, 3, 2, 0, 40]))
        // Busy all day: 40 is normal for it.
        #expect(!SentryService.isSpiking([35, 40, 38, 42, 40]))
        // A jump, but too few events to matter.
        #expect(!SentryService.isSpiking([0, 0, 0, 0, 12]))
        // Not enough history to judge.
        #expect(!SentryService.isSpiking([0, 50]))
    }
}
