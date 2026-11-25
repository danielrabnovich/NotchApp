import Foundation
import Testing
@testable import NotchApp

/// Due dates pulled out of a task's text.
@MainActor
struct DueDateParserTests {
    @Test func dateAndTimeComeOutOfTheTitle() throws {
        let (title, due) = DueDateParser.extract(from: "send deck by tomorrow at 3pm")
        #expect(title == "Send deck")
        let date = try #require(due)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        #expect(Calendar.current.isDate(date, inSameDayAs: tomorrow))
        #expect(Calendar.current.component(.hour, from: date) == 15)
    }

    @Test func aDayWithoutATimeIsTheEndOfTheWorkingDay() throws {
        let (title, due) = DueDateParser.extract(from: "Renew passport tomorrow")
        #expect(title == "Renew passport")
        let date = try #require(due)
        #expect(Calendar.current.component(.hour, from: date) == 17)
        #expect(Calendar.current.component(.minute, from: date) == 0)
    }

    @Test func noDateLeavesTheTextAlone() {
        let (title, due) = DueDateParser.extract(from: "buy milk")
        #expect(title == "buy milk")
        #expect(due == nil)
    }

    @Test func pastDatesAreNotDueDates() {
        let (title, due) = DueDateParser.extract(from: "read the January 2 2020 report")
        #expect(due == nil)
        #expect(title == "read the January 2 2020 report")
    }

    @Test func dueDayIsTheDeadlineNotToday() throws {
        // The detector reads "due tomorrow" as a span from now: the end is the due date.
        let (title, due) = DueDateParser.extract(from: "Pay rent due tomorrow")
        #expect(title == "Pay rent")
        let date = try #require(due)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        #expect(Calendar.current.isDate(date, inSameDayAs: tomorrow))
        #expect(Calendar.current.component(.hour, from: date) == 17)
    }

    @Test func danglingWordsGo() {
        #expect(DueDateParser.extract(from: "Call mum on tomorrow").title == "Call mum")
        #expect(DueDateParser.extract(from: "Taxes due tomorrow").title == "Taxes")
    }
}
