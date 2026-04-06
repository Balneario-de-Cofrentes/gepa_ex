defmodule GEPA.LLM.Anthropic do
  @moduledoc """
  Anthropic Claude LLM implementation using the Anthropic Messages API directly via Req.

  Calls `https://api.anthropic.com/v1/messages` without going through ReqLLM.

  ## Configuration

  API key can be provided via:
  1. Runtime option `:api_key`
  2. Environment variable `ANTHROPIC_API_KEY`

  ## Examples

      # With default model (claude-haiku-4-5)
      llm = GEPA.LLM.Anthropic.new()
      {:ok, response} = GEPA.LLM.complete(llm, "Explain GEPA in one sentence")

      # With custom model
      llm = GEPA.LLM.Anthropic.new(model: "claude-opus-4-5", temperature: 0.9)
      {:ok, response} = GEPA.LLM.complete(llm, "Write a haiku about Elixir")

      # Override options per call
      {:ok, response} = GEPA.LLM.complete(llm, prompt, temperature: 0.1, max_tokens: 100)
  """

  @behaviour GEPA.LLM

  @anthropic_api_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"

  @default_model "claude-haiku-4-5"
  @default_temperature 0.7
  @default_max_tokens 2000
  @default_timeout 60_000

  defstruct [
    :model,
    :api_key,
    :temperature,
    :max_tokens,
    :timeout
  ]

  @type t :: %__MODULE__{
          model: String.t(),
          api_key: String.t() | nil,
          temperature: float(),
          max_tokens: pos_integer(),
          timeout: pos_integer()
        }

  @doc """
  Creates a new Anthropic LLM instance.

  ## Options

    - `:model` - Claude model name (default: `"claude-haiku-4-5"`)
    - `:api_key` - Anthropic API key (falls back to `ANTHROPIC_API_KEY` env var)
    - `:temperature` - Sampling temperature 0.0–1.0 (default: 0.7)
    - `:max_tokens` - Maximum tokens to generate (default: 2000)
    - `:timeout` - Request timeout in milliseconds (default: 60_000)

  ## Examples

      llm = GEPA.LLM.Anthropic.new()
      llm = GEPA.LLM.Anthropic.new(model: "claude-opus-4-5", temperature: 0.9)
      llm = GEPA.LLM.Anthropic.new(api_key: "sk-ant-...", max_tokens: 1000)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      model: Keyword.get(opts, :model, @default_model),
      api_key: Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY"),
      temperature: Keyword.get(opts, :temperature, @default_temperature),
      max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }
  end

  @impl GEPA.LLM
  @spec complete(t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(%__MODULE__{} = llm, prompt, opts \\ []) when is_binary(prompt) do
    model = Keyword.get(opts, :model, llm.model)
    api_key = Keyword.get(opts, :api_key, llm.api_key)
    temperature = Keyword.get(opts, :temperature, llm.temperature)
    max_tokens = Keyword.get(opts, :max_tokens, llm.max_tokens)
    timeout = Keyword.get(opts, :timeout, llm.timeout)

    with {:ok, key} <- validate_api_key(api_key) do
      body = %{
        model: model,
        max_tokens: max_tokens,
        temperature: temperature,
        messages: [%{role: "user", content: prompt}]
      }

      case Req.post(@anthropic_api_url,
             json: body,
             headers: build_headers(key),
             receive_timeout: timeout
           ) do
        {:ok, %{status: 200, body: response_body}} ->
          extract_text(response_body)

        {:ok, %{status: status, body: error_body}} ->
          {:error, format_api_error(status, error_body)}

        {:error, reason} ->
          {:error, format_req_error(reason)}
      end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  ## Private Functions

  defp validate_api_key(nil), do: {:error, "missing required option :api_key"}
  defp validate_api_key(""), do: {:error, "missing required option :api_key"}
  defp validate_api_key(key), do: {:ok, key}

  defp build_headers(api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]
  end

  defp extract_text(%{"content" => [%{"type" => "text", "text" => text} | _]}),
    do: {:ok, text}

  defp extract_text(%{"content" => content}) when is_list(content) do
    case Enum.find(content, &match?(%{"type" => "text"}, &1)) do
      %{"text" => text} -> {:ok, text}
      nil -> {:error, "no text content in Anthropic response"}
    end
  end

  defp extract_text(body),
    do: {:error, "unexpected Anthropic response format: #{inspect(body)}"}

  defp format_api_error(status, %{"error" => %{"message" => message}}) do
    "Anthropic API error #{status}: #{message}"
  end

  defp format_api_error(status, body) do
    "Anthropic API error #{status}: #{inspect(body)}"
  end

  defp format_req_error(%{reason: reason}), do: "request failed: #{inspect(reason)}"
  defp format_req_error(reason), do: "request failed: #{inspect(reason)}"
end
