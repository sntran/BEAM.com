defmodule Studio.AssetsTest do
  @moduledoc """
  The tests of the import rewrite of `Studio.Assets`: the browser loads the
  JavaScript of a project as ES modules, with no esbuild.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @base "/t/abc"

  test "the imports of the app.js of phx.new" do
    text = """
    import "phoenix_html"
    import {Socket} from "phoenix"
    import {hooks as colocatedHooks} from "phoenix-colocated/hello"
    import topbar from "../vendor/topbar"
    import confetti from "canvas-confetti"
    const liveSocket = new LiveSocket("/live", Socket, {})
    """

    out = Studio.Assets.transform(text, "js/app.js", @base)
    assert out =~ ~s(import "/t/abc/__studio/pkg/phoenix_html.js")
    assert out =~ ~s(from "/t/abc/__studio/pkg/phoenix.js")
    assert out =~ ~s(from "/t/abc/__studio/colocated/hello/index.js")
    assert out =~ ~s(from "/t/abc/__studio/js/vendor/topbar")
    assert out =~ ~s(from "https://cdn.jsdelivr.net/npm/canvas-confetti/+esm")
    assert out =~ ~s(new LiveSocket("/t/abc" + "/live")
  end

  test "a file with no import or export is a CommonJS module" do
    out = Studio.Assets.transform("module.exports = 1;\n", "vendor/topbar.js", @base)
    assert out =~ "export default module.exports;"
    assert out =~ "module.exports = 1;"
  end

  # A relative import names a file of assets/. Each "../" stops at the
  # root of assets/, so the address never leaves /__studio/js/.
  property "a relative import stays in the files of assets/" do
    check all(
            rel <- path(min_length: 1),
            ups <- integer(0..4),
            down <- path(min_length: 1),
            quote <- member_of([~s("), "'"])
          ) do
      spec = String.duplicate("../", ups) <> down
      spec = if ups == 0, do: "./" <> spec, else: spec
      text = "import x from #{quote}#{spec}#{quote};\n"
      out = Studio.Assets.transform(text, rel <> ".js", @base)

      assert [_, target] =
               Regex.run(
                 ~r/from #{quote}#{Regex.escape(@base)}\/__studio\/js\/([^"']*)#{quote}/,
                 out
               )

      refute ".." in Path.split(target)
      refute String.starts_with?(target, "/")
      assert String.ends_with?(target, down)
    end
  end

  # The rewrite changes only the text of an import: each other line stays.
  # The rewrite uses a regular expression, not a parser of JavaScript, so
  # it also changes an import in a comment or a string. A comment has no
  # effect, and the app.js of a project has no such string.
  property "the text out of the imports does not change" do
    check all(
            lines <-
              list_of(member_of(["let a = 1;", "// a comment", "f(\"z\");", "x.from = y;", ""]),
                max_length: 5
              ),
            name <- member_of(["phoenix", "lodash", "./a"])
          ) do
      text = Enum.join(["import v from \"#{name}\";" | lines], "\n")
      out = Studio.Assets.transform(text, "js/app.js", @base)
      [_ | rest] = String.split(out, "\n")
      assert rest == lines
    end
  end

  defp path(opts) do
    map(list_of(member_of(["a", "b", "js", "vendor", "x.y"]), opts), &Enum.join(&1, "/"))
  end
end
