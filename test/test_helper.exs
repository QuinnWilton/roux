# Spawned processes in async tests can wait well past ExUnit's 100 ms default
# while the whole suite runs; the timeout only costs time when a test fails.
ExUnit.start(assert_receive_timeout: 5_000)
