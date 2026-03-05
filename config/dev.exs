import Config

# Override the default log format to remove the leading \n that causes blank lines.
config :logger, :default_formatter, format: "$time $metadata[$level] $message\n"
