defmodule Notes.Router do
  use Plug.Router
  import Ecto.Query
  alias Notes.{Note, Repo}

  plug :match
  plug :dispatch

  # A note for each request, and the count.
  get "/" do
    note = Repo.insert!(%Note{text: "hello #{conn.request_path}", data: <<0, 1, 2, 255>>})
    count = Repo.aggregate(Note, :count)
    send_resp(conn, 200, "note #{note.id}: #{count} notes\n")
  end

  # The last notes, as JSON (a binary field too).
  get "/notes" do
    notes =
      Repo.all(from n in Note, order_by: [desc: n.id], limit: 5, select: %{id: n.id, text: n.text, data: n.data})
      |> Enum.map(&%{&1 | data: &1.data && Base.encode16(&1.data)})

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(notes))
  end

  # A transaction (each statement commits alone on the host).
  get "/tx" do
    {:ok, n} = Repo.transaction(fn -> Repo.insert!(%Note{text: "in a transaction"}).id end)
    send_resp(conn, 200, "note #{n} in a transaction\n")
  end

  match _ do
    send_resp(conn, 404, "not found\n")
  end
end
