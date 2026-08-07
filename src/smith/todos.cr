require "json"

module Smith
  # The plan a multi-step run is following, kept as a structured artifact
  # instead of only implicitly in the transcript — where context compaction
  # would drop it first.
  #
  # Deliberately independent of the tool that writes it and of the event bus,
  # so session persistence and the renderers can use it without knowing about
  # the tool registry. The only way out is the optional `on_change` callback,
  # which the CLI wires to the renderer.
  class TodoList
    enum Status
      Pending
      InProgress
      Completed
    end

    struct Item
      include JSON::Serializable

      getter content : String
      getter status : Status

      def initialize(@content : String, @status : Status)
      end
    end

    getter items : Array(Item)
    property on_change : Proc(Array(Item), Nil)?

    def initialize(@items : Array(Item) = Array(Item).new)
    end

    # Replaces the complete list. Incremental patching would need the model to
    # track indices correctly across turns; a full rewrite cannot desynchronise.
    def replace(items : Array(Item)) : Nil
      in_progress = items.count(&.status.in_progress?)
      if in_progress > 1
        raise ArgumentError.new("Only one todo may be in_progress at a time, got #{in_progress}. Mark the others as pending or completed.")
      end

      @items = items
      @on_change.try &.call(items)
    end

    def summary : String
      counts = Hash(Status, Int32).new(0)
      @items.each { |i| counts[i.status] += 1 }

      "#{counts[Status::InProgress]} in progress, #{counts[Status::Pending]} pending, #{counts[Status::Completed]} completed"
    end

    def empty? : Bool
      @items.empty?
    end
  end
end
