import SwiftUI
import ServerKilnCore

public struct AppLanguagePicker: View {
    @AppStorage("appLanguage") private var language = "system"
    public init() {}
    public var body: some View {
        #if os(macOS)
        PillPicker(selection: $language, options: [
            ("system", String(appLocalized: "跟随系统")),
            ("zh-Hans", "简体中文"), ("en", "English")
        ])
        .accessibilityLabel(Text("语言"))
        #else
        Picker(selection: $language) {
            Text("跟随系统").tag("system")
            Text(verbatim: "简体中文").tag("zh-Hans")
            Text(verbatim: "English").tag("en")
        } label: {
            Label("语言", systemImage: "globe")
        }
        #endif
    }
}

public struct AppLanguageModifier: ViewModifier {
    @AppStorage("appLanguage") private var language = "system"
    public init() {}
    public func body(content: Content) -> some View {
        content
            .environment(\.locale, language == "system" ? .current : Locale(identifier: language))
            .id(language)
    }
}
