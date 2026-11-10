defmodule BeamCom.GitFixture do
  @moduledoc """
  A git repository in memory for the tests of the git client
  (`:beam_com_git`): the pack of one commit of some files, and a function
  that answers as a server of git (version 2 over HTTP) for it.
  """

  @doc """
  The pack of one commit of `files` (`[{"path/of/file", data}]`), and
  the name of the commit: `{pack, commit}`.
  """
  def repo(files) do
    {root, objects} = tree(files)
    commit = "tree #{root}\nauthor A <a@b> 0 +0000\n\nmessage\n"
    objects = objects ++ [{1, commit}]
    {pack(objects), name(:commit, commit)}
  end

  @doc """
  A function of requests (`http` of `:beam_com_git`) for the repository
  `{pack, commit}`. Each ref of `refs` (for example `refs/tags/v1`) names
  the commit.
  """
  def server({pack, commit}, refs) do
    fn
      :get, _url, _headers, :none, _max ->
        IO.iodata_to_binary([
          pkt("# service=git-upload-pack\n"),
          "0000",
          pkt("version 2\n"),
          "0000"
        ])

      :post, _url, _headers, {_type, body}, _max ->
        if body =~ "command=ls-refs" do
          IO.iodata_to_binary([for(r <- refs, do: pkt("#{commit} #{r}\n")), "0000"])
        else
          IO.iodata_to_binary([pkt("packfile\n"), pkt(<<1>> <> pack), "0000"])
        end
    end
  end

  @doc """
  The program git_sha1dc, the SHA-1 check of the git client:
  `BEAM_COM_SHA1DC` (a build of `c_src/cosmo/beam_com_sha1dc.c` with
  `BEAM_COM_SHA1DC_MAIN`), else the helper of the `beam.com` of the tests
  when the file has one, else nil. `tests/test_helper.exs` excludes the
  tag `:sha1dc` when it is nil.
  """
  def sha1dc do
    case System.get_env("BEAM_COM_SHA1DC") do
      nil ->
        with {:ok, [[exe]]} <- :init.get_argument(:beam_com_exe),
             {:ok, bin} <- File.read(exe),
             {_, _} <- :binary.match(bin, "usage: git_sha1dc") do
          ~c"/zip/bin/git_sha1dc"
        else
          _ -> nil
        end

      path ->
        String.to_charlist(path)
    end
  end

  @doc """
  The test vectors of `tests/programs/sha1dc_vectors.txt`: `[{name,
  bytes}]`. Each pair of vectors is a SHA-1 collision.
  """
  def sha1dc_vectors do
    for line <-
          File.read!(Path.expand("../programs/sha1dc_vectors.txt", __DIR__))
          |> String.split("\n", trim: true),
        not String.starts_with?(line, "#") do
      [name, hex] = String.split(line, " ")
      {name, Base.decode16!(hex, case: :lower)}
    end
  end

  @doc "The name of a git object: the SHA-1 of its type, size and data."
  def name(type, data) do
    :crypto.hash(:sha, [to_string(type), " ", Integer.to_string(byte_size(data)), 0, data])
    |> Base.encode16(case: :lower)
  end

  # The tree of the files: its name, and the objects (blobs and trees).
  defp tree(files) do
    {here, deeper} = Enum.split_with(files, fn {p, _} -> not String.contains?(p, "/") end)

    dirs =
      deeper
      |> Enum.group_by(fn {p, _} -> hd(String.split(p, "/", parts: 2)) end, fn {p, d} ->
        {List.last(String.split(p, "/", parts: 2)), d}
      end)
      |> Enum.map(fn {dir, sub} ->
        {sha, objects} = tree(sub)
        {{"40000", dir, sha}, objects}
      end)

    entries =
      Enum.sort_by(
        for({p, d} <- here, do: {"100644", p, name(:blob, d)}) ++ for({e, _} <- dirs, do: e),
        fn {_, n, _} -> n end
      )

    data =
      for {mode, n, sha} <- entries,
          into: "",
          do: mode <> " " <> n <> <<0>> <> Base.decode16!(sha, case: :lower)

    objects = for({_, d} <- here, do: {3, d}) ++ Enum.flat_map(dirs, &elem(&1, 1)) ++ [{2, data}]
    {name(:tree, data), objects}
  end

  defp pack(objects) do
    body =
      Enum.reduce(objects, "PACK" <> <<2::32, length(objects)::32>>, fn {type, data}, acc ->
        acc <> header(type, byte_size(data)) <> :zlib.compress(data)
      end)

    body <> :crypto.hash(:sha, body)
  end

  defp header(type, size) do
    first = Bitwise.bor(Bitwise.bsl(type, 4), Bitwise.band(size, 15))
    rest = Bitwise.bsr(size, 4)
    if rest == 0, do: <<first>>, else: <<Bitwise.bor(first, 0x80)>> <> more(rest)
  end

  defp more(n) when n < 128, do: <<n>>
  defp more(n), do: <<Bitwise.bor(Bitwise.band(n, 127), 0x80)>> <> more(Bitwise.bsr(n, 7))

  defp pkt(data), do: :beam_com_git.pkt(data)
end
