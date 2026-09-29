defmodule PhoenixDemo.CountersTest do
  use PhoenixDemo.DataCase, async: true

  alias PhoenixDemo.Counters

  test "a new counter is 0, and each increment adds 1" do
    assert Counters.get("test") == 0
    assert Counters.increment("test") == 1
    assert Counters.increment("test") == 2
    assert Counters.get("test") == 2
    assert Counters.get("other") == 0
  end
end
