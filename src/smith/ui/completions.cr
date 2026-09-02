module Smith::UI
  # One entry in the autocomplete popup. Built-in chat commands and skills
  # share the list — both are invoked with a leading slash, and the popup is
  # the place where a human sees that skills cannot shadow built-ins.
  record Completion,
    name : String,
    description : String,
    takes_args : Bool = false,
    builtin : Bool = true

  # The autocomplete popup's state: which entries match the query, which one
  # is selected, and which window of them is visible. Pure logic — the app
  # draws it, so the palette can be spec'ed without a terminal.
  class CommandPalette
    # How many rows the popup shows before scrolling. Long enough to see a
    # real list, short enough not to bury the prompt.
    VISIBLE_ROWS = 8

    getter matches : Array(Completion) = Array(Completion).new
    getter selected : Int32 = 0

    def initialize(@all : Array(Completion))
    end

    # Recomputes the filtered list for a new query. Resets the selection:
    # every keystroke that changes the query starts the choice over.
    def update(query : String) : Nil
      @matches = filter(query)
      @selected = 0
      @top = 0
    end

    # The popup is up when there is something to choose from. A space ends
    # the command word — what follows is an argument, not a filter.
    def open? : Bool
      !@matches.empty?
    end

    def current : Completion?
      @matches[@selected]?
    end

    def move_up : Nil
      @selected -= 1 if @selected > 0
      adjust_window
    end

    def move_down : Nil
      @selected += 1 if @selected < @matches.size - 1
      adjust_window
    end

    # The rows the popup actually shows, plus where the window starts — the
    # app draws the scroll marker from the two together.
    def visible : Array(Completion)
      @matches[@top, Math.min(VISIBLE_ROWS, @matches.size - @top)]
    end

    getter top : Int32 = 0

    # The query the popup filters on: a leading slash with nothing but the
    # command word typed so far. nil when the text is not a command-in-progress.
    def self.query_for(text : String) : String?
      return nil unless text.starts_with?('/')
      return nil if text.includes?(' ')
      text
    end

    private def filter(query : String) : Array(Completion)
      return Array(Completion).new unless query.starts_with?('/')
      return Array(Completion).new if query.includes?(' ')

      wanted = query.downcase
      @all.select { |completion| completion.name.downcase.starts_with?(wanted) }
        .sort_by { |completion| {completion.builtin ? 0 : 1, completion.name} }
    end

    private def adjust_window : Nil
      # Keep the selection inside the visible window: scrolling down puts it
      # on the window's last row, scrolling up on its first.
      @top = @selected - VISIBLE_ROWS + 1 if @selected >= @top + VISIBLE_ROWS
      @top = @selected if @selected < @top

      max_top = @matches.size - VISIBLE_ROWS
      max_top = 0 if max_top < 0
      @top = max_top if @top > max_top
      @top = 0 if @top < 0
    end
  end
end
