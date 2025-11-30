# Epsilon-Greedy Candidate Selector

> **Priority**: Low
> **Estimated Effort**: 1-2 hours
> **Dependencies**: None

## Current State

GEPA has two candidate selectors:

1. **`GEPA.Strategies.CandidateSelector.Pareto`** - Frequency-weighted selection from Pareto front
2. **`GEPA.Strategies.CandidateSelector.CurrentBest`** - Always select highest-scoring candidate

Missing: **Epsilon-Greedy** - Balances exploration/exploitation with configurable randomness.

---

## Python Reference

```python
class EpsilonGreedyCandidateSelector:
    """
    Select best candidate with probability (1 - epsilon),
    random candidate with probability epsilon.

    Supports epsilon decay for annealing exploration over time.
    """

    def __init__(
        self,
        epsilon: float = 0.1,
        epsilon_decay: float = 1.0,
        epsilon_min: float = 0.01
    ):
        self.epsilon = epsilon
        self.epsilon_decay = epsilon_decay
        self.epsilon_min = epsilon_min
        self.current_epsilon = epsilon

    def select(self, state: GEPAState, rng: Random) -> int:
        if rng.random() < self.current_epsilon:
            # Explore: random candidate
            return rng.choice(range(len(state.program_candidates)))
        else:
            # Exploit: best candidate
            return state.best_program_idx

    def step(self):
        """Decay epsilon after each selection."""
        self.current_epsilon = max(
            self.epsilon_min,
            self.current_epsilon * self.epsilon_decay
        )
```

---

## Proposed Implementation

```elixir
defmodule GEPA.Strategies.CandidateSelector.EpsilonGreedy do
  @moduledoc """
  Epsilon-greedy candidate selection with optional decay.

  Balances exploration (random selection) with exploitation (best candidate)
  using a configurable epsilon parameter.

  ## Configuration

  - `:epsilon` - Initial probability of random selection (default: 0.1)
  - `:epsilon_decay` - Multiplicative decay per selection (default: 1.0 = no decay)
  - `:epsilon_min` - Minimum epsilon after decay (default: 0.01)

  ## Usage

      selector = EpsilonGreedy.new(epsilon: 0.2, epsilon_decay: 0.99)
      {candidate_idx, new_selector, new_rand} = EpsilonGreedy.select(selector, state, rand_state)

  ## Epsilon Decay

  With decay, epsilon decreases over time:

      # Start with 20% exploration, decay to 1%
      selector = EpsilonGreedy.new(
        epsilon: 0.2,
        epsilon_decay: 0.95,
        epsilon_min: 0.01
      )

      # After 50 selections: epsilon ≈ 0.2 * 0.95^50 ≈ 0.015
  """

  @behaviour GEPA.Strategies.CandidateSelector

  defstruct [
    :epsilon,
    :epsilon_decay,
    :epsilon_min,
    :current_epsilon
  ]

  @type t :: %__MODULE__{
    epsilon: float(),
    epsilon_decay: float(),
    epsilon_min: float(),
    current_epsilon: float()
  }

  @doc """
  Create a new epsilon-greedy selector.

  ## Options

  - `:epsilon` - Initial exploration probability (default: 0.1)
  - `:epsilon_decay` - Decay factor per selection (default: 1.0)
  - `:epsilon_min` - Minimum epsilon value (default: 0.01)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    epsilon = opts[:epsilon] || 0.1
    validate_probability!(epsilon, :epsilon)
    validate_probability!(opts[:epsilon_decay] || 1.0, :epsilon_decay)
    validate_probability!(opts[:epsilon_min] || 0.01, :epsilon_min)

    %__MODULE__{
      epsilon: epsilon,
      epsilon_decay: opts[:epsilon_decay] || 1.0,
      epsilon_min: opts[:epsilon_min] || 0.01,
      current_epsilon: epsilon
    }
  end

  @doc """
  Select a candidate using epsilon-greedy strategy.

  Returns `{candidate_idx, updated_selector, new_rand_state}`.

  The selector is updated with decayed epsilon for next selection.
  """
  @impl GEPA.Strategies.CandidateSelector
  @spec select(t(), GEPA.State.t(), :rand.state()) ::
    {non_neg_integer(), t(), :rand.state()}
  def select(%__MODULE__{} = selector, state, rand_state) do
    {random_value, rand_state} = :rand.uniform_s(rand_state)

    num_candidates = length(state.program_candidates)

    {candidate_idx, rand_state} =
      if random_value < selector.current_epsilon do
        # Explore: random candidate
        {random_idx, new_rand} = random_candidate(num_candidates, rand_state)
        {random_idx, new_rand}
      else
        # Exploit: best candidate
        {best_idx, _score} = GEPA.State.get_best_program(state)
        {best_idx, rand_state}
      end

    # Decay epsilon for next selection
    updated_selector = decay_epsilon(selector)

    {candidate_idx, updated_selector, rand_state}
  end

  @doc """
  Reset epsilon to initial value.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = selector) do
    %{selector | current_epsilon: selector.epsilon}
  end

  @doc """
  Get current epsilon value.
  """
  @spec current_epsilon(t()) :: float()
  def current_epsilon(%__MODULE__{current_epsilon: eps}), do: eps

  # Private functions

  defp random_candidate(num_candidates, rand_state) do
    {value, new_rand} = :rand.uniform_s(rand_state)
    idx = trunc(value * num_candidates)
    # Ensure we don't go out of bounds due to floating point
    idx = min(idx, num_candidates - 1)
    {idx, new_rand}
  end

  defp decay_epsilon(%__MODULE__{} = selector) do
    new_epsilon = max(
      selector.epsilon_min,
      selector.current_epsilon * selector.epsilon_decay
    )
    %{selector | current_epsilon: new_epsilon}
  end

  defp validate_probability!(value, field) when is_float(value) do
    if value < 0.0 or value > 1.0 do
      raise ArgumentError, "#{field} must be between 0.0 and 1.0, got: #{value}"
    end
  end

  defp validate_probability!(value, field) do
    raise ArgumentError, "#{field} must be a float, got: #{inspect(value)}"
  end
end
```

