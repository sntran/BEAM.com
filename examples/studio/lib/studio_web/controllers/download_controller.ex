defmodule StudioWeb.DownloadController do
  @moduledoc "The project as a zip file, with no build files and no database."
  use Phoenix.Controller, formats: [:html]

  def show(conn, _params) do
    case Studio.Project.dir() do
      nil ->
        send_resp(conn, 404, "No project.")

      dir ->
        name = Path.basename(dir)

        files =
          for f <- Studio.Project.files(), do: {~c"#{name}/#{f}", File.read!(Path.join(dir, f))}

        {:ok, {_, zip}} = :zip.create(~c"#{name}.zip", files, [:memory])

        conn
        |> put_resp_content_type("application/zip")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}.zip"))
        |> send_resp(200, zip)
    end
  end
end
