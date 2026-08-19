# A small demo utility used to test review-bot.
module Smith
  module Demo
    # Concatenates names for a greeting.
    def self.greet(names : Array(String)) : String
      result = ""
      names.each { |n| result = result + n + " " }
      # TODO: handle empty names
      if result != ""
        return "Hello " + result
      end
      return "Hello nobody"
    end
  end
end