### Update Behaviour Module

```elixir
defmodule GEPA.Strategies.CandidateSelector do
  @moduledoc """
  Behaviour for candidate selection strategies.

  Implementations determine which candidate to use as the parent
  for the next proposal iteration.
  """

  @doc """
  Select a candidate index from the current state.

  Returns `{candidate_idx, rand_state}` for stateless selectors,
  or `{candidate_idx, updated_selector, rand_state}` for stateful selectors.
  """
  @callback select(state :: GEPA.State.t(), rand_state :: :rand.state()) ::
    {non_neg_integer(), :rand.state()}
    | {non_neg_integer(), term(), :rand.state()}
end
```

---

## Usage Examples

### Basic Usage

```elixir
# 10% exploration, 90% exploitation (no decay)
{:ok, result} = GEPA.optimize(
  seed_candidate: %{"instruction" => "..."},
  trainset: trainset,
  valset: valset,
  adapter: adapter,
  max_metric_calls: 100,
  candidate_selector: GEPA.Strategies.CandidateSelector.EpsilonGreedy.new(epsilon: 0.1)
)
```

### With Epsilon Decay

```elixir
# Start with 30% exploration, decay to 5% minimum
selector = GEPA.Strategies.CandidateSelector.EpsilonGreedy.new(
  epsilon: 0.3,
  epsilon_decay: 0.95,
  epsilon_min: 0.05
)

{:ok, result} = GEPA.optimize(
  # ...
  candidate_selector: selector
)
```

### Aggressive Exploration Early

```elixir
# High exploration initially, then purely greedy
selector = GEPA.Strategies.CandidateSelector.EpsilonGreedy.new(
  epsilon: 0.5,        # 50% random initially
  epsilon_decay: 0.9,  # Fast decay
  epsilon_min: 0.0     # Eventually pure exploitation
)
```

---

## Testing Plan

