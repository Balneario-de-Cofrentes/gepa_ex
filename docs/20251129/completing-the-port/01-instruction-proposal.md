# Instruction Proposal: Custom Templates

> **Priority**: High
> **Estimated Effort**: 4-6 hours
> **Dependencies**: GEPA.LLM module

## Current State

The `GEPA.Proposer.Reflective` module currently has a **hardcoded improvement function**:

```elixir
# lib/gepa/proposer/reflective.ex:107-113
defp improve_candidate(candidate) do
  # Simplified for MVP - append improvement marker
  # In full version, this would use LLM with reflective dataset
  for {key, value} <- candidate, into: %{} do
    {key, value <> "\n[Optimized]"}
  end
end
```

This is a placeholder that doesn't actually use the reflective dataset or LLM.

---

## Python Reference

The Python implementation in `instruction_proposal.py` provides:

### 1. Configurable Prompt Template

```python
DEFAULT_TEMPLATE = """
You are optimizing instructions for a language model pipeline.

Current instruction for component "{component_name}":
{current_instruction}

Here are examples of the component's performance:
{reflective_dataset}

Based on the feedback, propose an improved instruction that:
1. Addresses the identified issues
2. Maintains the core functionality
3. Is clear and concise

New instruction:
"""
```

### 2. Template Validation

```python
def validate_template(template: str) -> bool:
    """Ensure template has required placeholders."""
    required = ["{component_name}", "{current_instruction}", "{reflective_dataset}"]
    return all(p in template for p in required)
```

### 3. Dataset Formatting

```python
def format_reflective_dataset(dataset: list[dict]) -> str:
    """Format dataset for inclusion in prompt."""
    formatted = []
    for i, item in enumerate(dataset, 1):
        formatted.append(f"Example {i}:")
        formatted.append(f"  Inputs: {json.dumps(item['Inputs'], indent=2)}")
        formatted.append(f"  Outputs: {item['Generated Outputs']}")
        formatted.append(f"  Feedback: {item['Feedback']}")
    return "\n".join(formatted)
```

---

## Proposed Implementation

### New Module: `GEPA.Proposer.InstructionProposal`

