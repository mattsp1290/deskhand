/// Why an app is on the default deny list (plan, "Safety and privacy").
public enum SensitiveAppCategory: String, CaseIterable, Sendable {
    /// Terminals and anything else that runs arbitrary commands or scripts.
    case terminal
    case systemSettings = "system_settings"
    case keychain
    case passwordManager = "password_manager"
    case mail
    case messaging
    /// deskhand cannot tell whether a browser is signed in to Forge, so every browser is denied.
    case browser

    /// Whether apps of this category are also left out of screenshots by default. Browsers and System
    /// Settings stay visible: they are denied for input, and what they show is not secret by default.
    public var excludedFromCaptureByDefault: Bool {
        switch self {
        case .terminal, .keychain, .passwordManager, .mail, .messaging: true
        case .systemSettings, .browser: false
        }
    }
}

/// Whether a default bundle identifier is known to be the app's real one, or still has to be checked
/// on a Mac with the app installed (`mdls -name kMDItemCFBundleIdentifier <app>`).
public enum IdentifierConfidence: Sendable {
    case known, unconfirmed
}

/// One row of the default deny list.
public struct DefaultDenyEntry: Sendable {
    public let family: BundleIDFamily
    public let app: String
    public let category: SensitiveAppCategory
    public let confidence: IdentifierConfidence
}

extension DefaultDenyEntry {
    /// Sensitive apps denied out of the box. Each entry also covers identifiers nested under it, so
    /// `com.google.Chrome` covers the beta, dev and canary channels and Chrome's installed web apps.
    public static let all: [DefaultDenyEntry] = [
        row("com.apple.Terminal", "Terminal", .terminal),
        row("com.googlecode.iterm2", "iTerm2", .terminal),
        row("dev.warp.Warp-Stable", "Warp", .terminal),
        row("net.kovidgoyal.kitty", "kitty", .terminal),
        row("com.github.wez.wezterm", "WezTerm", .terminal),
        row("com.mitchellh.ghostty", "Ghostty", .terminal),
        row("org.alacritty", "Alacritty", .terminal, .unconfirmed),
        row("co.zeit.hyper", "Hyper", .terminal, .unconfirmed),
        row("com.apple.ScriptEditor2", "Script Editor", .terminal),
        row("com.apple.Automator", "Automator", .terminal),
        row("com.apple.shortcuts", "Shortcuts", .terminal),

        row("com.apple.systempreferences", "System Settings", .systemSettings),

        row("com.apple.keychainaccess", "Keychain Access", .keychain),
        row("com.apple.Passwords", "Passwords", .keychain, .unconfirmed),

        row("com.1password.1password", "1Password 8", .passwordManager),
        row("com.agilebits.onepassword7", "1Password 7", .passwordManager),
        row("com.bitwarden.desktop", "Bitwarden", .passwordManager),
        row("org.keepassxc.keepassxc", "KeePassXC", .passwordManager),
        row("com.dashlane.dashlanephonefinal", "Dashlane", .passwordManager, .unconfirmed),
        row("in.sinew.Enpass-Desktop", "Enpass", .passwordManager, .unconfirmed),
        row("com.lastpass.LastPass", "LastPass", .passwordManager, .unconfirmed),
        row("me.proton.pass.electron", "Proton Pass", .passwordManager, .unconfirmed),

        row("com.apple.mail", "Mail", .mail),
        row("com.microsoft.Outlook", "Outlook", .mail),
        row("org.mozilla.thunderbird", "Thunderbird", .mail),
        row("com.readdle.smartemail-Mac", "Spark Classic", .mail),
        row("com.readdle.SparkDesktop", "Spark", .mail, .unconfirmed),
        row("com.mimestream.Mimestream", "Mimestream", .mail, .unconfirmed),
        row("com.freron.MailMate", "MailMate", .mail, .unconfirmed),
        row("it.bloop.airmail2", "Airmail", .mail, .unconfirmed),
        row("com.superhuman.electron", "Superhuman", .mail, .unconfirmed),

        row("com.apple.MobileSMS", "Messages", .messaging),
        row("com.apple.FaceTime", "FaceTime", .messaging),
        row("com.tinyspeck.slackmacgap", "Slack", .messaging),
        row("com.hnc.Discord", "Discord", .messaging),
        row("net.whatsapp.WhatsApp", "WhatsApp", .messaging),
        row("desktop.WhatsApp", "WhatsApp (Electron)", .messaging, .unconfirmed),
        row("ru.keepcoder.Telegram", "Telegram", .messaging),
        row("org.telegram.desktop", "Telegram Desktop", .messaging, .unconfirmed),
        row("com.tdesktop.Telegram", "Telegram Desktop (direct download)", .messaging, .unconfirmed),
        row("org.whispersystems.signal-desktop", "Signal", .messaging),
        row("com.microsoft.teams2", "Microsoft Teams", .messaging),
        row("com.microsoft.teams", "Microsoft Teams classic", .messaging),
        row("us.zoom.xos", "Zoom", .messaging),
        row("com.facebook.archon", "Messenger", .messaging, .unconfirmed),

        row("com.apple.Safari", "Safari", .browser),
        row("com.apple.SafariTechnologyPreview", "Safari Technology Preview", .browser),
        row("com.google.Chrome", "Google Chrome", .browser),
        row("org.chromium.Chromium", "Chromium", .browser),
        row("org.mozilla.firefox", "Firefox", .browser),
        row("org.mozilla.firefoxdeveloperedition", "Firefox Developer Edition", .browser),
        row("org.mozilla.nightly", "Firefox Nightly", .browser),
        row("company.thebrowser.Browser", "Arc", .browser),
        row("com.microsoft.edgemac", "Microsoft Edge", .browser),
        row("com.brave.Browser", "Brave", .browser),
        row("com.operasoftware.Opera", "Opera", .browser),
        row("com.operasoftware.OperaGX", "Opera GX", .browser, .unconfirmed),
        row("com.vivaldi.Vivaldi", "Vivaldi", .browser),
        row("com.kagi.kagimacOS", "Orion", .browser, .unconfirmed),
        row("app.zen-browser.zen", "Zen", .browser, .unconfirmed),
        row("com.duckduckgo.macos.browser", "DuckDuckGo", .browser, .unconfirmed),
        row("org.torproject.torbrowser", "Tor Browser", .browser, .unconfirmed),
        row("company.thebrowser.dia", "Dia", .browser, .unconfirmed),
    ]

    private static func row(
        _ bundleID: String, _ app: String, _ category: SensitiveAppCategory,
        _ confidence: IdentifierConfidence = .known
    ) -> DefaultDenyEntry {
        DefaultDenyEntry(
            family: BundleIDFamily(BundleID(bundleID)!), app: app, category: category, confidence: confidence)
    }
}
