defmodule GEPA.LLM do
  @moduledoc """
  Behavior for Language Model integrations.

  This module defines the interface that all LLM providers must implement
  to work with GEPA. It provides a simple, unified API for text completion
  across different LLM providers.

  ## Implementations

  - `GEPA.LLM.ReqLLM` - Production implementation using ReqLLM library
    - Supports OpenAI (default: gpt-4o-mini)
    - Supports Google Gemini (default: gemini-flash-lite-latest)
  - `GEPA.LLM.Anthropic` - Direct Anthropic Messages API implementation via Req
    - Supports Claude models (default: claude-haiku-4-5)
  - `GEPA.LLM.Mock` - Mock implementation for testing

  ## Configuration

  LLM providers can be configured via application config or runtime options:

      config :gepa_ex, :llm,
        provider: :openai,
        api_key: System.get_env("OPENAI_API_KEY"),
        model: "gpt-4o-mini",
        temperature: 0.7

  Or at runtime:

      llm = GEPA.LLM.ReqLLM.new(
        provider: :gemini,
        api_key: System.get_env("GEMINI_API_KEY"),
        model: "gemini-flash-lite-latest"
      )

      {:ok, response} = GEPA.LLM.complete(llm, prompt, temperature: 0.9)

  ## Example

      # Using OpenAI
      llm = GEPA.LLM.ReqLLM.new(provider: :openai)
      {:ok, response} = GEPA.LLM.complete(llm, "Explain GEPA")

      # Using Gemini
      llm = GEPA.LLM.ReqLLM.new(provider: :gemini)
      {:ok, response} = GEPA.LLM.complete(llm, "Explain GEPA")

      # Using Anthropic Claude
      llm = GEPA.LLM.Anthropic.new()
      {:ok, response} = GEPA.LLM.complete(llm, "Explain GEPA")

      # Using Mock (for testing)
      llm = GEPA.LLM.Mock.new(responses: ["Fixed response"])
      {:ok, response} = GEPA.LLM.complete(llm, "Any prompt")
  """

  @type t :: module() | map()

  @type completion_opts :: [
          temperature: float(),
          max_tokens: pos_integer(),
          top_p: float(),
          model: String.t(),
          timeout: pos_integer()
        ]

  @type structured_result :: {:ok, map()} | {:error, term()}

  @doc """
  Completes a prompt using the LLM provider.

  ## Parameters

    - `llm` - LLM provider instance
    - `prompt` - Text prompt to complete
    - `opts` - Optional parameters (temperature, max_tokens, etc.)

  ## Returns

    - `{:ok, response}` - Successful completion with response text
    - `{:error, reason}` - Error with reason

  ## Examples

      {:ok, response} = GEPA.LLM.complete(llm, "What is 2+2?")
      {:ok, response} = GEPA.LLM.complete(llm, prompt, temperature: 0.9, max_tokens: 500)
  """
  @callback complete(llm :: t(), prompt :: String.t(), opts :: completion_opts()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Completes a prompt using the LLM provider and returns a structured map.

  Providers that support native tool_use / function calling implement this
  callback to force well-formed JSON output.  Providers that do not implement
  it fall back to `complete/3` with JSON parsing via `fallback_complete_structured/3`.

  ## Returns

    - `{:ok, map}` - Structured result (always includes at least `"instruction"` key)
    - `{:error, reason}` - Error with reason
  """
  @callback complete_structured(llm :: t(), prompt :: String.t(), opts :: completion_opts()) ::
              structured_result()

  @optional_callbacks complete_structured: 3

  @doc """
  Convenience function to call complete/3 on any LLM implementation.

  Delegates to the appropriate module's complete/3 callback.
  """
  @spec complete(t(), String.t(), completion_opts()) :: {:ok, String.t()} | {:error, term()}
  def complete(llm, prompt, opts \\ [])

  def complete(%module{} = llm, prompt, opts) when is_atom(module) do
    module.complete(llm, prompt, opts)
  end

  def complete(module, prompt, opts) when is_atom(module) do
    module.complete(module, prompt, opts)
  end

  @doc """
  Completes a prompt and returns a structured map.

  Dispatches to the provider's `complete_structured/3` when available;
  falls back to `complete/3` with JSON parsing otherwise.

  ## Examples

      {:ok, %{"instruction" => text}} = GEPA.LLM.complete_structured(llm, prompt)
  """
  @spec complete_structured(t(), String.t(), completion_opts()) :: structured_result()
  def complete_structured(llm, prompt, opts \\ [])

  def complete_structured(%module{} = llm, prompt, opts) when is_atom(module) do
    if function_exported?(module, :complete_structured, 3) do
      module.complete_structured(llm, prompt, opts)
    else
      fallback_complete_structured(llm, prompt, opts)
    end
  end

  def complete_structured(module, prompt, opts) when is_atom(module) do
    if function_exported?(module, :complete_structured, 3) do
      module.complete_structured(module, prompt, opts)
    else
      fallback_complete_structured(module, prompt, opts)
    end
  end

  defp fallback_complete_structured(llm, prompt, opts) do
    case complete(llm, prompt, opts) do
      {:ok, text} -> parse_instruction_json(text)
      {:error, _} = err -> err
    end
  end

  defp parse_instruction_json(text) do
    trimmed = String.trim(text)

    case Jason.decode(trimmed) do
      {:ok, %{"instruction" => _} = map} -> {:ok, map}
      {:ok, map} when is_map(map) -> {:ok, map}
      {:error, _} -> {:ok, %{"instruction" => trimmed}}
    end
  end

  @doc """
  Returns the default LLM provider based on application configuration.

  Priority:
  1. Application config `:gepa_ex, :llm`
  2. Environment variable `GEPA_LLM_PROVIDER`
  3. Falls back to OpenAI via ReqLLM

  ## Examples

      # With config set
      config :gepa_ex, :llm, provider: :gemini
      llm = GEPA.LLM.default()

      # Without config (uses OpenAI)
      llm = GEPA.LLM.default()
  """
  @spec default() :: t()
  def default do
    config = Application.get_env(:gepa_ex, :llm, [])

    provider =
      Keyword.get(config, :provider) ||
        parse_env_provider(System.get_env("GEPA_LLM_PROVIDER")) ||
        :openai

    build_default_llm(provider, config)
  end

  defp build_default_llm(:anthropic, config) do
    GEPA.LLM.Anthropic.new(config)
  end

  defp build_default_llm(provider, config) do
    GEPA.LLM.ReqLLM.new(Keyword.put(config, :provider, provider))
  end

  defp parse_env_provider(nil), do: nil
  defp parse_env_provider("openai"), do: :openai
  defp parse_env_provider("gemini"), do: :gemini
  defp parse_env_provider("anthropic"), do: :anthropic
  defp parse_env_provider("mock"), do: :mock
  defp parse_env_provider(_), do: nil
end
