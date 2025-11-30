defmodule GepaExTest do
  use GEPA.SupertesterCase, isolation: :full_isolation, async: false
  doctest GepaEx

  test "greets the world" do
    assert GepaEx.hello() == :world
  end
end
