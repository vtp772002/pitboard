import Foundation
import PitboardKit
import SwiftUI

/// Antigravity CLI credentials stay in agyw; Pitboard stores profile names and quota snapshots.
struct AntigravitySettings: View {
    @AppStorage(DefaultsKey.antigravityProfiles) private var saved = ""
    @AppStorage(DefaultsKey.antigravityQuota) private var quotaCache = "{}"
    @AppStorage(DefaultsKey.antigravityActiveProfile) private var activeProfile = ""
    @AppStorage(DefaultsKey.antigravityInspectorProfile) private var inspectorProfile = ""
    @State private var draft = ""
    @State private var shellIntegrationError: String?
    @State private var refreshing: Set<String> = []
    @State private var quotaFailures: [String: String] = [:]

    private var profiles: [String] { saved.split(separator: "\n").map(String.init) }

    private var quotaByProfile: [String: AntigravityQuotaSnapshot] {
        guard let data = quotaCache.data(using: .utf8),
            let values = try? JSONDecoder().decode(
                [String: AntigravityQuotaSnapshot].self, from: data)
        else { return [:] }
        return values
    }

    var body: some View {
        Form {
            Section("Profiles and quota") {
                if profiles.isEmpty {
                    Text("No Antigravity CLI profiles yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(profiles, id: \.self) { profile in
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent(profile) {
                                HStack {
                                    Button(activeProfile == profile ? "Selected" : "Select") {
                                        select(profile)
                                    }
                                    .accessibilityIdentifier("antigravity.open.\(profile)")
                                    Button("Remove", role: .destructive) {
                                        remove(profile)
                                    }
                                    .accessibilityIdentifier("antigravity.remove.\(profile)")
                                }
                            }
                            quotaView(for: profile)
                        }
                        .padding(.vertical, 3)
                    }
                }
                if let shellIntegrationError {
                    Text(shellIntegrationError).font(.footnote).foregroundStyle(.red)
                }
            }

            Section("Add an account") {
                TextField("Profile name (e.g. work)", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("antigravity.profileName")
                if !draft.isEmpty && !validDraft {
                    Text("Use a short profile name like work, not your Google email.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Add Profile") { add() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!validDraft)
                        .accessibilityIdentifier("antigravity.add")
                }
                Text(
                    "Requires agyw. Select a profile here, then run `agy` in your own terminal. "
                        + "If it is a new profile, agy will ask you to sign in. Removing a name here "
                        + "does not delete its agyw login."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                if let guide = URL(string: "https://github.com/tranquocthong/agy-switcher") {
                    Link("Install agyw", destination: guide)
                }
            }

        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .task { refreshStaleProfiles() }
    }

    private var validDraft: Bool { AntigravityTerminal.valid(draft) }

    private func add() {
        guard validDraft else { return }
        let profile = draft
        if !profiles.contains(profile) {
            saved = (profiles + [profile]).joined(separator: "\n")
        }
        draft = ""
        select(profile)
    }

    private func remove(_ profile: String) {
        saved = profiles.filter { $0 != profile }.joined(separator: "\n")
        if activeProfile == profile { activeProfile = "" }
        if inspectorProfile == profile { inspectorProfile = "" }
        var values = quotaByProfile
        values.removeValue(forKey: profile)
        if let data = try? JSONEncoder().encode(values),
            let json = String(data: data, encoding: .utf8)
        {
            quotaCache = json
        }
        quotaFailures[profile] = nil
    }

    private func select(_ profile: String) {
        guard AntigravityTerminal.valid(profile) else { return }
        activeProfile = profile
        do {
            try AntigravityShellRouting.install()
            shellIntegrationError = nil
        } catch {
            shellIntegrationError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func quotaView(for profile: String) -> some View {
        if let snapshot = quotaByProfile[profile] {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.name).font(.subheadline.weight(.medium))
                        ForEach(group.buckets) { bucket in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(bucket.name)
                                    Spacer()
                                    Text(
                                        "\(Int((bucket.remainingFraction * 100).rounded()))% left"
                                    )
                                    .monospacedDigit()
                                }
                                .font(.caption)
                                ProgressView(value: bucket.remainingFraction)
                                if let reset = bucket.resetDate {
                                    Text(antigravityResetLabel(reset))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Text(
                        "Updated \(snapshot.fetchedAt.formatted(.relative(presentation: .named)))"
                    )
                    Spacer()
                    refreshButton(profile)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let error = quotaFailures[profile] {
                    Text("Refresh failed: \(error)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.leading, 8)
        } else {
            HStack {
                Text(quotaFailures[profile] ?? "Quota not loaded yet")
                    .font(.caption)
                    .foregroundStyle(
                        quotaFailures[profile] == nil ? Color.secondary : Color.red)
                Spacer()
                refreshButton(profile)
            }
        }
    }

    private func refreshButton(_ profile: String) -> some View {
        Button(refreshing.contains(profile) ? "Checking…" : "Refresh quota") {
            refresh(profile)
        }
        .disabled(refreshing.contains(profile))
        .accessibilityIdentifier("antigravity.quota.refresh.\(profile)")
    }

    private func refreshStaleProfiles() {
        let now = Date()
        for profile in profiles {
            if let snapshot = quotaByProfile[profile],
                now.timeIntervalSince(snapshot.fetchedAt) < 300
            {
                continue
            }
            refresh(profile)
        }
    }

    private func refresh(_ profile: String) {
        guard !refreshing.contains(profile), AntigravityTerminal.valid(profile) else { return }
        refreshing.insert(profile)
        quotaFailures[profile] = nil
        Task {
            defer { refreshing.remove(profile) }
            do {
                let snapshot = try await AntigravityQuotaReader.read(profile)
                var values = quotaByProfile
                values[profile] = snapshot
                if let data = try? JSONEncoder().encode(values),
                    let json = String(data: data, encoding: .utf8)
                {
                    quotaCache = json
                }
            } catch {
                quotaFailures[profile] = error.localizedDescription
            }
        }
    }
}

private struct AntigravityQuotaSnapshot: Codable, Sendable {
    var fetchedAt: Date
    var groups: [AntigravityQuotaGroup]
}

private struct AntigravityQuotaGroup: Codable, Identifiable, Sendable {
    var name: String
    var buckets: [AntigravityQuotaBucket]
    var id: String { name }
}

private struct AntigravityQuotaBucket: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var remainingFraction: Double
    var window: String?
    var resetTime: String?

    var resetDate: Date? {
        guard let resetTime else { return nil }
        return ISO8601DateFormatter().date(from: resetTime)
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case remainingFraction = "remaining_fraction"
        case window
        case resetTime = "reset_time"
    }
}

private enum AntigravityQuotaReader {
    static func read(_ profile: String) async throws -> AntigravityQuotaSnapshot {
        try await Task.detached(priority: .utility) {
            guard AntigravityTerminal.valid(profile) else { throw ReadError.invalidProfile }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                "-lc", "exec agyw exec \(profile) -p /usage --output-format json",
            ]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()

            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()

            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                throw ReadError.commandFailed(
                    message?.isEmpty == false
                        ? message! : "agyw exited with status \(process.terminationStatus).")
            }
            guard
                let root = try JSONSerialization.jsonObject(with: outputData) as? [String: Any],
                let command = root["command"] as? [String: Any],
                let data = command["data"] as? [String: Any],
                let groups = data["groups"]
            else { throw ReadError.unexpectedOutput }
            let payload = try JSONSerialization.data(withJSONObject: ["groups": groups])
            let decoded = try JSONDecoder().decode(GroupPayload.self, from: payload)
            return AntigravityQuotaSnapshot(fetchedAt: Date(), groups: decoded.groups)
        }.value
    }

    private struct GroupPayload: Decodable { var groups: [AntigravityQuotaGroup] }

    private enum ReadError: LocalizedError {
        case invalidProfile
        case commandFailed(String)
        case unexpectedOutput

        var errorDescription: String? {
            switch self {
            case .invalidProfile: return "The profile name is invalid."
            case .commandFailed(let message): return message
            case .unexpectedOutput: return "agy returned quota data in an unknown format."
            }
        }
    }
}

private func antigravityResetLabel(_ date: Date) -> String {
    let day = date.formatted(.dateTime.month(.abbreviated).day())
    let time = date.formatted(date: .omitted, time: .shortened)
    return "Resets \(day) · \(time)"
}

private enum AntigravityTerminal {
    static func valid(_ profile: String) -> Bool {
        guard !profile.isEmpty, profile.utf8.count <= 32 else { return false }
        let bytes = Array(profile.utf8)
        let startsWithLetterOrNumber =
            bytes.first.map {
                ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57)
            } ?? false
        return startsWithLetterOrNumber
            && bytes.allSatisfy {
                ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                    || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
            }
    }
}

private enum AntigravityShellRouting {
    private static let begin = "# BEGIN PITBOARD AGY ROUTING"
    private static let end = "# END PITBOARD AGY ROUTING"
    private static let block = """
        # BEGIN PITBOARD AGY ROUTING
        agy() {
          if [[ -n "${AGYW_PROFILE:-}" ]]; then
            command agy "$@"
            return
          fi
          local profile
          profile=$(/usr/bin/defaults read com.usepitboard.Pitboard antigravityActiveProfile 2>/dev/null) || profile=""
          if [[ -n "$profile" && ${#profile} -le 32 && "$profile" == [[:alnum:]]* && "$profile" != *[^[:alnum:]_-]* ]]; then
            command agyw exec "$profile" "$@"
          else
            command agy "$@"
          fi
        }
        # END PITBOARD AGY ROUTING
        """

    static func install() throws {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configDirectory = URL(
            fileURLWithPath: environment["ZDOTDIR"] ?? home.path, isDirectory: true)
        let zshrc = configDirectory.appendingPathComponent(".zshrc")
        var contents = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        if contents.contains(begin), contents.contains(end) { return }

        let hasExistingAgyCommand = contents.split(separator: "\n").contains { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("agy()") || line.hasPrefix("function agy")
                || line.hasPrefix("alias agy=")
        }
        guard !hasExistingAgyCommand else { throw RoutingError.existingCommand }

        if !FileManager.default.fileExists(atPath: configDirectory.path) {
            try FileManager.default.createDirectory(
                at: configDirectory, withIntermediateDirectories: true)
        }
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents.append("\n") }
        contents.append("\n" + block + "\n")
        try contents.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    private enum RoutingError: LocalizedError {
        case existingCommand

        var errorDescription: String? {
            "Your .zshrc already defines agy, so Pitboard left it unchanged."
        }
    }
}

/// Antigravity profiles share the Accounts list, but agyw keeps each login in its own HOME.
struct AntigravityAccountSection: View {
    @AppStorage(DefaultsKey.antigravityProfiles) private var saved = ""
    @AppStorage(DefaultsKey.antigravityQuota) private var quotaCache = "{}"
    @AppStorage(DefaultsKey.antigravityActiveProfile) private var activeProfile = ""
    @AppStorage(DefaultsKey.antigravityInspectorProfile) private var inspectorProfile = ""
    @AppStorage(DefaultsKey.antigravityAutoSwitch) private var autoSwitch = true
    @State private var draft = ""
    @State private var shellIntegrationError: String?
    @State private var refreshing: Set<String> = []
    @State private var failures: [String: String] = [:]

    private var profiles: [String] { saved.split(separator: "\n").map(String.init) }

    private var quotaByProfile: [String: AntigravityQuotaSnapshot] {
        guard let data = quotaCache.data(using: .utf8),
            let values = try? JSONDecoder().decode(
                [String: AntigravityQuotaSnapshot].self, from: data)
        else { return [:] }
        return values
    }

    private var validDraft: Bool { AntigravityTerminal.valid(draft) }

    var body: some View {
        Section {
            ForEach(profiles, id: \.self) { profile in
                VStack(alignment: .leading, spacing: Design.rowSpacing) {
                    HStack(spacing: Design.iconSpacing) {
                        Image(
                            systemName: activeProfile == profile
                                ? "person.crop.circle.fill" : Symbol.account
                        )
                        .font(.title2)
                        .foregroundStyle(
                            activeProfile == profile
                                ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                        )
                        .frame(width: 26)
                        .accessibilityHidden(true)
                        Text(profile).fontWeight(.medium)
                        Spacer(minLength: Design.iconSpacing)
                        if activeProfile == profile {
                            Label("Selected for next agy run", systemImage: "checkmark")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Switch") { select(profile) }
                                .accessibilityIdentifier(
                                    "antigravity.account.switch.\(profile)")
                        }
                    }
                    if let snapshot = quotaByProfile[profile] {
                        let limits = quotaLimits(snapshot)
                        if !limits.isEmpty {
                            UsageBars(limits: limits)
                                .padding(.leading, 34)
                        }
                        HStack {
                            Text(
                                "Updated \(snapshot.fetchedAt.formatted(.relative(presentation: .named)))"
                            )
                            Spacer()
                            Button(refreshing.contains(profile) ? "Checking…" : "Refresh") {
                                refresh(profile)
                            }
                            .disabled(refreshing.contains(profile))
                            .accessibilityIdentifier("antigravity.account.refresh.\(profile)")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 34)
                    } else {
                        HStack(spacing: Design.iconSpacing) {
                            Text(
                                failures[profile]
                                    ?? (refreshing.contains(profile)
                                        ? "Checking quota…" : "Quota not loaded")
                            )
                            .explanatory()
                            Spacer()
                            Button("Refresh") { refresh(profile) }
                                .disabled(refreshing.contains(profile))
                                .accessibilityIdentifier(
                                    "antigravity.account.refresh.\(profile)")
                        }
                        .padding(.leading, 34)
                    }
                    if quotaByProfile[profile] != nil, let failure = failures[profile] {
                        Text(failure).font(.caption).foregroundStyle(.red).padding(.leading, 34)
                    }
                }
                .padding(.vertical, 3)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 34 }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("antigravity.account.\(profile)")
                .tag("antigravity/\(profile)")
            }

            HStack {
                TextField("New profile name, e.g. work", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("antigravity.account.profileName")
                Button("Add profile") { add() }
                    .disabled(!validDraft)
                    .accessibilityIdentifier("antigravity.account.add")
            }
            if !draft.isEmpty && !validDraft {
                Text(
                    "Use 1–32 letters or numbers, with - or _; this is a profile name, not an email."
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
            if let shellIntegrationError {
                Text(shellIntegrationError).font(.caption).foregroundStyle(.red)
            }
            Toggle(
                "Auto-select another profile for the next agy run when quota is nearly used",
                isOn: $autoSwitch
            )
            .font(.caption)
            .accessibilityIdentifier("antigravity.account.autoSwitch")
        } header: {
            Text("Antigravity CLI")
        } footer: {
            Text(
                "Switch updates the profile used by your next `agy` command. A running CLI session keeps its current profile; start a new session to use the selected account."
            )
        }
        .task { await refreshStaleProfiles() }
    }

    private func quotaLimits(_ snapshot: AntigravityQuotaSnapshot) -> [LimitRow] {
        snapshot.groups.flatMap { group in
            group.buckets.map { bucket in
                let used = min(max((1 - bucket.remainingFraction) * 100, 0), 100)
                let percent = Int(used.rounded())
                let isFiveHour =
                    bucket.window == "5h"
                    || bucket.id.hasSuffix("-5h")
                    || bucket.name.localizedCaseInsensitiveContains("five hour")
                let period = isFiveHour ? "5-hour" : "Weekly"
                let short: String
                if group.name == "Gemini Models" {
                    short = "Gemini \(period)"
                } else if group.name == "Claude and GPT models" {
                    short = "Claude/GPT \(period)"
                } else {
                    short = "\(group.name) \(period)"
                }
                let resets =
                    bucket.resetDate.map(antigravityResetLabel)
                    ?? "Reset time unavailable"
                let resetsIn =
                    bucket.resetDate.map { $0.formatted(.relative(presentation: .named)) } ?? ""
                return LimitRow(
                    kind: isFiveHour ? .fiveHour : .weekly,
                    name: "\(group.name) — \(bucket.name)",
                    short: short,
                    percent: used,
                    figure: "\(percent)% used",
                    used: "\(percent)% used",
                    level: used >= 90 ? .out : (used >= 70 ? .low : .plenty),
                    resetsAt: nil,
                    resets: resets,
                    resetsIn: resetsIn,
                    spoken: "\(group.name), \(bucket.name), \(percent)% used, \(resets)"
                )
            }
        }
    }

    private func add() {
        guard validDraft else { return }
        let profile = draft
        if !profiles.contains(profile) {
            saved = (profiles + [profile]).joined(separator: "\n")
        }
        draft = ""
        select(profile)
    }

    private func select(_ profile: String) {
        guard AntigravityTerminal.valid(profile) else { return }
        activeProfile = profile
        inspectorProfile = profile
        do {
            try AntigravityShellRouting.install()
            shellIntegrationError = nil
        } catch {
            shellIntegrationError = error.localizedDescription
        }
    }

    private func refreshStaleProfiles() async {
        let now = Date()
        for profile in profiles {
            if let snapshot = quotaByProfile[profile],
                now.timeIntervalSince(snapshot.fetchedAt) < 300
            {
                continue
            }
            refresh(profile)
        }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            for profile in profiles { refresh(profile) }
        }
    }

    private func refresh(_ profile: String) {
        guard !refreshing.contains(profile), AntigravityTerminal.valid(profile) else { return }
        refreshing.insert(profile)
        failures[profile] = nil
        Task {
            defer { refreshing.remove(profile) }
            do {
                let snapshot = try await AntigravityQuotaReader.read(profile)
                var values = quotaByProfile
                values[profile] = snapshot
                if let data = try? JSONEncoder().encode(values),
                    let json = String(data: data, encoding: .utf8)
                {
                    quotaCache = json
                }
                maybeAutoSelect(after: snapshot, from: profile)
            } catch {
                failures[profile] = error.localizedDescription
            }
        }
    }

    private func maybeAutoSelect(after snapshot: AntigravityQuotaSnapshot, from profile: String)
    {
        guard autoSwitch, activeProfile == profile,
            snapshot.groups.flatMap(\.buckets).contains(where: { $0.remainingFraction <= 0.05 })
        else { return }
        let candidates =
            quotaByProfile
            .filter { $0.key != profile && profiles.contains($0.key) }
            .filter {
                $0.value.groups.flatMap(\.buckets).contains(where: {
                    $0.remainingFraction > 0.05
                })
            }
        guard let next = candidates.max(by: { remaining($0.value) < remaining($1.value) })?.key
        else { return }
        activeProfile = next
    }

    private func remaining(_ snapshot: AntigravityQuotaSnapshot) -> Double {
        let fractions = snapshot.groups.flatMap(\.buckets).map(\.remainingFraction)
        return fractions.isEmpty ? 0 : fractions.reduce(0, +) / Double(fractions.count)
    }
}

struct AntigravityInspector: View {
    let profile: String

    @AppStorage(DefaultsKey.antigravityQuota) private var quotaCache = "{}"
    @AppStorage(DefaultsKey.antigravityActiveProfile) private var activeProfile = ""
    @AppStorage(DefaultsKey.antigravityInspectorProfile) private var inspectorProfile = ""
    @State private var refreshing = false
    @State private var failure: String?

    private var snapshot: AntigravityQuotaSnapshot? {
        guard let data = quotaCache.data(using: .utf8),
            let values = try? JSONDecoder().decode(
                [String: AntigravityQuotaSnapshot].self, from: data)
        else { return nil }
        return values[profile]
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Design.iconSpacing) {
                    Image(
                        systemName: activeProfile == profile
                            ? "person.crop.circle.fill" : Symbol.account
                    )
                    .font(.largeTitle)
                    .foregroundStyle(
                        activeProfile == profile
                            ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: Design.lineSpacing) {
                        Text(profile).font(.title3.weight(.semibold))
                        Text("Antigravity CLI").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, Design.rowSpacing)
            } footer: {
                Text(
                    activeProfile == profile
                        ? "Selected for the next agy run."
                        : "This profile is not selected for the next agy run.")
            }

            Section("Quota") {
                if let snapshot {
                    ForEach(snapshot.groups) { group in
                        VStack(alignment: .leading, spacing: Design.rowSpacing) {
                            Text(group.name).font(.headline)
                            ForEach(group.buckets) { bucket in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(bucket.name)
                                        Spacer()
                                        Text(
                                            "\(Int((bucket.remainingFraction * 100).rounded()))% left"
                                        )
                                        .monospacedDigit()
                                    }
                                    ProgressView(value: bucket.remainingFraction)
                                    if let reset = bucket.resetDate {
                                        Text(antigravityResetLabel(reset))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        .padding(.vertical, Design.rowSpacing)
                    }
                    LabeledContent(
                        "Updated",
                        value: snapshot.fetchedAt.formatted(.relative(presentation: .named)))
                } else {
                    Text(failure ?? "Quota not loaded yet.")
                        .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                }
            }

            if let failure, snapshot != nil {
                Text(failure).font(.caption).foregroundStyle(.red)
            }

            Section {
                if activeProfile != profile {
                    Button("Switch") { select() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
                Button(refreshing ? "Checking quota…" : "Refresh quota") { refresh() }
                    .disabled(refreshing)
                    .frame(maxWidth: .infinity)
            } footer: {
                Text(
                    "Switch applies to the next agy command. A running CLI session keeps its current profile."
                )
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("antigravity.inspector")
    }

    private func select() {
        activeProfile = profile
        inspectorProfile = profile
        do { try AntigravityShellRouting.install() } catch {
            failure = error.localizedDescription
        }
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        failure = nil
        Task {
            defer { refreshing = false }
            do {
                let updated = try await AntigravityQuotaReader.read(profile)
                var values: [String: AntigravityQuotaSnapshot] = [:]
                if let data = quotaCache.data(using: .utf8) {
                    values =
                        (try? JSONDecoder().decode(
                            [String: AntigravityQuotaSnapshot].self, from: data)) ?? [:]
                }
                values[profile] = updated
                if let data = try? JSONEncoder().encode(values),
                    let json = String(data: data, encoding: .utf8)
                {
                    quotaCache = json
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
