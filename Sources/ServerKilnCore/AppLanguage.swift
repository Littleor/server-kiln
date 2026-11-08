import Foundation

public enum AppLanguage {
    public static var code: String {
        let args = CommandLine.arguments
        if args.contains("--snapshot"), let index = args.firstIndex(of: "--language"),
           index + 1 < args.count, ["en", "zh-Hans"].contains(args[index + 1]) {
            return args[index + 1]
        }
        return UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
    }
    public static var locale: Locale { code == "system" ? .current : Locale(identifier: code) }
    public static var bundle: Bundle {
        guard code != "system", let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}

public extension String {
    /// Resolve explicit strings with the same language as SwiftUI's environment.
    init(appLocalized value: String.LocalizationValue) {
        self.init(localized: value, bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }
}
