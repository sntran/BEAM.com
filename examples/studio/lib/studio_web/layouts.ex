defmodule StudioWeb.Layouts do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    assigns = assign(assigns, base: Studio.Project.base())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>{assigns[:page_title] || "phx.new"}</title>
        <link rel="stylesheet" href={@base <> "/__studio/static/studio/studio.css"} />
        <script type="module" src={@base <> "/__studio/static/studio/studio.js"} data-base={@base}>
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end

defmodule StudioWeb.ErrorHTML do
  @moduledoc false
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