```elixir
defmodule GEPA.Strategies.CandidateSelector.EpsilonGreedyTest do
  use ExUnit.Case
  alias GEPA.Strategies.CandidateSelector.EpsilonGreedy

  describe "new/1" do
    test "creates with default values" do
      selector = EpsilonGreedy.new()
      assert selector.epsilon == 0.1
      assert selector.epsilon_decay == 1.0
      assert selector.epsilon_min == 0.01
      assert selector.current_epsilon == 0.1
    end

    test "validates epsilon range" do
      assert_raise ArgumentError, fn ->
        EpsilonGreedy.new(epsilon: 1.5)
      end

      assert_raise ArgumentError, fn ->
        EpsilonGreedy.new(epsilon: -0.1)
      end
    end
  end

  describe "select/3" do
    test "sometimes selects randomly with high epsilon" do
      selector = EpsilonGreedy.new(epsilon: 1.0)  # Always explore
      state = mock_state_with_candidates(5)
      rand_state = :rand.seed(:exsss, {1, 2, 3})

      # Multiple selections should give different results
      results = for _ <- 1..10, reduce: {[], rand_state} do
        {acc, rand} ->
          {idx, _selector, new_rand} = EpsilonGreedy.select(selector, state, rand)
          {[idx | acc], new_rand}
      end
      |> elem(0)

      # With epsilon=1.0, we should see variety
      assert length(Enum.uniq(results)) > 1
    end

    test "always selects best with epsilon=0" do
      selector = EpsilonGreedy.new(epsilon: 0.0, epsilon_min: 0.0)
      state = mock_state_with_candidates(5)
      rand_state = :rand.seed(:exsss, {1, 2, 3})

      {best_idx, _} = GEPA.State.get_best_program(state)

      # Multiple selections should all be best
      for _ <- 1..10, reduce: rand_state do
        rand ->
          {idx, _selector, new_rand} = EpsilonGreedy.select(selector, state, rand)
          assert idx == best_idx
          new_rand
      end
    end

    test "decays epsilon after selection" do
      selector = EpsilonGreedy.new(epsilon: 0.5, epsilon_decay: 0.9)
      state = mock_state_with_candidates(3)
      rand_state = :rand.seed(:exsss, {1, 2, 3})

      {_idx, selector2, _rand} = EpsilonGreedy.select(selector, state, rand_state)
      assert selector2.current_epsilon == 0.5 * 0.9

      {_idx, selector3, _rand} = EpsilonGreedy.select(selector2, state, rand_state)
      assert_in_delta selector3.current_epsilon, 0.5 * 0.9 * 0.9, 0.001
    end

    test "respects epsilon_min" do
      selector = EpsilonGreedy.new(
        epsilon: 0.1,
        epsilon_decay: 0.5,
        epsilon_min: 0.05
      )
      state = mock_state_with_candidates(3)
      rand_state = :rand.seed(:exsss, {1, 2, 3})

      # Decay multiple times
      final_selector = for _ <- 1..20, reduce: selector do
        sel ->
          {_idx, new_sel, _rand} = EpsilonGreedy.select(sel, state, rand_state)
          new_sel
      end

      # Should not go below minimum
      assert final_selector.current_epsilon >= 0.05
    end
  end

  describe "reset/1" do
    test "resets current_epsilon to initial value" do
      selector = EpsilonGreedy.new(epsilon: 0.5, epsilon_decay: 0.9)
      state = mock_state_with_candidates(3)
      rand_state = :rand.seed(:exsss, {1, 2, 3})

      # Decay
      {_idx, decayed, _rand} = EpsilonGreedy.select(selector, state, rand_state)
      assert decayed.current_epsilon < 0.5

      # Reset
      reset = EpsilonGreedy.reset(decayed)
      assert reset.current_epsilon == 0.5
    end
  end

  # Helper to create mock state
  defp mock_state_with_candidates(n) do
    candidates = for i <- 1..n, do: %{"instruction" => "Candidate #{i}"}
    scores = for i <- 1..n, do: {0, i / n}  # Ascending scores

    %GEPA.State{
      program_candidates: candidates,
      prog_candidate_val_subscores: Enum.map(scores, fn {_id, score} -> %{0 => score} end),
      # ... other required fields ...
    }
  end
end
```

---

## Integration with Engine

The engine needs minor updates to support stateful selectors:

```elixir
# In GEPA.Engine or GEPA.Proposer.Reflective

defp select_candidate(selector, state, rand_state) do
  case selector do
    # Stateless selectors (module)
    module when is_atom(module) ->
      {idx, new_rand} = module.select(state, rand_state)
      {idx, selector, new_rand}

    # Stateful selectors (struct)
    %{__struct__: module} = struct ->
      module.select(struct, state, rand_state)
  end
end
```

---

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `lib/gepa/strategies/candidate_selector/epsilon_greedy.ex` | Create | New selector |
| `lib/gepa/strategies/candidate_selector.ex` | Modify | Update behaviour |
| `lib/gepa/proposer/reflective.ex` | Modify | Support stateful selectors |
| `test/gepa/strategies/candidate_selector/epsilon_greedy_test.exs` | Create | Tests |
