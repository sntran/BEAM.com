defmodule PhoenixDemoWeb.DemoLiveHostTest do
  # BEAM_HOST and BEAM_REGION are variables of the OS process: no other test
  # may run at the same time.
  use PhoenixDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    on_exit(fn ->
      System.delete_env("BEAM_HOST")
      System.delete_env("BEAM_REGION")
    end)
  end

  test "on Deno Deploy, the page names Deno Deploy and its region", %{conn: conn} do
    System.put_env("BEAM_HOST", "deno-deploy")
    System.put_env("BEAM_REGION", "us-east4")
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Phoenix LiveView on Deno Deploy"
    assert html =~ "Deno Deploy region"
    refute html =~ "Cloudflare"
    assert view |> element("#colo[data-region=us-east4]") |> render() =~ "us-east4"
  end

  test "on Cloudflare Workers, the page names Cloudflare and asks for its data center",
       %{conn: conn} do
    System.put_env("BEAM_HOST", "cloudflare")
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Phoenix LiveView on Cloudflare Workers"
    assert html =~ "Cloudflare data center"
    assert view |> has_element?("#colo[phx-hook]")
    refute view |> has_element?("#colo[data-region]")
  end

  test "an unknown host is as a native VM", %{conn: conn} do
    System.put_env("BEAM_HOST", "somewhere")
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Phoenix LiveView on this server"
  end
end
