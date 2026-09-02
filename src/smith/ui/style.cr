require "anvil"

module Smith::UI
  # The text layer comes from anvil. What is left here are the names smith
  # knows it by, plus the palette.
  #
  # `Style`, `Span`, `StyledLine` and the line helpers (widths, wrapping,
  # truncation, ANSI output) are the same there — with two differences smith
  # has taken on: colors are `Anvil::Text::Color` rather than raw 256-colour
  # indices, and the attribute is called `reverse` rather than `invert`.
  #
  # anvil computes widths over grapheme clusters and termisu's Unicode tables
  # instead of the approximation that used to live here, which is more
  # accurate for emoji with variation selectors and for combining marks.
  alias Style = Anvil::Text::Style
  alias Span = Anvil::Text::Span
  alias StyledLine = Anvil::Text::StyledLine
  alias Color = Anvil::Text::Color

  alias LineUtil = Anvil::Text

  # The palette used across the UI — 256-colour codes, which every terminal
  # smith realistically meets understands.
  module Palette
    USER      = Color.ansi256(39)  # blue
    SUCCESS   = Color.ansi256(71)  # green
    ERROR     = Color.ansi256(167) # red
    WARN      = Color.ansi256(179)
    INFO      = Color.ansi256(245) # grey
    ACCENT    = Color.ansi256(75)  # light blue
    THINKING  = Color.ansi256(245)
    BORDER    = Color.ansi256(240)
    CODE      = Color.ansi256(114)
    HEADING   = Color.ansi256(75)
    LINK      = Color.ansi256(75)
    TODO_DONE = Color.ansi256(245)
    MODE_PLAN = Color.ansi256(214) # orange
  end
end
