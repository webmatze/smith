require "./style"

module Smith::UI
  # One entry in the autocomplete popup. Built-in chat commands and skills
  # share the list — both are invoked with a leading slash, and the popup is
  # the place where a human sees that skills cannot shadow built-ins.
  # `takes_args` means an argument may follow, so completing the word leaves
  # the cursor after a space. `optional_args` narrows that: the bare form does
  # something too, so a fully typed command runs on the first Enter instead of
  # waiting for an argument nobody has to give.
  record Completion,
    name : String,
    description : String,
    takes_args : Bool = false,
    optional_args : Bool = false,
    builtin : Bool = true

  # The autocomplete popup.
  #
  # The window mechanics — selection, scrolling, the visible slice — come from
  # `Anvil::Widgets::ListPopup`. What stays here is what is smith's own: a
  # command word is matched by *prefix*, built-ins sort ahead of skills, and
  # the selection clamps at both ends rather than wrapping.
  class CommandPalette < Anvil::Widgets::ListPopup(Completion)
    # How many rows the popup shows before scrolling. Long enough to see a
    # real list, short enough not to bury the prompt.
    VISIBLE_ROWS = 8

    def initialize(all : Array(Completion))
      super(all,
        max_visible: VISIBLE_ROWS,
        label: ->(c : Completion) { c.name },
        description: ->(c : Completion) { c.description },
        filter: ->(items : Array(Completion), query : String) { CommandPalette.filter(items, query) },
        wrap_around: false)
    end

    # The query the popup filters on: a leading slash with nothing but the
    # command word typed so far. nil when the text is not a command-in-progress.
    def self.query_for(text : String) : String?
      return nil unless text.starts_with?('/')
      return nil if text.includes?(' ')
      text
    end

    # A space ends the command word — what follows is an argument, not a filter.
    def self.filter(items : Array(Completion), query : String) : Array(Completion)
      return Array(Completion).new unless query.starts_with?('/')
      return Array(Completion).new if query.includes?(' ')

      wanted = query.downcase
      items.select { |completion| completion.name.downcase.starts_with?(wanted) }
        .sort_by { |completion| {completion.builtin ? 0 : 1, completion.name} }
    end
  end
end
