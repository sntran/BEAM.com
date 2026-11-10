import Config

# The value at the start of the program.
config :runtime_check, greeting: System.get_env("RUNTIME_CHECK_GREETING", "no variable")
