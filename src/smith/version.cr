module Smith
  VERSION = "0.4.0"

  # Where this binary came from, read from the environment **at compile time**
  # and set only by .github/workflows/release.yml — a `crystal build` or
  # `make build` anywhere else leaves it "dev".
  #
  # `smith update` overwrites the running executable, so it needs to know the
  # binary really is a release artifact it can fetch a successor for. VERSION
  # cannot answer that: every build carries one, including a working tree half
  # way through a feature.
  BUILD_CHANNEL = {{ env("SMITH_BUILD_CHANNEL") || "dev" }}
end
