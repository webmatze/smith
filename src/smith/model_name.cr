require "./config"

module Smith
  # What can honestly be checked about a model name before it is sent.
  #
  # Deliberately *not* an allow-list: Config::BUILTIN_MODELS is a per-provider
  # default, not a roster, and there is no offline list of every model a
  # provider will accept — one would reject models released next week. So this
  # rejects only what cannot be a model name under any provider and leaves the
  # real question to the provider, which answers it at the next request.
  #
  # Pure on purpose: no session, no provider, no network, so every branch is
  # reachable from a spec.
  module ModelName
    # Why this name is not worth sending, or nil when it is.
    def self.rejection(name : String) : String?
      return "A model name cannot be empty." if name.blank?

      # A provider is not a model. Switching providers means another client and
      # another API key, so it stays a restart rather than a chat command.
      if Config::BUILTIN_MODELS.has_key?(name.downcase)
        return "'#{name}' is a provider, not a model. Restart with --provider #{name.downcase} to change provider."
      end

      # Every provider's model names are bare identifiers — sometimes with a
      # vendor prefix (`anthropic/claude-sonnet-5`) or a tag (`gemma4:latest`).
      # None of them is a sentence, a flag, an absolute path or a quoted
      # string, and passing one on would only buy a rejection a request later.
      return "'#{name}' is not a model name — it must be a single word." if name.each_char.any?(&.whitespace?)
      return "'#{name}' is not a model name — it looks like a command-line flag." if name.starts_with?('-')
      return "'#{name}' is not a model name — it looks like a path." if name.starts_with?('/')
      return "'#{name}' is not a model name — it must not contain quotes." if name.includes?('"') || name.includes?('\'')

      nil
    end
  end
end
