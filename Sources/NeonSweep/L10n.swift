import Foundation
import SwiftUI

/// Bundle de traducciones español (el inglés es la clave misma).
private let esBundle: Bundle? = Bundle.module
    .path(forResource: "es", ofType: "lproj")
    .flatMap(Bundle.init(path:))

/// Traduce una clave (texto en inglés) al idioma activo.
nonisolated func t(_ key: String) -> String {
    let code = UserDefaults.standard.string(forKey: "lang")
        ?? (Locale.preferredLanguages.first?.hasPrefix("es") == true ? "es" : "en")
    guard code == "es", let esBundle else { return key }
    return esBundle.localizedString(forKey: key, value: key, table: nil)
}

/// Idioma activo de la interfaz; el cambio fuerza reconstruir las vistas.
@MainActor
final class Lang: ObservableObject {
    static let shared = Lang()
    @Published private(set) var code: String

    private init() {
        code = UserDefaults.standard.string(forKey: "lang")
            ?? (Locale.preferredLanguages.first?.hasPrefix("es") == true ? "es" : "en")
    }

    func toggle() {
        code = code == "es" ? "en" : "es"
        UserDefaults.standard.set(code, forKey: "lang")
    }
}
