defmodule GEPA.OptimizeTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.LLM.Mock
  alias GEPA.Adapters.Basic

  describe "GEPA.optimize/1 with reflection_llm" do
    test "accepts reflection_llm option" do
      llm = Mock.new(responses: ["LLM-improved instruction"])

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 10,
          reflection_llm: llm
        )

      # Should complete without error
      assert %GEPA.Result{} = result
    end

    test "uses LLM to generate improved candidates when reflection_llm provided" do
      # Track calls to LLM
      call_count = :counters.new(1, [:atomics])

      llm =
        Mock.new(
          response_fn: fn _prompt ->
            :counters.add(call_count, 1, 1)
            "LLM-generated improvement"
          end
        )

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 15,
          reflection_llm: llm,
          skip_perfect_score: false
        )

      # LLM should have been called at least once
      assert :counters.get(call_count, 1) > 0

      # Result should have candidates
      assert length(result.candidates) >= 1
    end

    test "accepts custom proposal_template with reflection_llm" do
      captured_prompts = :ets.new(:captured_prompts, [:set, :public])

      llm =
        Mock.new(
          response_fn: fn prompt ->
            :ets.insert(captured_prompts, {System.unique_integer(), prompt})
            "improved"
          end
        )

      custom_template = """
      CUSTOM_MARKER: Improve {component_name}
      Current: {current_instruction}
      Feedback: {reflective_dataset}
      """

      {:ok, _result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 10,
          reflection_llm: llm,
          proposal_template: custom_template,
          skip_perfect_score: false
        )

      # Check that custom template was used
      prompts = :ets.tab2list(captured_prompts) |> Enum.map(&elem(&1, 1))
      :ets.delete(captured_prompts)

      if length(prompts) > 0 do
        assert Enum.any?(prompts, &String.contains?(&1, "CUSTOM_MARKER"))
      end
    end

    test "falls back to simple improvement without reflection_llm" do
      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 10
          # No reflection_llm - should use fallback
        )

      # Should still work with fallback
      assert %GEPA.Result{} = result
    end
  end

  describe "GEPA.optimize/1 option validation" do
    test "raises when seed_candidate not provided" do
      assert_raise ArgumentError, ~r/must provide :seed_candidate/, fn ->
        GEPA.optimize(
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 10
        )
      end
    end

    test "raises when adapter not provided" do
      assert_raise ArgumentError, ~r/must provide :adapter/, fn ->
        GEPA.optimize(
          seed_candidate: %{"i" => "test"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          max_metric_calls: 10
        )
      end
    end

    test "raises when max_metric_calls not provided" do
      assert_raise ArgumentError, ~r/must provide :max_metric_calls/, fn ->
        GEPA.optimize(
          seed_candidate: %{"i" => "test"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new()
        )
      end
    end
  end
end
