defmodule BeamComZipTest do
  @moduledoc """
  The tests of `:beam_com_zip`, the zip writer for APE files.

  The oracle is independent code. The `zip` module of stdlib must read each
  file that the writer makes, with the offsets from the start of the file,
  as in an APE file. The data must be the same. Info-ZIP `unzip` also reads
  the file, when it is installed.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @end_record 0x06054B50

  # A fake executable: some bytes, then an empty zip whose offsets count
  # from the start of the file.
  defp exe(prefix) do
    size = byte_size(prefix)

    <<prefix::binary, @end_record::32-little, 0::16, 0::16, 0::16, 0::16, 0::32, size::32-little,
      0::16>>
  end

  # Not a multiple of 4, and with "PK" bytes in it.
  defp prefix do
    <<"MZqFpD='\n", :binary.copy(<<"PK", 1, 2, " image ">>, 50)::binary, 7>>
  end

  defp write(bin, keep, new) do
    IO.iodata_to_binary(:beam_com_zip.write(bin, keep, new))
  end

  defp all(_), do: true

  defp only(bin, keep), do: IO.iodata_to_binary(:beam_com_zip.only(bin, keep))

  # The files of the zip, as stdlib reads them (without the directory
  # entries).
  defp files(bin) do
    {:ok, files} = :zip.unzip(bin, [:memory])
    files |> Enum.filter(fn {name, _} -> List.last(name) != ?/ end) |> Enum.sort()
  end

  defp names(bin), do: Enum.sort(:beam_com_zip.entries(bin))

  defp sample do
    [
      {~c"a.txt", "hello"},
      {~c"dir/", ""},
      {~c"dir/b.bin", crypto_free_random(1000)},
      {~c"dir/c.txt", :binary.copy("compress me ", 200)}
    ]
  end

  # Random bytes that do not compress, the same on each run (and with no
  # crypto NIF).
  defp crypto_free_random(n) do
    {bytes, _} = :rand.bytes_s(n, :rand.seed_s(:exsss, {1, 2, 3}))
    bytes
  end

  test "new_entries_test" do
    out = write(exe(prefix()), &all/1, sample())
    assert prefix() == binary_part(out, 0, byte_size(prefix()))
    assert [~c"a.txt", ~c"dir/", ~c"dir/b.bin", ~c"dir/c.txt"] == names(out)

    assert [
             {~c"a.txt", "hello"},
             {~c"dir/b.bin", crypto_free_random(1000)},
             {~c"dir/c.txt", :binary.copy("compress me ", 200)}
           ] == files(out)
  end

  test "entries_order_test" do
    out = write(exe(prefix()), &all/1, sample())
    assert [~c"a.txt", ~c"dir/", ~c"dir/b.bin", ~c"dir/c.txt"] == :beam_com_zip.entries(out)
  end

  test "deterministic_test" do
    a = write(exe(prefix()), &all/1, sample())
    b = write(exe(prefix()), &all/1, sample())
    assert a == b
  end

  test "stored_or_deflated_test" do
    random = crypto_free_random(1000)
    text = :binary.copy("compress me ", 200)
    out = write(exe(prefix()), &all/1, [{~c"random", random}, {~c"text", text}])
    methods = Map.new(central(out), fn {n, m, _} -> {n, m} end)
    assert 0 == Map.fetch!(methods, ~c"random")
    assert 8 == Map.fetch!(methods, ~c"text")
    assert byte_size(out) < byte_size(exe(prefix())) + 1000 + 2400
  end

  # The code of kernel and stdlib is stored (the boot reads it without
  # inflation). Other code becomes a gzip file, which is stored.
  test "kernel_stdlib_stored_test" do
    text = :binary.copy("compress me ", 200)

    out =
      write(exe(prefix()), &all/1, [
        {~c"lib/kernel-11.0/ebin/code.beam", text},
        {~c"lib/stdlib-8.1/ebin/lists.beam", text},
        {~c"lib/stdlib-8.1/include/x.hrl", text},
        {~c"lib/other-1.0/ebin/o.beam", text}
      ])

    methods = Map.new(central(out), fn {n, m, _} -> {n, m} end)
    assert 0 == Map.fetch!(methods, ~c"lib/kernel-11.0/ebin/code.beam")
    assert 0 == Map.fetch!(methods, ~c"lib/stdlib-8.1/ebin/lists.beam")
    assert 8 == Map.fetch!(methods, ~c"lib/stdlib-8.1/include/x.hrl")
    assert 0 == Map.fetch!(methods, ~c"lib/other-1.0/ebin/o.beam")
    assert text == :proplists.get_value(~c"lib/kernel-11.0/ebin/code.beam", files(out))
    assert text == :zlib.gunzip(:proplists.get_value(~c"lib/other-1.0/ebin/o.beam", files(out)))
  end

  # A gzip file is stored, also when deflate makes it smaller. A .beam file
  # that is not a gzip file becomes one: so each .beam entry is stored, and
  # the WebAssembly runtime uses its bytes with no copy.
  test "gzip_stored_test" do
    code = :binary.copy("FOR1 the code ", 200)
    # A gzip file with no compression (level 0): deflate makes it smaller.
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :none, :deflated, 31, 8, :default)
    level0 = IO.iodata_to_binary(:zlib.deflate(z, code, :finish))
    :zlib.close(z)
    assert <<0x1F, 0x8B, _::binary>> = level0
    assert byte_size(:zlib.zip(level0)) < byte_size(level0)

    out =
      write(exe(prefix()), &all/1, [
        {~c"lib/a-1.0/ebin/gz.beam", :zlib.gzip(code)},
        {~c"lib/a-1.0/ebin/level0.beam", level0},
        {~c"lib/a-1.0/ebin/plain.beam", code}
      ])

    methods = Map.new(central(out), fn {n, m, _} -> {n, m} end)
    assert 0 == Map.fetch!(methods, ~c"lib/a-1.0/ebin/gz.beam")
    assert 0 == Map.fetch!(methods, ~c"lib/a-1.0/ebin/level0.beam")
    assert 0 == Map.fetch!(methods, ~c"lib/a-1.0/ebin/plain.beam")
    assert level0 == :proplists.get_value(~c"lib/a-1.0/ebin/level0.beam", files(out))
    assert :zlib.gzip(code) == :proplists.get_value(~c"lib/a-1.0/ebin/plain.beam", files(out))
  end

  test "directory_attributes_test" do
    out = write(exe(prefix()), &all/1, [{~c"d/", ""}, {~c"f", "x"}])
    attrs = Map.new(central(out), fn {n, _, a} -> {n, a} end)
    assert 0o40755 == Bitwise.bsr(Map.fetch!(attrs, ~c"d/"), 16)
    assert 0x10 == Bitwise.band(Map.fetch!(attrs, ~c"d/"), 0x10)
    assert 0o100644 == Bitwise.bsr(Map.fetch!(attrs, ~c"f"), 16)
  end

  test "utf8_name_test" do
    name = ~c"lib/café/日.txt"
    out = write(exe(prefix()), &all/1, [{name, "x"}, {~c"ascii", "y"}])
    flags = Map.new(flags(out))
    assert 0x800 == Bitwise.band(Map.fetch!(flags, :unicode.characters_to_binary(name)), 0x800)
    assert 0 == Bitwise.band(Map.fetch!(flags, "ascii"), 0x800)
  end

  test "empty_file_test" do
    out = write(exe(prefix()), &all/1, [{~c"empty", ""}])
    assert [{~c"empty", ""}] == files(out)
  end

  test "iodata_test" do
    out = write(exe(prefix()), &all/1, [{~c"io", ["a", ~c"b", [?c]]}])
    assert [{~c"io", "abc"}] == files(out)
  end

  test "keep_all_test" do
    base = write(exe(prefix()), &all/1, sample())
    out = write(base, &all/1, [])
    assert files(base) == files(out)
    # Nothing moves: the entries and the data before the central directory
    # are the same bytes.
    cd_offset = cd_offset(base)
    assert binary_part(base, 0, cd_offset) == binary_part(out, 0, cd_offset)
  end

  test "remove_test" do
    base = write(exe(prefix()), &all/1, sample())
    out = write(base, fn n -> n != ~c"a.txt" end, [])
    assert [~c"dir/", ~c"dir/b.bin", ~c"dir/c.txt"] == names(out)
    assert tl(files(base)) == files(out)
    assert byte_size(out) < byte_size(base)
  end

  test "remove_all_test" do
    base = write(exe(prefix()), &all/1, sample())
    out = write(base, fn _ -> false end, [])
    assert [] == :beam_com_zip.entries(out)
    assert exe(prefix()) == out
  end

  test "replace_test" do
    base = write(exe(prefix()), &all/1, sample())
    out = write(base, &all/1, [{~c"dir/c.txt", "new"}])
    assert [~c"a.txt", ~c"dir/", ~c"dir/b.bin", ~c"dir/c.txt"] == names(out)
    assert "new" == :proplists.get_value(~c"dir/c.txt", files(out))
    assert "hello" == :proplists.get_value(~c"a.txt", files(out))
  end

  # The entries before the first removed entry stay at the same offsets
  # (the zip entries of the emulator image), and the entries after it move.
  test "in_place_and_moved_test" do
    base =
      write(exe(prefix()), &all/1, [
        {~c"image1", "first"},
        {~c"image2", "second"},
        {~c"old", "remove me"},
        {~c"after", "moved"}
      ])

    out = write(base, fn n -> n != ~c"old" end, [{~c"new", "added"}])
    offsets0 = Map.new(offsets(base))
    offsets1 = Map.new(offsets(out))
    assert Map.fetch!(offsets0, "image1") == Map.fetch!(offsets1, "image1")
    assert Map.fetch!(offsets0, "image2") == Map.fetch!(offsets1, "image2")
    assert Map.fetch!(offsets0, "old") == Map.fetch!(offsets1, "after")

    assert [
             {~c"after", "moved"},
             {~c"image1", "first"},
             {~c"image2", "second"},
             {~c"new", "added"}
           ] == files(out)
  end

  # A file made from a file of the writer (a build with -o on a program
  # that a build with -o made).
  test "chain_test" do
    a = write(exe(prefix()), &all/1, sample())
    b = write(a, fn n -> n != ~c"dir/b.bin" end, [{~c"x", "1"}])
    c = write(b, fn n -> n != ~c"a.txt" end, [{~c"y", "2"}])

    assert [
             {~c"dir/c.txt", :binary.copy("compress me ", 200)},
             {~c"x", "1"},
             {~c"y", "2"}
           ] == files(c)
  end

  # A zip that another tool (stdlib) made, after a prefix, with absolute
  # offsets: the writer keeps and moves its entries.
  test "foreign_zip_test" do
    {:ok, {_, zip}} = :zip.create(~c"z.zip", [{~c"one", "1"}, {~c"two", "22"}], [:memory])
    base = relocate(prefix(), zip)
    assert [{~c"one", "1"}, {~c"two", "22"}] == files(base)
    out = write(base, fn n -> n != ~c"one" end, [{~c"three", "333"}])
    assert [{~c"three", "333"}, {~c"two", "22"}] == files(out)
  end

  # The writer moves an entry with a data descriptor (flag bit 3) together
  # with the descriptor, with and without its signature.
  describe "data_descriptor_test_" do
    for {name, signature} <- [{"with signature", true}, {"without signature", false}] do
      test name do
        data_descriptor(unquote(signature))
      end
    end
  end

  defp data_descriptor(signature) do
    base =
      descriptor_zip(prefix(), signature, [
        {~c"first", "remove"},
        {~c"second", "keep me"},
        {~c"third", "and me"}
      ])

    assert [{~c"first", "remove"}, {~c"second", "keep me"}, {~c"third", "and me"}] ==
             files(base)

    out = write(base, fn n -> n != ~c"first" end, [{~c"new", "n"}])

    assert [{~c"new", "n"}, {~c"second", "keep me"}, {~c"third", "and me"}] ==
             files(out)

    # only/2 moves an entry with its descriptor too.
    assert [{~c"second", "keep me"}, {~c"third", "and me"}] ==
             files(only(base, fn n -> n != ~c"first" end))
  end

  # only/2: the kept entries in a zip of their own, with no bytes of the
  # executable before them, and with offsets from the start of the new
  # file (the edge part of --target wasm32 with -o FILE.com).
  test "only_test" do
    base = write(exe(prefix()), &all/1, sample())
    out = only(base, &:lists.prefix(~c"dir/", &1))
    assert <<0x04034B50::32-little, _::binary>> = out
    assert names(out) == [~c"dir/", ~c"dir/b.bin", ~c"dir/c.txt"]
    assert files(out) == Enum.filter(files(base), fn {n, _} -> :lists.prefix(~c"dir/", n) end)
    assert 0 == Enum.min(for {_, offset} <- offsets(out), do: offset)
  end

  test "only_none_test" do
    out = only(write(exe(prefix()), &all/1, sample()), fn _ -> false end)
    assert 22 == byte_size(out)
    assert [] == :beam_com_zip.entries(out)
  end

  test "comment_test" do
    exe = exe(prefix())
    # A zip comment: the end record is not the last 22 bytes.
    head_size = byte_size(exe) - 2
    <<head::binary-size(^head_size), _::16>> = exe
    with_comment = <<head::binary, 5::16-little, "hello">>
    out = write(with_comment, &all/1, [{~c"a", "b"}])
    assert [{~c"a", "b"}] == files(out)
  end

  # A comment with the bytes of an end record: the last record whose
  # comment length matches is the real record.
  test "comment_with_signature_test" do
    exe = exe(prefix())
    head_size = byte_size(exe) - 2
    <<head::binary-size(^head_size), _::16>> = exe
    fake = <<@end_record::32-little, 0::size(18 * 8)>>
    with_comment = <<head::binary, byte_size(fake)::16-little, fake::binary>>
    out = write(with_comment, &all/1, [{~c"a", "b"}])
    assert [{~c"a", "b"}] == files(out)
    assert prefix() == binary_part(out, 0, byte_size(prefix()))
  end

  # The central directory does not end at the record: not a zip.
  test "bad_end_record_test" do
    bad = <<"exe", @end_record::32-little, 0::16, 0::16, 0::16, 0::16, 0::32, 0::32, 0::16>>
    assert :no_zip == error_of(fn -> :beam_com_zip.entries(bad) end)
  end

  test "zip64_offset_test" do
    zip64 =
      <<"exe", @end_record::32-little, 0::16, 0::16, 1::16, 1::16, 0::32, 0xFFFFFFFF::32, 0::16>>

    assert :zip64_not_supported == error_of(fn -> :beam_com_zip.entries(zip64) end)
  end

  test "no_zip_test" do
    assert :no_zip == error_of(fn -> :beam_com_zip.entries("just an executable") end)
    assert :no_zip == error_of(fn -> :beam_com_zip.write("", &all/1, []) end)
  end

  test "zip64_test" do
    zip64 =
      <<"exe", @end_record::32-little, 0::16, 0::16, 0xFFFF::16, 0xFFFF::16, 0::32,
        0xFFFFFFFF::32, 0::16>>

    assert :zip64_not_supported == error_of(fn -> :beam_com_zip.entries(zip64) end)
  end

  # The real check of the APE layout: Info-ZIP unzip reads the file, when
  # it is installed. Without unzip, the test does no check.
  @tag :tmp_dir
  test "unzip_test", %{tmp_dir: dir} do
    if unzip = System.find_executable("unzip") do
      file = Path.join(dir, "beam_com_zip_test.com")
      out = write(exe(prefix()), &all/1, sample())
      File.write!(file, out)
      {result, _} = System.cmd(unzip, ["-tq", file], stderr_to_stdout: true)
      File.rm!(file)
      assert String.starts_with?(result, "No errors detected"), result
    end
  end

  # The helpers below read the central directory without the writer.

  defp central(bin) do
    for {name, method, eattr, _offset, _flags} <- cd_entries(bin),
        do: {:binary.bin_to_list(name), method, eattr}
  end

  defp flags(bin) do
    for {name, _, _, _, flags} <- cd_entries(bin), do: {name, flags}
  end

  defp offsets(bin) do
    for {name, _, _, offset, _} <- cd_entries(bin), do: {name, offset}
  end

  defp cd_offset(bin) do
    pos = byte_size(bin) - 22

    <<@end_record::32-little, _::binary-size(12), cd_offset::32-little, _::16>> =
      binary_part(bin, pos, 22)

    cd_offset
  end

  defp cd_entries(bin) do
    pos = byte_size(bin) - 22

    <<@end_record::32-little, _::binary-size(6), count::16-little, cd_size::32-little,
      cd_offset::32-little, _::16>> = binary_part(bin, pos, 22)

    parse(binary_part(bin, cd_offset, cd_size), count)
  end

  defp parse(_, 0), do: []

  defp parse(
         <<0x02014B50::32-little, _::binary-size(4), flags::16-little, method::16-little,
           _::binary-size(16), n::16-little, m::16-little, k::16-little, _::binary-size(4),
           eattr::32-little, offset::32-little, name::binary-size(n), _::binary-size(m),
           _::binary-size(k), rest::binary>>,
         count
       ) do
    [{name, method, eattr, offset, flags} | parse(rest, count - 1)]
  end

  # Put a zip (offsets from its start) after the prefix, with offsets from
  # the start of the result.
  defp relocate(prefix, zip) do
    p = byte_size(prefix)
    size = byte_size(zip)

    <<@end_record::32-little, _::binary-size(6), count::16-little, cd_size::32-little,
      cd_offset::32-little, clen::16-little>> = binary_part(zip, size - 22, 22)

    0 = clen
    cd = binary_part(zip, cd_offset, cd_size)
    new_cd = shift(cd, count, p)

    <<prefix::binary, binary_part(zip, 0, cd_offset)::binary, new_cd::binary,
      @end_record::32-little, 0::16, 0::16, count::16-little, count::16-little,
      cd_size::32-little, cd_offset + p::32-little, 0::16>>
  end

  defp shift(_, 0, _), do: <<>>

  defp shift(<<head::binary-size(42), offset::32-little, rest0::binary>>, count, p) do
    <<_::binary-size(28), n::16-little, m::16-little, k::16-little, _::binary>> = head
    len = n + m + k
    <<tail::binary-size(^len), rest::binary>> = rest0

    <<head::binary, offset + p::32-little, tail::binary, shift(rest, count - 1, p)::binary>>
  end

  # A zip of stored entries with data descriptors (as a stream writer makes
  # them), after the prefix.
  defp descriptor_zip(prefix, signature, files) do
    {locals, cds, _} =
      Enum.reduce(files, {<<>>, <<>>, byte_size(prefix)}, fn {name, data}, {l, c, pos} ->
        crc = :erlang.crc32(data)
        size = byte_size(data)
        n = length(name)
        bin_name = :erlang.list_to_binary(name)

        local =
          <<0x04034B50::32-little, 20::16-little, 8::16-little, 0::16, 0::16, 33::16-little,
            0::32, 0::32, 0::32, n::16-little, 0::16, bin_name::binary, data::binary>>

        desc =
          if signature do
            <<0x08074B50::32-little, crc::32-little, size::32-little, size::32-little>>
          else
            <<crc::32-little, size::32-little, size::32-little>>
          end

        cd =
          <<0x02014B50::32-little, 20::16-little, 20::16-little, 8::16-little, 0::16, 0::16,
            33::16-little, crc::32-little, size::32-little, size::32-little, n::16-little, 0::16,
            0::16, 0::16, 0::16, 0::32, pos::32-little, bin_name::binary>>

        record = <<local::binary, desc::binary>>
        {<<l::binary, record::binary>>, <<c::binary, cd::binary>>, pos + byte_size(record)}
      end)

    count = length(files)

    <<prefix::binary, locals::binary, cds::binary, @end_record::32-little, 0::16, 0::16,
      count::16-little, count::16-little, byte_size(cds)::32-little,
      byte_size(prefix) + byte_size(locals)::32-little, 0::16>>
  end

  # The reason of an Erlang error, as erlang:error/1 gave it.
  defp error_of(fun) do
    fun.()
    flunk("no error")
  catch
    :error, reason -> reason
  end

  # The properties of the writer. The oracle is the zip module of stdlib.
  describe "properties of the writer" do
    property "stdlib reads each entry that write/3 writes" do
      check all(prefix <- binary(), new <- entries()) do
        out = write(exe(prefix), &all/1, new)
        assert binary_part(out, 0, byte_size(prefix)) == prefix
        assert names(out) == Enum.sort(for {name, _} <- new, do: name)

        assert files(out) ==
                 Enum.sort(for {name, data} <- new, List.last(name) != ?/, do: {name, data})
      end
    end

    property "a second write keeps, removes and replaces entries" do
      check all(
              first <- entries(),
              mask <- list_of(boolean(), length: length(first)),
              second <- entries()
            ) do
        kept = for {{name, _}, true} <- Enum.zip(first, mask), do: name
        out = write(exe(prefix()), &all/1, first)
        second_names = names_of(second)
        out = write(out, &(&1 in kept), second)

        expected =
          Enum.filter(first, fn {name, _} -> name in kept and name not in second_names end) ++
            second

        assert names(out) == Enum.sort(names_of(expected))

        assert files(out) ==
                 Enum.sort(for {name, data} <- expected, List.last(name) != ?/, do: {name, data})
      end
    end
  end

  describe "properties of only/2" do
    property "only/2 gives the kept entries, with no prefix" do
      check all(
              prefix <- binary(),
              first <- entries(),
              mask <- list_of(boolean(), length: length(first))
            ) do
        kept = for {{name, _}, true} <- Enum.zip(first, mask), do: name
        out = only(write(exe(prefix), &all/1, first), &(&1 in kept))
        assert names(out) == Enum.sort(kept)

        assert files(out) ==
                 Enum.sort(
                   for {name, data} <- first,
                       name in kept,
                       List.last(name) != ?/,
                       do: {name, data}
                 )
      end
    end
  end

  # Entries with distinct names: files with data that compresses or not,
  # and directories (a name that ends with "/").
  defp entries do
    file =
      tuple(
        {map(
           list_of(member_of(["a", "b", "dir", "x.txt"]), min_length: 1, max_length: 3),
           &path/1
         ), one_of([binary(), map(binary(max_length: 8), &:binary.copy(&1, 50))])}
      )

    directory =
      map(list_of(member_of(["a", "b", "dir"]), min_length: 1, max_length: 2), fn parts ->
        {path(parts) ++ ~c"/", ""}
      end)

    map(
      uniq_list_of(one_of([file, directory]), uniq_fun: &elem(&1, 0), max_length: 6),
      fn entries ->
        # A name is a file or a directory, not both.
        dirs = for {name, ""} <- entries, List.last(name) == ?/, do: Enum.drop(name, -1)
        Enum.reject(entries, fn {name, _} -> name in dirs end)
      end
    )
  end

  defp path(parts), do: String.to_charlist(Enum.join(parts, "/"))
  defp names_of(entries), do: for({name, _} <- entries, do: name)
end
