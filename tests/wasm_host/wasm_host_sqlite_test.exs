defmodule WasmHostSqliteTest do
  @moduledoc """
  The tests of `:wasm_host_sqlite`, the NIF of exqlite in the WebAssembly
  runtime: the parts that need no host.

  The named ETS table `wasm_host_sqlite` and the persistent term of the
  backend are global state, so the tests do not run async.
  """
  use ExUnit.Case, async: false

  # The process of setup_all owns the table of the connections until the
  # tests of the module end.
  setup_all do
    if :ets.info(:wasm_host_sqlite) == :undefined, do: :wasm_host_sqlite.table()
    :ok
  end

  describe "local_test_" do
    for {name, sql, expected} <- [
          {nil, "BEGIN IMMEDIATE TRANSACTION", :tx_begin},
          {nil, "SAVEPOINT exqlite_savepoint", :tx_begin},
          {nil, "RELEASE SAVEPOINT exqlite_savepoint", :tx_release},
          {nil, "ROLLBACK TO SAVEPOINT exqlite_savepoint", :tx_rollback_to},
          {nil, "ROLLBACK TRANSACTION", :tx_rollback},
          {nil, "commit;", :tx_commit},
          {nil, "PRAGMA journal_mode = WAL", {:pragma, "journal_mode", "WAL"}},
          {nil, "PRAGMA foreign_keys", {:pragma, "foreign_keys"}},
          {"a PRAGMA with an argument: the host", "PRAGMA table_info(\"notes\")", :host},
          {nil, "SELECT 1", :host}
        ] do
      test name || "local(#{inspect(sql)})" do
        assert unquote(Macro.escape(expected)) == :wasm_host_sqlite.local(unquote(sql))
      end
    end
  end

  describe "params_test_" do
    for {name, sql, expected} <- [
          {nil, "SELECT ?1, ?2 FROM t WHERE a = ?3", {3, []}},
          {nil, "INSERT INTO t VALUES (?, ?)", {2, []}},
          {"not in strings or quoted names", "SELECT '?', \"a?\", [b?], `c?`, ? -- ?\n /* ? */",
           {1, []}},
          {"a quote in a string", "SELECT 'it''s ?', ?", {1, []}},
          {"named parameters, once each", "SELECT :a, @b, :a", {2, [{":a", 1}, {"@b", 2}]}}
        ] do
      test name || "params(#{inspect(sql)})" do
        assert unquote(Macro.escape(expected)) == :wasm_host_sqlite.params(unquote(sql))
      end
    end
  end

  describe "wire_test_" do
    for {value, wire} <- [
          {{:blob, <<0, 1, 255>>}, %{b: "AAH/"}},
          {9_007_199_254_740_993, %{i: "9007199254740993"}},
          {42, 42},
          {:null, :null}
        ] do
      test "wire(#{inspect(value)})" do
        assert unquote(Macro.escape(wire)) ==
                 :wasm_host_sqlite.wire(unquote(Macro.escape(value)))
      end
    end

    for {wire, value} <- [
          {%{"b" => "AAH/"}, <<0, 1, 255>>},
          {%{"i" => "9007199254740993"}, 9_007_199_254_740_993},
          {:null, nil}
        ] do
      test "unwire(#{inspect(wire)})" do
        assert unquote(Macro.escape(value)) ==
                 :wasm_host_sqlite.unwire(unquote(Macro.escape(wire)))
      end
    end
  end

  describe "connection_test_" do
    setup do
      {:ok, c} = :wasm_host_sqlite.open(~c"db", [])
      %{conn: c}
    end

    test "a new connection is idle", %{conn: c} do
      assert {:ok, :idle} == :wasm_host_sqlite.transaction_status(c)
    end

    test "a transaction with a savepoint", %{conn: c} do
      :ok = :wasm_host_sqlite.execute(c, ~c"BEGIN TRANSACTION")
      assert {:ok, :transaction} == :wasm_host_sqlite.transaction_status(c)
      :ok = :wasm_host_sqlite.execute(c, ~c"SAVEPOINT exqlite_savepoint")
      :ok = :wasm_host_sqlite.execute(c, ~c"RELEASE SAVEPOINT exqlite_savepoint")
      assert {:ok, :transaction} == :wasm_host_sqlite.transaction_status(c)
      :ok = :wasm_host_sqlite.execute(c, ~c"COMMIT")
      assert {:ok, :idle} == :wasm_host_sqlite.transaction_status(c)
    end

    test "a PRAGMA that was set, read back as a row", %{conn: c} do
      :ok = :wasm_host_sqlite.execute(c, ~c"PRAGMA foreign_keys = ON")
      {:ok, s} = :wasm_host_sqlite.prepare(c, ~c"PRAGMA foreign_keys")
      assert {:ok, ["foreign_keys"]} == :wasm_host_sqlite.columns(c, s)
      assert {:done, [["ON"]]} == :wasm_host_sqlite.multi_step(c, s, 50)
    end

    test "binds and the parameter count", %{conn: c} do
      {:ok, s} = :wasm_host_sqlite.prepare(c, ~c"SELECT ?1, :x")
      assert 2 == :wasm_host_sqlite.bind_parameter_count(s)
      assert 2 == :wasm_host_sqlite.bind_parameter_index(s, ~c":x")
      assert 0 == :wasm_host_sqlite.bind_text(s, 1, ~c"a")
      assert 0 == :wasm_host_sqlite.bind_blob(s, 2, <<1>>)
      assert :ok == :wasm_host_sqlite.release(c, s)
    end

    test "close", %{conn: c} do
      assert :ok == :wasm_host_sqlite.close(c)
    end
  end

  # With no NIF of exqlite (a native run), the backend is this module: the
  # host runs the SQL. A function that the backend does not have is
  # not_supported.
  test "dispatch_test" do
    :persistent_term.erase(:wasm_host_sqlite)
    refute :wasm_host_exqlite.available()
    assert :wasm_host_sqlite == :wasm_host_sqlite.backend()
    # The second call gives the backend that the first call kept.
    assert :wasm_host_sqlite == :wasm_host_sqlite.backend()

    assert {:ok, false} ==
             {:ok, :wasm_host_sqlite.dispatch(:erlang_allocator_enabled, [])}

    assert :not_supported == error_of(fn -> :wasm_host_sqlite.dispatch(:made_up, [:x]) end)
  end

  # The functions of the NIF, with no NIF.
  describe "exqlite_stubs_test" do
    for {f, a} <- :wasm_host_exqlite.module_info(:exports),
        f not in [:available, :module_info] do
      test "#{f}/#{a}" do
        args = List.duplicate(:x, unquote(a))

        assert :not_loaded ==
                 error_of(fn -> apply(:wasm_host_exqlite, unquote(f), args) end)
      end
    end
  end

  # The reason of an Erlang error, as erlang:error/1 gave it.
  defp error_of(fun) do
    fun.()
    flunk("no error")
  catch
    :error, reason -> reason
  end
end
