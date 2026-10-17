import SwiftUI
import XTermXKit

struct InterfaceLanguagePicker: View {
    @AppStorage(InterfaceLanguage.preferenceKey) private var language = InterfaceLanguage.system.rawValue
    var body: some View {
        Picker("Interface language", selection: $language) {
            ForEach(InterfaceLanguage.allCases) { option in
                Text(LocalizedStringKey(option.nativeName)).tag(option.rawValue)
            }
        }
    }
}
