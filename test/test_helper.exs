# JUnitFormatter writes JUnit XML (consumed by Codecov Test Analytics) as a side
# effect of the normal test run. Listing formatters explicitly REPLACES the
# defaults, so ExUnit.CLIFormatter must be named here to keep console output.
ExUnit.start(formatters: [ExUnit.CLIFormatter, JUnitFormatter])
