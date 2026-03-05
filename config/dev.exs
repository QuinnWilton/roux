import Config

# Send all log output to stderr so it doesn't corrupt the LSP stdio stream.
# Override the default format to remove the leading \n that causes blank lines.
config :logger, :default_handler, config: [type: :standard_error]
config :logger, :default_formatter, format: "$time $metadata[$level] $message\n"

# Register test languages for local LSP development.
# These modules live in test/support/languages/ and are compiled
# via the :dev elixirc_paths addition in mix.exs.
config :roux,
  languages: [
    Roux.Test.HoverLang,
    Roux.Test.MiniLang,
    Roux.Test.TinyLang,
    Roux.Test.FailingLang
  ]
