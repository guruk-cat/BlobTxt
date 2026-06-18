import Foundation
import Combine

// The app-global source of truth for page-layout profiles. Holds the user's custom profiles plus the
// go-to profile reference (the one File → Print uses), persisted as print.json in Application Support.
// The built-in default profile is synthesized in code and never written to disk.
final class LayoutStore: ObservableObject {
    static let shared = LayoutStore()

    // Custom profiles only; the default is prepended by `allProfiles`. Kept sorted alphabetically.
    @Published private(set) var customProfiles: [LayoutProfile] = []

    // The profile File → Print renders with. Falls back to the default when its target is gone.
    @Published private(set) var goToProfileID: UUID = LayoutProfile.defaultID

    private let fileURL: URL

    private struct Persisted: Codable {
        var goToProfileID: UUID
        var profiles: [LayoutProfile]
    }

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlobTxt", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("print.json")
        load()
    }

    // MARK: - Derived

    // The full list shown in the panel: the default pinned at the top, then custom profiles A→Z.
    var allProfiles: [LayoutProfile] {
        [LayoutProfile.defaultProfile] + customProfiles
    }

    func profile(for id: UUID) -> LayoutProfile {
        if id == LayoutProfile.defaultID { return .defaultProfile }
        return customProfiles.first { $0.id == id } ?? .defaultProfile
    }

    // The profile to print with, resolved through the go-to reference.
    var goToProfile: LayoutProfile { profile(for: goToProfileID) }

    func isGoTo(_ id: UUID) -> Bool { id == goToProfileID }

    // MARK: - Mutation

    // Creates a profile identical to the default, named uniquely, and returns it (already persisted).
    @discardableResult
    func addProfile() -> LayoutProfile {
        var profile = LayoutProfile.defaultProfile
        profile.id = UUID()
        profile.name = uniqueName("Untitled Profile", excluding: nil)
        customProfiles.append(profile)
        sortAndSave()
        return profile
    }

    // Forks a profile, appending " (n)" to keep the name unique, and returns the copy.
    @discardableResult
    func duplicate(_ source: LayoutProfile) -> LayoutProfile {
        var copy = source
        copy.id = UUID()
        copy.name = uniqueName(source.name, excluding: nil)
        customProfiles.append(copy)
        sortAndSave()
        return copy
    }

    func remove(_ id: UUID) {
        customProfiles.removeAll { $0.id == id }
        if goToProfileID == id { goToProfileID = LayoutProfile.defaultID }
        sortAndSave()
    }

    // Commits edits to an existing custom profile. The name is normalized for uniqueness so a rename
    // can never collide with another profile.
    func update(_ profile: LayoutProfile) {
        guard let index = customProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var normalized = profile
        normalized.name = uniqueName(profile.name, excluding: profile.id)
        customProfiles[index] = normalized
        sortAndSave()
    }

    func setGoTo(_ id: UUID) {
        goToProfileID = id
        save()
    }

    // MARK: - Naming

    // Returns `base` if free, otherwise "base (2)", "base (3)", … skipping the profile being renamed.
    func uniqueName(_ base: String, excluding id: UUID?) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.isEmpty ? "Untitled Profile" : trimmed
        var taken = Set(customProfiles.filter { $0.id != id }.map(\.name))
        taken.insert("Default")
        guard taken.contains(candidate) else { return candidate }
        var n = 2
        while taken.contains("\(candidate) (\(n))") { n += 1 }
        return "\(candidate) (\(n))"
    }

    // MARK: - Persistence

    private func sortAndSave() {
        customProfiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        customProfiles = decoded.profiles.filter { !$0.isDefault }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        goToProfileID = decoded.goToProfileID
    }

    private func save() {
        let payload = Persisted(goToProfileID: goToProfileID, profiles: customProfiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
