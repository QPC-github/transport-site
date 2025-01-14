defmodule Transport.Notifications do
  @moduledoc """
  Handles notifications on transport.data.gouv.fr
  """
  require Logger
  alias Transport.Notifications.Item
  @type configuration :: list(Item)

  @reasons [:expiration, :new_dataset, :dataset_now_licence_ouverte]
  @emails_list_reasons [:new_dataset, :dataset_now_licence_ouverte]

  @spec emails_for_reason(configuration, atom()) :: list(binary())
  def emails_for_reason(config, reason) when reason in @emails_list_reasons do
    Enum.find_value(config, [], fn item ->
      if item.reason == reason, do: item.emails
    end)
  end

  @spec emails_for_reason(configuration, atom(), DB.Dataset.t()) :: list(binary())
  def emails_for_reason(config, :expiration = reason, %DB.Dataset{slug: slug}) do
    Enum.find_value(config, [], fn item ->
      if item.reason == reason and item.dataset_slug == slug, do: item.emails
    end)
  end

  def is_valid_extra_delay?(config, :expiration = reason, %DB.Dataset{slug: slug}, delay)
      when is_integer(delay) and delay > 0 do
    item = config |> Enum.find(fn item -> item.reason == reason and item.dataset_slug == slug end)
    if is_nil(item), do: false, else: Enum.member?(item.extra_delays, delay)
  end

  @spec config() :: configuration
  def config, do: Application.fetch_env!(:transport, :notifications_impl).fetch_config!()

  def valid_reasons, do: @reasons

  defmodule Item do
    @moduledoc """
    An intermediate structure to add a bit of typing to the
    external YAML configuration.
    """
    @enforce_keys [:reason, :emails]
    defstruct [:reason, :dataset_slug, :emails, :extra_delays]

    @type t :: %__MODULE__{
            reason: atom,
            dataset_slug: term,
            emails: list(binary),
            extra_delays: list(integer)
          }
  end

  defmodule Fetcher do
    @moduledoc """
    A behaviour + shared methods for config fetching.
    """
    @callback fetch_config!() :: list(Item)
    @callback clear_config_cache!() :: any

    def convert_yaml_to_config_items(body) do
      content = body |> YamlElixir.read_from_string!()

      Transport.Notifications.valid_reasons()
      |> Enum.flat_map(&create_items(&1, content))
    end

    defp create_items(:expiration = reason, content) do
      content
      |> Map.get(Atom.to_string(reason), [])
      |> Enum.map(fn {slug, data} ->
        %Item{
          reason: reason,
          dataset_slug: slug,
          emails: Map.fetch!(data, "emails"),
          extra_delays: Map.get(data, "extra_delays", [])
        }
      end)
    end

    defp create_items(reason, content) do
      [
        %Item{
          reason: reason,
          emails: content |> Map.get(Atom.to_string(reason), [])
        }
      ]
    end
  end

  defmodule GitHub do
    @moduledoc """
    Fetch the configuration from GitHub and cache it in RAM using Cachex.

    This will allow expiry via a simple key deletion.
    """
    @behaviour Fetcher
    @config_cache_key "config:notifications"

    @impl Fetcher
    def fetch_config! do
      # NOTE: this won't handle errors correctly at this point
      fetch_config = fn _key -> {:commit, fetch_config_no_cache!()} end

      case {_operation, _result} = Cachex.fetch(cache_name(), @config_cache_key, fetch_config) do
        {:commit, result} ->
          result

        {:ok, result} ->
          result
      end
    end

    @impl Fetcher
    def clear_config_cache! do
      Cachex.del!(cache_name(), @config_cache_key)
    end

    @doc """
    Retrieve the configuration from GitHub as a map.
    """
    def fetch_config_no_cache! do
      fetch_config_from_github!() |> Fetcher.convert_yaml_to_config_items()
    end

    defp fetch_config_from_github! do
      Logger.info("Fetching notifications config from GitHub")
      config_url = Application.fetch_env!(:transport, :notifications_github_config_url)
      github_token = Application.fetch_env!(:transport, :notifications_github_auth_token)

      client = Transport.Shared.Wrapper.HTTPoison.impl()

      {:ok, %HTTPoison.Response{body: body, status_code: 200}} =
        client.get(config_url, [{"Authorization", "token #{github_token}"}])

      body
    end

    def cache_name, do: Transport.Application.cache_name()
  end

  defmodule Disk do
    @moduledoc """
    Fetch the configuration from a file on disk (useful for development or disk-based persistence).
    """
    @behaviour Fetcher

    @impl Fetcher
    def fetch_config! do
      config_file = Application.fetch_env!(:transport, :notifications_config_file)
      Logger.info("Fetching notifications config using file #{config_file}")

      config_file
      |> File.read!()
      |> Fetcher.convert_yaml_to_config_items()
    end

    @impl Fetcher
    def clear_config_cache! do
      Logger.info("Clearing cache config (no-op)")
    end
  end
end
