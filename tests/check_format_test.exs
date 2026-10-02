defmodule BeamCom.CheckFormatTest do
  @moduledoc """
  The tests of tests/check_format.sh: a built beam.com passes, and each
  of four broken copies fails with the correct message. The tests make
  sure that the checks stay live when the output of a tool changes.

  The tests need BEAM_COM_FORMAT_FILE (a built beam.com), COSMOCC (the
  directory of cosmocc), GNU binutils, unzip, and llvm-objdump. Without
  BEAM_COM_FORMAT_FILE, ExUnit skips them (the tag check_format).
  `make unit` sets the two variables when the build has the files.
  """
  use ExUnit.Case, async: true

  @moduletag :check_format
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  @script Path.join(__DIR__, "check_format.sh")

  test "a built file passes, and each broken copy fails", %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    data = File.read!(System.fetch_env!("BEAM_COM_FORMAT_FILE"))
    copies = Path.join(dir, "copies")

    good = write(dir, "good.com", data)
    {out, status} = check(good, copies)
    assert status == 0, out

    for part <- ["zip", "pe", "elf x86_64", "elf aarch64", "macho x86_64"],
        do: assert(out =~ "ok   #{good}: #{part}")

    # The ELF program headers of x86_64 are in the file, at e_phoff of the
    # ELF copy of assimilate.
    elf = File.read!(Path.join(copies, "good.com.x86_64.elf"))

    broken = [
      {"zip.com", binary_part(data, 0, byte_size(data) - 22), "zip: "},
      {"pe.com", writable_text(data), "pe: .text: writable code"},
      {"elf.com", rwx_load(data, elf),
       "elf x86_64: LOAD at 0x0000000000400000: writable and executable"},
      {"macho.com", rwx_segment(data), "macho: __APE1: starts writable and executable"}
    ]

    for {name, bytes, message} <- broken do
      file = write(dir, name, bytes)
      {out, status} = check(file, copies)
      assert status == 1, out
      assert out =~ "FAIL #{file}: #{message}"
      File.rm!(file)
    end
  end

  defp write(dir, name, bytes) do
    file = Path.join(dir, name)
    File.write!(file, bytes)
    File.chmod!(file, 0o755)
    file
  end

  defp check(file, copies) do
    System.cmd(@script, [file], env: [{"FORMAT_TMP", copies}], stderr_to_stdout: true)
  end

  # The section .text of the PE gets IMAGE_SCN_MEM_WRITE.
  defp writable_text(data) do
    <<pe::little-32>> = binary_part(data, 0x3C, 4)
    <<count::little-16>> = binary_part(data, pe + 6, 2)
    <<optional::little-16>> = binary_part(data, pe + 20, 2)

    offset =
      Enum.find_value(0..(count - 1), fn i ->
        o = pe + 24 + optional + 40 * i
        binary_part(data, o, 5) == ".text" && o + 36
      end)

    <<flags::little-32>> = binary_part(data, offset, 4)
    patch(data, offset, <<Bitwise.bor(flags, 0x80000000)::little-32>>)
  end

  # The first PT_LOAD with the flags R and E (5) gets the flags R, W and E (7).
  defp rwx_load(data, elf) do
    <<phoff::little-64>> = binary_part(elf, 32, 8)
    <<count::little-16>> = binary_part(elf, 56, 2)

    offset =
      Enum.find_value(0..(count - 1), fn i ->
        o = phoff + 56 * i
        binary_part(data, o, 8) == <<1::little-32, 5::little-32>> && o + 4
      end)

    patch(data, offset, <<7::little-32>>)
  end

  # The Mach-O segment __APE1 starts with the protection rwx: initprot is
  # 52 bytes after the start of segname.
  defp rwx_segment(data) do
    {start, _} = :binary.match(data, "__APE1\0")
    patch(data, start + 52, <<7::little-32>>)
  end

  defp patch(data, offset, bytes) do
    binary_part(data, 0, offset) <>
      bytes <>
      binary_part(data, offset + byte_size(bytes), byte_size(data) - offset - byte_size(bytes))
  end
end
