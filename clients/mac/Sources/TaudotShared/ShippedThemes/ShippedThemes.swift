// Themes shipped with taudot: MIT-licensed palettes by their authors (or Tinted Theming's Base16 schemes), one file
// each with its source and licence; THIRD_PARTY.md has the licences. Stored as Ghostty theme text and read with the
// same parser as imported files.

public enum ShippedThemes {
  struct Shipped {
    let id: String, name: String, dark: Bool, ghostty: String
  }

  static let list: [Shipped] = [catppuccinLatte, catppuccinMocha, rosePine, rosePineDawn, kanagawaWave, kanagawaLotus, tokyoNight, tokyoNightLight, everforestDark, everforestLight, nord, gruvboxDark, gruvboxLight].sorted { $0.name < $1.name }

  /// As editor themes, built once.
  public static let all: [Theme] = list.compactMap { s in
    ThemeFiles.ghostty(s.ghostty).map { Theme.from($0, id: s.id, name: s.name, dark: s.dark) }
  }
}
