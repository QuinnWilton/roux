import Config

config :logger, level: :warning

# The buffer's reader calls System.stop/0 when the client socket closes.
# Under ExUnit that socket closes on every test's cleanup, which would
# take the VM (and ExUnit's own tables) down mid-run.
config :gen_lsp, exit_on_end: false
