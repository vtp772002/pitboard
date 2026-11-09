enum DefaultsKey {
    static let menuBarShows = "menuBarShows"
    static let settingsTab = "settingsTab"
    static let antigravityProfiles = "antigravityProfiles"
    static let antigravityQuota = "antigravityQuota"
    static let antigravityActiveProfile = "antigravityActiveProfile"
    static let antigravityInspectorProfile = "antigravityInspectorProfile"
    static let antigravityAutoSwitch = "antigravityAutoSwitch"

    /// Where this app kept what the model now keeps in `app.json`, read once to hand over.
    enum Earlier {
        static let hasBeenSeen = "hasBeenSeen"
        /// The tools somebody said "Not Now" to a second account for, by code.
        static let secondAccountDeclined = "secondAccountDeclined"
        /// "Not Now" said before there was a second tool, which was about Claude Code.
        static let hideSecondAccountNudge = "hideSecondAccountNudge"

        static let all = [hasBeenSeen, secondAccountDeclined, hideSecondAccountNudge]

        /// The account windows' stores each Pitboard directory made, by the directory's
        /// path, each store as `UUID.uuidString` writes it.
        static let webStores = "webStores"
        /// The page each account window was last on, by the Pitboard directory's path and
        /// the window's store.
        static let windowPages = "windowPages"

        static let windows = [webStores, windowPages]
    }
}
