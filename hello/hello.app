{application, hello,
 [{description, "Hello world for BEAM.com"},
  {vsn, "0.1.0"},
  {modules, [hello, hello_app]},
  {registered, []},
  {applications, [kernel, stdlib]},
  {env, [{greeting, "Hello from the app env"}]},
  {mod, {hello_app, []}}]}.
