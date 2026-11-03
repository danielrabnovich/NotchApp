import NotchKit
import Testing

struct DevQueryTests {
    @Test("Parses", arguments: [
        ("ENG-123", DevQuery.linearIssue("ENG-123")), ("eng-7", .linearIssue("ENG-7")),
        ("https://linear.app/acme/issue/WEB-42/fix-the-thing", .linearIssue("WEB-42")),
        ("my issues", .linearMine), ("Linear", .linearMine), ("what am I working on?", .linearMine),
        ("linear onboarding flow", .linearSearch("onboarding flow")),
        ("deploys", .deploys(project: nil)), ("Vercel", .deploys(project: nil)), ("deploys web", .deploys(project: "web")),
        ("vercel for docs-site", .deploys(project: "docs-site")),
    ])
    func parses(query: String, expected: DevQuery) {
        #expect(DevQuery.parse(query) == expected)
    }

    @Test("Leaves other searches alone", arguments: ["covid-19 cases", "how do I deploy to vercel", "pr 3", "weather", "x-1 rocket plane facts"])
    func leaves(query: String) {
        #expect(DevQuery.parse(query) == nil)
    }
}
