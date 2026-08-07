require "socket"
require "uri"

module Smith::Web
  # Keeps web_fetch from being turned into a probe of the machine it runs on.
  module Guard
    ALLOWED_SCHEMES = %w[http https]

    # Plain http is upgraded rather than refused: the request would otherwise
    # travel in the clear, and nearly every public host that answers http
    # answers https too.
    #
    # Not when private targets are allowed, though. That setting exists for
    # local development, and a dev server on loopback almost never speaks TLS —
    # upgrading would make the option useless for the one case it is for.
    def self.normalize(uri : URI, allow_private : Bool = false) : URI
      return uri if allow_private
      return uri unless uri.scheme == "http"

      upgraded = uri.dup
      upgraded.scheme = "https"
      upgraded
    end

    # Returns the reason to refuse, or nil to proceed.
    #
    # The address check happens **after** DNS resolution on purpose. Checking
    # the hostname would be theatre: a name with an A record pointing at
    # 169.254.169.254 walks straight past it, which is the classic way to read
    # cloud instance metadata through someone else's fetcher.
    def self.check(uri : URI, allow_private : Bool = false) : String?
      scheme = uri.scheme
      unless scheme && ALLOWED_SCHEMES.includes?(scheme)
        return "unsupported scheme #{scheme.inspect} — only http and https are fetched"
      end

      host = uri.host
      return "the URL has no host" if host.nil? || host.empty?

      return nil if allow_private

      addresses = begin
        Socket::Addrinfo.resolve(host, uri.port || 443, type: Socket::Type::STREAM).map(&.ip_address)
      rescue ex : Socket::Error
        return "could not resolve #{host}: #{ex.message}"
      end

      return "could not resolve #{host}" if addresses.empty?

      # Every resolved address must be acceptable. A name resolving to one
      # public and one private address is a bypass, not a convenience.
      addresses.each do |address|
        next unless blocked?(address)

        return "#{host} resolves to the private or reserved address #{address.address}; " \
               "refusing to fetch it. Set [web] allow_private = true to permit this."
      end

      nil
    end

    private def self.blocked?(address : Socket::IPAddress) : Bool
      address.loopback? || address.private? || address.link_local? || address.unspecified?
    end
  end
end
