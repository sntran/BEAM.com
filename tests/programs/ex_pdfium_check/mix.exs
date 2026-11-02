# A check of the NIF of ex_pdfium (PDFium, Rust) in a build with
# EXTRA_NIFS=ex_pdfium (.github/workflows/pdfium.yml): make, read, render
# and change PDF documents, and the times of some operations.
defmodule ExPdfiumCheck.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_pdfium_check,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:ex_pdfium, "0.6.0"}],
      escript: [main_module: ExPdfiumCheck]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
