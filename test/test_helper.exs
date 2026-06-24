# JUnitFormatter writes JUnit XML (consumed by Codecov Test Analytics) as a side
# effect of the normal test run. Listing formatters explicitly REPLACES the
# defaults, so ExUnit.CLIFormatter must be named here to keep console output.
#
# `:external` tests shell out to real tools (skopeo/umoci/mke2fs) and touch the
# image DB + media store. They are opt-in: run with `mix test --include external`.
ExUnit.start(
  formatters: [ExUnit.CLIFormatter, JUnitFormatter],
  exclude: [:external]
)
