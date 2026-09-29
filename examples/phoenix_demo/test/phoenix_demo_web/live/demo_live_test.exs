defmodule PhoenixDemoWeb.DemoLiveTest do
  use PhoenixDemoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the home page shows the facts of the VM", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Phoenix LiveView on Cloudflare Workers"
    assert html =~ to_string(:erlang.system_info(:system_architecture))
    assert html =~ "Visitors online"
  end

  test "the page shows the country of the request from Cloudflare", %{conn: conn} do
    conn = put_req_header(conn, "cf-ipcountry", "US")
    {:ok, view, _html} = live(conn, ~p"/")
    assert view |> element("#country") |> render() =~ "US"
    assert view |> has_element?("#colo[phx-hook]")
  end

  test "a click in one view updates the counter in all views", %{conn: conn} do
    {:ok, one, _html} = live(conn, ~p"/")
    {:ok, two, _html} = live(conn, ~p"/")
    before = String.to_integer(one |> element("#clicks") |> render() |> text())

    one |> element("#click") |> render_click()

    expected = Integer.to_string(before + 1)
    assert one |> element("#clicks") |> render() |> text() == expected
    assert_eventually(fn -> two |> element("#clicks") |> render() |> text() == expected end)
  end

  test "the server clock and the visitors update without a request", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    send(view.pid, :tick)
    assert view |> element("#clock") |> render() =~ "UTC"
    {:ok, _other, _html} = live(conn, ~p"/")

    assert_eventually(fn ->
      String.to_integer(view |> element("#online") |> render() |> text()) >= 2
    end)
  end

  test "a ping gets a reply", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert render_hook(view, "ping", %{}) =~ "Server clock"
  end

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  # A poll with a ceiling of 5,000 ms and a step of 10 ms: a broadcast
  # reaches the other view a moment later.
  defp assert_eventually(fun) do
    assert Enum.any?(1..500, fn _ -> fun.() || (Process.sleep(10) && false) end)
  end
end
