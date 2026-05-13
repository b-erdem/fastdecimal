if match?({:module, _}, Code.ensure_compiled(Ecto.Type)) do
  defmodule FastDecimal.Ecto.Type do
    @moduledoc """
    `Ecto.Type` implementation for `FastDecimal`. Lets you use `FastDecimal`
    as the value type for `numeric` / `decimal` columns.

        defmodule MyApp.Invoice do
          use Ecto.Schema

          schema "invoices" do
            field :total, FastDecimal.Ecto.Type
          end
        end

    The database adapter (e.g. postgrex) speaks `Decimal` over the wire — this
    type converts at the boundary so the database stays compatible while your
    Elixir code holds `%FastDecimal{}` structs.
    """

    @behaviour Ecto.Type

    @impl true
    def type, do: :decimal

    @impl true
    def cast(value), do: FastDecimal.cast(value)

    @impl true
    def load(%Decimal{} = d), do: FastDecimal.cast(d)
    def load(%FastDecimal{} = d), do: {:ok, d}
    def load(int) when is_integer(int), do: {:ok, FastDecimal.new(int)}
    def load(str) when is_binary(str), do: FastDecimal.parse(str)
    def load(_), do: :error

    @impl true
    def dump(%FastDecimal{coef: c, exp: e}) when is_integer(c) and c >= 0,
      do: {:ok, %Decimal{sign: 1, coef: c, exp: e}}

    def dump(%FastDecimal{coef: c, exp: e}) when is_integer(c),
      do: {:ok, %Decimal{sign: -1, coef: -c, exp: e}}

    def dump(%FastDecimal{coef: :nan}), do: {:ok, %Decimal{sign: 1, coef: :NaN, exp: 0}}
    def dump(%FastDecimal{coef: :inf}), do: {:ok, %Decimal{sign: 1, coef: :inf, exp: 0}}
    def dump(%FastDecimal{coef: :neg_inf}), do: {:ok, %Decimal{sign: -1, coef: :inf, exp: 0}}
    def dump(_), do: :error

    @impl true
    def equal?(a, b) do
      with {:ok, a_fd} <- cast(a),
           {:ok, b_fd} <- cast(b) do
        FastDecimal.equal?(a_fd, b_fd)
      else
        _ -> false
      end
    end

    @impl true
    def embed_as(_), do: :self
  end
end