```elixir
defmodule GEPA.Proposer.InstructionProposal do
  @moduledoc """
  LLM-based instruction proposal with configurable templates.

  ## Default Template

  The default template includes placeholders for:
  - `{component_name}` - Name of the component being optimized
  - `{current_instruction}` - Current instruction text
  - `{reflective_dataset}` - Formatted examples with feedback

  ## Custom Templates

      template = \"\"\"
      Improve this prompt for {component_name}:

      Current: {current_instruction}

      Examples: {reflective_dataset}

      Better prompt:
      \"\"\"

      proposal = InstructionProposal.new(template: template, llm: llm)
  """

  defstruct [
    :template,
    :llm,
    :extract_fn,
    :format_fn
  ]

  @type t :: %__MODULE__{
    template: String.t(),
    llm: GEPA.LLM.t(),
    extract_fn: (String.t() -> String.t()) | nil,
    format_fn: (list(map()) -> String.t()) | nil
  }

  @default_template """
  You are optimizing instructions for a language model pipeline.

  ## Current Instruction for "{component_name}"

  ```
  {current_instruction}
  ```

  ## Performance Examples

  {reflective_dataset}

  ## Task

  Based on the feedback above, propose an improved instruction that:
  1. Addresses the identified issues
  2. Maintains the core functionality
  3. Is clear and concise

  Write ONLY the new instruction, nothing else:
  """

  @required_placeholders ["{component_name}", "{current_instruction}", "{reflective_dataset}"]

  @doc """
  Create a new instruction proposal configuration.

  ## Options

  - `:template` - Custom prompt template (default: built-in template)
  - `:llm` - LLM configuration for proposals (required)
  - `:extract_fn` - Function to extract instruction from LLM response
  - `:format_fn` - Function to format reflective dataset
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    template = opts[:template] || @default_template
    validate_template!(template)

    %__MODULE__{
      template: template,
      llm: opts[:llm] || raise(ArgumentError, "must provide :llm"),
      extract_fn: opts[:extract_fn],
      format_fn: opts[:format_fn]
    }
  end

  @doc """
  Propose new instruction text for a component.
  """
  @spec propose(t(), String.t(), String.t(), list(map())) ::
    {:ok, String.t()} | {:error, term()}
  def propose(%__MODULE__{} = config, component_name, current_instruction, dataset) do
    # Format the dataset
    formatted_dataset = format_dataset(config, dataset)

    # Build prompt from template
    prompt = config.template
      |> String.replace("{component_name}", component_name)
      |> String.replace("{current_instruction}", current_instruction)
      |> String.replace("{reflective_dataset}", formatted_dataset)

    # Call LLM
    case GEPA.LLM.generate(config.llm, prompt) do
      {:ok, response} ->
        # Extract instruction from response
        instruction = extract_instruction(config, response)
        {:ok, instruction}

      {:error, reason} ->
        {:error, {:llm_error, reason}}
    end
  end

  @doc """
  Propose new texts for multiple components.
  """
  @spec propose_batch(t(), map(), map(), list(String.t())) ::
    {:ok, map()} | {:error, term()}
  def propose_batch(%__MODULE__{} = config, candidate, reflective_dataset, components) do
    results = for component <- components do
      current = Map.get(candidate, component, "")
      dataset = Map.get(reflective_dataset, component, [])

      case propose(config, component, current, dataset) do
        {:ok, new_text} -> {:ok, {component, new_text}}
        {:error, reason} -> {:error, {component, reason}}
      end
    end

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      new_texts = results
        |> Enum.map(fn {:ok, pair} -> pair end)
        |> Enum.into(%{})
      {:ok, new_texts}
    else
      {:error, {:partial_failure, errors}}
    end
  end

  # Private functions

  defp validate_template!(template) do
    missing = Enum.reject(@required_placeholders, &String.contains?(template, &1))

    if not Enum.empty?(missing) do
      raise ArgumentError,
        "template missing required placeholders: #{inspect(missing)}"
    end
  end

  defp format_dataset(%__MODULE__{format_fn: nil}, dataset) do
    default_format_dataset(dataset)
  end

  defp format_dataset(%__MODULE__{format_fn: format_fn}, dataset) do
    format_fn.(dataset)
  end

  defp default_format_dataset(dataset) do
    dataset
    |> Enum.with_index(1)
    |> Enum.map(fn {item, i} ->
      """
      ### Example #{i}

      **Inputs:**
      ```json
      #{Jason.encode!(item["Inputs"] || %{}, pretty: true)}
      ```

      **Generated Outputs:**
      #{item["Generated Outputs"] || "N/A"}

      **Feedback:**
      #{item["Feedback"] || "No feedback"}
      """
    end)
    |> Enum.join("\n---\n")
  end

  defp extract_instruction(%__MODULE__{extract_fn: nil}, response) do
    # Default: take whole response, strip whitespace
    String.trim(response)
  end

  defp extract_instruction(%__MODULE__{extract_fn: extract_fn}, response) do
    extract_fn.(response)
  end
end
```

### Update `GEPA.Proposer.Reflective`

```elixir
defmodule GEPA.Proposer.Reflective do
  # ... existing struct fields ...
  defstruct [
    :adapter,
    :trainset,
    :candidate_selector,
    :perfect_score,
    :skip_perfect_score,
    :minibatch_size,
    :instruction_proposal  # NEW FIELD
  ]

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      # ... existing fields ...
      instruction_proposal: opts[:instruction_proposal]  # NEW
    }
  end

  # Update propose/2 to use instruction_proposal
  def propose(%__MODULE__{} = proposer, state) do
    # ... steps 1-4 unchanged ...

    # Step 5: Generate improved candidate
    case generate_improved_candidate(proposer, candidate, eval_batch) do
      {:ok, new_candidate} ->
        # Step 6: Evaluate new candidate
        # ... rest unchanged ...

      {:error, reason} ->
        {:error, {:proposal_failed, reason}}
    end
  end

  defp generate_improved_candidate(proposer, candidate, eval_batch) do
    # Get components to update
    components = Map.keys(candidate)

    # Build reflective dataset
    {:ok, reflective_dataset} =
      proposer.adapter.__struct__.make_reflective_dataset(
        proposer.adapter,
        candidate,
        eval_batch,
        components
      )

    # Use instruction proposal if configured
    case proposer.instruction_proposal do
      nil ->
        # Fallback to simple improvement (for testing)
        {:ok, simple_improve(candidate)}

      proposal_config ->
        GEPA.Proposer.InstructionProposal.propose_batch(
          proposal_config,
          candidate,
          reflective_dataset,
          components
        )
    end
  end

  defp simple_improve(candidate) do
    # Keep existing fallback for testing
    for {key, value} <- candidate, into: %{} do
      {key, value <> "\n[Optimized]"}
    end
  end
end
```

### Update `GEPA.optimize/1`

