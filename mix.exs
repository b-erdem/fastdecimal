defmodule FastDecimal.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/b-erdem/fastdecimal"

  def project do
    [
      app: :fastdecimal,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "FastDecimal",
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:decimal, "~> 2.1"},
      {:ecto, "~> 3.0", optional: true},
      {:benchee, "~> 1.3", only: [:dev, :test]},
      {:benchee_html, "~> 1.0", only: [:dev, :test]},
      {:stream_data, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      bench: ["run bench/summary.exs"],
      "bench.all": [
        "run bench/arithmetic.exs",
        "run bench/division.exs",
        "run bench/rounding.exs",
        "run bench/sqrt.exs",
        "run bench/conversion.exs",
        "run bench/special_values.exs",
        "run bench/batch.exs",
        "run bench/parse.exs",
        "run bench/representation.exs",
        "run bench/profile.exs",
        "run bench/realistic.exs"
      ]
    ]
  end

  defp description do
    """
    Fast arbitrary-precision decimal arithmetic for Elixir. A pure-Elixir
    alternative to the decimal library — ~10x faster on average across the
    common operations (add, sub, mult, div, compare, parse), with a drop-in
    compatibility shim, ~d sigil, and Ecto.Type.
    """
  end

  defp package do
    [
      maintainers: ["Baris Erdem"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md MIGRATION.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "MIGRATION.md",
        "CHANGELOG.md",
        "bench/README.md",
        "LICENSE"
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        Core: [FastDecimal],
        Integration: [FastDecimal.Compat, FastDecimal.Ecto.Type],
        Internal: [FastDecimal.Parser]
      ]
    ]
  end
end
