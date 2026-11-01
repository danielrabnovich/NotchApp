import NotchKit
import Testing

struct FuzzyMatchTests {
    @Test("Word starts in order find the app", arguments: [
        ("LM Studio", "lms"), ("Visual Studio Code", "vsc"), ("Visual Studio Code", "vscode"),
        ("Google Chrome", "gchr"), ("System Settings", "syss"), ("System Settings", "sys set"),
    ])
    func wordStarts(name: String, query: String) {
        #expect(FuzzyMatch.score(name, query) >= 80)
    }

    @Test func tiers() {
        #expect(FuzzyMatch.score("Spotify", "spotify") == 100)
        #expect(FuzzyMatch.score("LM Studio", "lmstudio") == 98)
        #expect(FuzzyMatch.score("Notes", "no") == 85)
        #expect(FuzzyMatch.score("LM Studio", "studio") == 70)
        #expect(FuzzyMatch.score("Adobe Premiere Pro", "prpro") == 65)
        #expect(FuzzyMatch.score("Make it more professional", "mipro") == 65)
        #expect(FuzzyMatch.score("FaceTime", "ft") == 60)
        #expect(FuzzyMatch.score("Microsoft OneNote", "note") == 70)
    }

    @Test func typos() {
        // The whole name with a slip beats the start of a longer one.
        #expect(FuzzyMatch.score("Spotify", "spotfy") > FuzzyMatch.score("SpotBye", "spotfy"))
        #expect(FuzzyMatch.score("Spotify", "spotfy") >= 60)
        #expect(FuzzyMatch.score("Notifications", "notifcations") >= 60)
        // Short words don't get typo matches: "test" isn't TextEdit.
        #expect(FuzzyMatch.score("TextEdit", "test") < 45)
    }

    @Test func noMatch() {
        #expect(FuzzyMatch.score("Safari", "xyz") == 0)
        #expect(FuzzyMatch.score("Safari", "") == 0)
        #expect(FuzzyMatch.score("", "safari") == 0)
    }

    @Test func caseAndAccents() {
        #expect(FuzzyMatch.score("Café Notes", "CAFE") == 85)
        #expect(FuzzyMatch.score("iTerm", "ITERM") == 100)
    }

    @Test("Names split into words", arguments: [
        ("LMStudio", ["lm", "studio"]), ("FaceTime", ["face", "time"]), ("iTerm2", ["i", "term", "2"]),
        ("1Password 7", ["1", "password", "7"]), ("VLC", ["vlc"]), ("Visual-Studio.Code", ["visual", "studio", "code"]),
    ])
    func words(name: String, expected: [String]) {
        #expect(FuzzyMatch.words(name) == expected)
    }

    @Test func preparedNameScoresTheSame() {
        let name = FuzzyMatch.Name("Visual Studio Code")
        for q in ["vsc", "code", "visual", "vscod", "xyz"] {
            #expect(FuzzyMatch.score(name, q) == FuzzyMatch.score("Visual Studio Code", q))
        }
    }
}
