%% erl -eval of run.sh: render /counter inside the VM (Plug.Test), and print
%% the boot time and memory.
T0 = erlang:monotonic_time(millisecond),
Conn = 'Elixir.HelloWeb.Endpoint':call('Elixir.Plug.Test':conn(get, <<"https://localhost/counter">>), []),
T1 = erlang:monotonic_time(millisecond),
#{status := St, resp_body := B} = Conn,
{match, [H1]} = re:run(B, "<h1>[^<]*</h1>", [{capture, first, binary}]),
io:format("status ~p, ~p bytes, ~p ms: ~s~n", [St, byte_size(B), T1 - T0, H1]),
io:format("uptime ~p ms, memory ~p MB, processes ~p~n",
          [element(1, erlang:statistics(wall_clock)), erlang:memory(total) div 1048576,
           erlang:system_info(process_count)]),
halt().