```elixir
def optimize(opts) do
  # ... existing code ...

  # Build instruction proposal config if LLM provided
  instruction_proposal =
    if opts[:reflection_llm] do
      GEPA.Proposer.InstructionProposal.new(
        llm: opts[:reflection_llm],
        template: opts[:proposal_template]
      )
    else
      nil
    end

  config = %{
    # ... existing fields ...
    instruction_proposal: instruction_proposal
  }

  # ... rest unchanged ...
end
```

---

## Usage Examples

### Basic Usage with Default Template

```elixir
{:ok, result} = GEPA.optimize(
  seed_candidate: %{"instruction" => "Answer the question."},
  trainset: trainset,
  valset: valset,
  adapter: my_adapter,
  max_metric_calls: 100,
  reflection_llm: GEPA.LLM.ReqLLM.new(provider: :openai, model: "gpt-4o-mini")
)
```

### Custom Template

```elixir
custom_template = """
You are a prompt engineer. Improve this instruction.

Component: {component_name}
Current: {current_instruction}

Examples of issues:
{reflective_dataset}

Write a better instruction (one paragraph):
"""

{:ok, result} = GEPA.optimize(
  # ... other options ...
  reflection_llm: my_llm,
  proposal_template: custom_template
)
```

### Custom Extraction Function

```elixir
# Extract instruction from code block
extract_fn = fn response ->
  case Regex.run(~r/```(?:text)?\n(.+?)\n```/s, response) do
    [_, instruction] -> instruction
    nil -> response
  end
end

proposal = GEPA.Proposer.InstructionProposal.new(
  llm: my_llm,
  extract_fn: extract_fn
)
```

---

## Testing Plan

### Unit Tests

```elixir
defmodule GEPA.Proposer.InstructionProposalTest do
  use ExUnit.Case

  describe "new/1" do
    test "creates with default template" do
      llm = GEPA.LLM.Mock.new(response: "improved")
      proposal = InstructionProposal.new(llm: llm)
      assert proposal.template =~ "{component_name}"
    end

    test "validates custom template has required placeholders" do
      llm = GEPA.LLM.Mock.new(response: "improved")

      assert_raise ArgumentError, ~r/missing required placeholders/, fn ->
        InstructionProposal.new(llm: llm, template: "no placeholders")
      end
    end
  end

  describe "propose/4" do
    test "generates improved instruction" do
      llm = GEPA.LLM.Mock.new(response: "Better instruction here")
      proposal = InstructionProposal.new(llm: llm)

      dataset = [%{"Inputs" => %{}, "Generated Outputs" => "bad", "Feedback" => "wrong"}]
      {:ok, result} = InstructionProposal.propose(proposal, "test", "original", dataset)

      assert result == "Better instruction here"
    end

    test "uses custom format function" do
      llm = GEPA.LLM.Mock.new(response: "custom formatted")
      format_fn = fn _dataset -> "CUSTOM FORMAT" end
      proposal = InstructionProposal.new(llm: llm, format_fn: format_fn)

      {:ok, _} = InstructionProposal.propose(proposal, "test", "original", [])
      # Verify prompt contained "CUSTOM FORMAT" via mock inspection
    end
  end
end
```

### Integration Tests

```elixir
defmodule GEPA.Proposer.InstructionProposalIntegrationTest do
  use ExUnit.Case
  @moduletag :integration

  @tag :live_api
  test "proposes with real LLM" do
    llm = GEPA.LLM.ReqLLM.new(provider: :openai, model: "gpt-4o-mini")
    proposal = InstructionProposal.new(llm: llm)

    dataset = [
      %{
        "Inputs" => %{"question" => "What is 2+2?"},
        "Generated Outputs" => "The answer is probably 5",
        "Feedback" => "Incorrect. The answer should be 4."
      }
    ]

    {:ok, result} = InstructionProposal.propose(
      proposal,
      "math_solver",
      "Answer math questions.",
      dataset
    )

    assert is_binary(result)
    assert String.length(result) > 10
  end
end
```

---

## Migration Path

1. **Phase 1**: Add `InstructionProposal` module (non-breaking)
2. **Phase 2**: Update `Reflective` to optionally use it
3. **Phase 3**: Update `GEPA.optimize/1` to accept LLM config
4. **Phase 4**: Deprecate hardcoded fallback in v0.3.0

---

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `lib/gepa/proposer/instruction_proposal.ex` | Create | New module |
| `lib/gepa/proposer/reflective.ex` | Modify | Add instruction_proposal field |
| `lib/gepa.ex` | Modify | Add reflection_llm option |
| `test/gepa/proposer/instruction_proposal_test.exs` | Create | Unit tests |
| `test/integration/instruction_proposal_test.exs` | Create | Integration tests |
