import Contacts
import Foundation

/// Today's birthdays from Contacts, for Home's Today column and the morning brief. Asked for only
/// from Settings → Permissions; without it, there are simply none.
@MainActor
final class Birthdays: ObservableObject {
    static let shared = Birthdays()

    struct Person: Equatable, Identifiable {
        let id: String
        let name: String
        /// How old they're turning, when the year is known.
        let turning: Int?
    }

    @Published private(set) var today: [Person] = []
    private var day: Date?

    static var authorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    /// Reads them again once a day (or after access is granted).
    func refreshIfStale(force: Bool = false) {
        let now = Calendar.current.startOfDay(for: Date())
        guard Self.authorized, force || day != now else { return }
        day = now
        Task.detached(priority: .utility) {
            let found = Self.read(on: Date())
            await MainActor.run { if Birthdays.shared.today != found { Birthdays.shared.today = found } }
        }
    }

    func requestAccess(_ done: @escaping @MainActor (Bool) -> Void) {
        CNContactStore().requestAccess(for: .contacts) { granted, _ in
            Task { @MainActor in
                if granted { Birthdays.shared.refreshIfStale(force: true) }
                done(granted)
            }
        }
    }

    private nonisolated static func read(on date: Date) -> [Person] {
        let cal = Calendar.current
        let today = cal.dateComponents([.month, .day, .year], from: date)
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactBirthdayKey] as [CNKeyDescriptor]
        var out: [Person] = []
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            guard let b = contact.birthday, b.month == today.month, b.day == today.day else { return }
            let name = [contact.nickname.isEmpty ? contact.givenName : contact.nickname, contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            guard !name.isEmpty else { return }
            out.append(Person(id: contact.identifier, name: name, turning: b.year.flatMap { y in today.year.map { $0 - y } }))
        }
        return out.sorted { $0.name < $1.name }
    }
}
