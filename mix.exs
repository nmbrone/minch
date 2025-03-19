defmodule Minch.MixProject do
  use Mix.Project

  @source_url "https://github.com/nmbrone/minch"

  def project do
    [
      app: :minch,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A WebSocket client",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      name: "Minch",
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:cowboy, "~> 2.9", optional: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.27", only: :dev, runtime: false},
      {:mint_web_socket, "~> 1.0"}
    ]
  end

  defp package do
    [
      maintainers: ["Serhii Snozyk"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "Minch",
      extras: ["CHANGELOG.md"]
    ]
  end
end
