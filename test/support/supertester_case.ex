defmodule GEPA.SupertesterCase do
  @moduledoc """
  Base test case that wires Supertester isolation into the test suite.
  """

  defmacro __using__(opts) do
    isolation = Keyword.get(opts, :isolation, :full_isolation)

    async? =
      Keyword.get(
        opts,
        :async,
        Supertester.UnifiedTestFoundation.isolation_allows_async?(isolation)
      )

    quote do
      use ExUnit.Case, async: unquote(async?)

      setup context do
        Supertester.UnifiedTestFoundation.setup_isolation(unquote(isolation), context)
      end

      import Supertester.Assertions
    end
  end
end
