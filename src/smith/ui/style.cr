require "anvil"

module Smith::UI
  # Die Text-Schicht kommt aus anvil. Hier stehen nur noch die Namen, unter
  # denen smith sie kennt, und die Palette.
  #
  # `Style`, `Span`, `StyledLine` und die Zeilenhelfer (Breiten, Umbruch,
  # Kürzung, ANSI-Ausgabe) sind dort dieselben — mit zwei Unterschieden, die
  # smith übernommen hat: Farben sind `Anvil::Text::Color` statt roher
  # 256er-Indizes, und das Attribut heißt `reverse` statt `invert`.
  #
  # Breiten rechnet anvil über Grapheme-Cluster und termisus Unicode-Tabellen
  # statt über die frühere Näherung hier; das ist bei Emoji mit
  # Variation Selector und kombinierenden Zeichen genauer.
  alias Style = Anvil::Text::Style
  alias Span = Anvil::Text::Span
  alias StyledLine = Anvil::Text::StyledLine
  alias Color = Anvil::Text::Color

  alias LineUtil = Anvil::Text

  # Die Palette der Oberfläche — 256-Farben, die jedes Terminal versteht, dem
  # smith realistisch begegnet.
  module Palette
    USER      = Color.ansi256(39)  # blau
    SUCCESS   = Color.ansi256(71)  # grün
    ERROR     = Color.ansi256(167) # rot
    WARN      = Color.ansi256(179)
    INFO      = Color.ansi256(245) # grau
    ACCENT    = Color.ansi256(75)  # hellblau
    THINKING  = Color.ansi256(245)
    BORDER    = Color.ansi256(240)
    CODE      = Color.ansi256(114)
    HEADING   = Color.ansi256(75)
    LINK      = Color.ansi256(75)
    TODO_DONE = Color.ansi256(245)
    MODE_PLAN = Color.ansi256(214) # orange
  end
end
