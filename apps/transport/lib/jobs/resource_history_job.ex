defmodule Transport.Jobs.ResourceHistoryDispatcherJob do
  @moduledoc """
  Job in charge of dispatching multiple `ResourceHistoryJob`
  """
  use Oban.Worker, unique: [period: 60 * 60 * 5], tags: ["history"], max_attempts: 5
  require Logger
  import Ecto.Query
  alias DB.{Repo, Resource}

  @impl Oban.Worker
  def perform(_job) do
    datagouv_ids = resources_to_historise()

    Logger.debug("Dispatching #{Enum.count(datagouv_ids)} ResourceHistoryJob jobs")

    datagouv_ids
    |> Enum.map(fn datagouv_id ->
      %{datagouv_id: datagouv_id} |> Transport.Jobs.ResourceHistoryJob.new()
    end)
    |> Oban.insert_all()

    :ok
  end

  def resources_to_historise do
    # FIX ME
    # Some datagouv_ids are duplicated for resources.
    # Since our ResourceHistoryJob assumes an uniqueness, ignore
    # those for the time being.
    # See https://github.com/etalab/transport-site/issues/1930
    duplicates =
      Resource
      |> where([r], not is_nil(r.datagouv_id))
      |> group_by([r], r.datagouv_id)
      |> having([r], count(r.datagouv_id) > 1)
      |> select([r], r.datagouv_id)
      |> Repo.all()

    Resource
    |> join(:inner, [r], d in DB.Dataset, on: r.dataset_id == d.id and d.is_active)
    |> where([r], not is_nil(r.url) and not is_nil(r.title) and not is_nil(r.datagouv_id))
    |> where([r], r.datagouv_id not in ^duplicates)
    |> where([r], not r.is_community_resource)
    |> where([r], like(r.url, "http%"))
    |> Repo.all()
    |> Enum.reject(&Resource.is_real_time?/1)
    |> Enum.map(& &1.datagouv_id)
  end
end

defmodule Transport.Jobs.ResourceHistoryJob do
  @moduledoc """
  Job historicising a single resource
  """
  use Oban.Worker, unique: [period: 60 * 60 * 5, fields: [:args, :queue, :worker]], tags: ["history"], max_attempts: 5
  require Logger
  import Ecto.Query
  alias DB.{Repo, Resource, ResourceHistory}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"datagouv_id" => datagouv_id}}) do
    Logger.info("Running ResourceHistoryJob for #{datagouv_id}")
    resource = Resource |> where([r], r.datagouv_id == ^datagouv_id) |> Repo.one!()

    path = download_path(resource)

    try do
      resource |> download_resource(path) |> process_download(resource)
    after
      remove_file(path)
    end

    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  defp process_download({:error, message}, %Resource{datagouv_id: datagouv_id}) do
    # Good opportunity to add a :telemetry event
    # Consider storing in our database that the resource
    # was not available.
    Logger.debug("Got an error while downloading #{datagouv_id}: #{message}")
  end

  defp process_download({:ok, resource_path, headers, body}, %Resource{datagouv_id: datagouv_id} = resource) do
    download_datetime = DateTime.utc_now()

    hash = resource_hash(resource, resource_path)

    case should_store_resource?(resource, hash) do
      true ->
        filename = upload_filename(resource, download_datetime)

        base = %{
          download_datetime: download_datetime,
          uuid: Ecto.UUID.generate(),
          http_headers: headers,
          resource_metadata: resource.metadata,
          title: resource.title,
          filename: filename,
          permanent_url: Transport.S3.permanent_url(:history, filename),
          format: resource.format
        }

        data =
          case is_zip?(resource) do
            true ->
              Map.merge(base, %{
                zip_metadata: hash,
                filenames: hash |> Enum.map(& &1.file_name),
                total_uncompressed_size: hash |> Enum.map(& &1.uncompressed_size) |> Enum.sum(),
                total_compressed_size: hash |> Enum.map(& &1.compressed_size) |> Enum.sum()
              })

            false ->
              Map.merge(base, %{content_hash: hash})
          end

        Transport.S3.upload_to_s3!(:history, body, filename)
        store_resource_history!(resource, data)

      {false, history} ->
        # Good opportunity to add a :telemetry event
        Logger.debug("skipping historization for #{datagouv_id} because resource did not change")
        touch_resource_history!(history)
    end
  end

  @doc """
  Determine if we would historicise a payload now.

  We should historicise a resource if:
  - we never historicised it
  - the latest ResourceHistory payload is different than the current state
  """
  def should_store_resource?(_, []), do: false
  def should_store_resource?(_, nil), do: false

  def should_store_resource?(%Resource{datagouv_id: datagouv_id}, resource_hash) do
    history =
      ResourceHistory
      |> where([r], r.datagouv_id == ^datagouv_id)
      |> order_by(desc: :inserted_at)
      |> limit(1)
      |> DB.Repo.one()

    case {history, is_same_resource?(history, resource_hash)} do
      {nil, _} -> true
      {_history, false} -> true
      {history, true} -> {false, history}
    end
  end

  @doc """
  Determines if a ZIP metadata payload is the same that was stored in
  the latest resource_history's row in the database by comparing sha256
  hashes for all files in the ZIP.
  """
  def is_same_resource?(%ResourceHistory{payload: %{"zip_metadata" => rh_zip_metadata}}, zip_metadata) do
    MapSet.equal?(set_of_sha256(rh_zip_metadata), set_of_sha256(zip_metadata))
  end

  def is_same_resource?(%ResourceHistory{payload: %{"content_hash" => rh_content_hash}}, content_hash) do
    rh_content_hash == content_hash
  end

  def is_same_resource?(nil, _), do: false

  def set_of_sha256(items) do
    items |> Enum.map(&{map_get(&1, :file_name), map_get(&1, :sha256)}) |> MapSet.new()
  end

  defp resource_hash(%Resource{content_hash: content_hash, datagouv_id: datagouv_id} = resource, resource_path) do
    case is_zip?(resource) do
      true ->
        try do
          Transport.ZipMetaDataExtractor.extract!(resource_path)
        rescue
          _ ->
            Logger.debug("Cannot compute ZIP metadata for #{datagouv_id}")
            nil
        end

      false ->
        content_hash
    end
  end

  def map_get(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp is_zip?(%Resource{format: format}), do: format in ["NeTEx", "GTFS"]

  defp store_resource_history!(%Resource{datagouv_id: datagouv_id}, payload) do
    Logger.debug("Saving ResourceHistory for #{datagouv_id}")

    %ResourceHistory{datagouv_id: datagouv_id, payload: payload, last_up_to_date_at: DateTime.utc_now()}
    |> DB.Repo.insert!()
  end

  defp touch_resource_history!(%ResourceHistory{id: id, datagouv_id: datagouv_id} = history) do
    Logger.debug("Touching unchanged ResourceHistory #{id} for resource datagouv_id #{datagouv_id}")

    history |> Ecto.Changeset.change(%{last_up_to_date_at: DateTime.utc_now()}) |> DB.Repo.update!()
  end

  defp download_path(%Resource{datagouv_id: datagouv_id}) do
    System.tmp_dir!() |> Path.join("resource_#{datagouv_id}_download")
  end

  defp download_resource(%Resource{datagouv_id: datagouv_id, url: url}, file_path) do
    case http_client().get(url, [], follow_redirect: true) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body} = r} ->
        Logger.debug("Saving resource #{datagouv_id} to #{file_path}")
        File.write!(file_path, body)
        {:ok, file_path, relevant_http_headers(r), body}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, "Got a non 200 status: #{status}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Got an error: #{reason}"}
    end
  end

  def http_client, do: Transport.Shared.Wrapper.HTTPoison.impl()

  def remove_file(path), do: File.rm(path)

  def upload_filename(%Resource{datagouv_id: datagouv_id} = resource, %DateTime{} = dt) do
    time = Calendar.strftime(dt, "%Y%m%d.%H%M%S.%f")

    "#{datagouv_id}/#{datagouv_id}.#{time}#{file_extension(resource)}"
  end

  @doc """
  Guess an appropriate file extension according to a format

    iex> file_extension(%DB.Resource{format: "GTFS"})
    ".zip"

    iex> file_extension(%DB.Resource{format: ".csv"})
    ".csv"

    iex> file_extension(%DB.Resource{format: "HTML"})
    ".html"

    iex> file_extension(%DB.Resource{format: ".csv.zip"})
    ".csv.zip"
  """
  def file_extension(%Resource{format: format} = resource) do
    case is_zip?(resource) do
      true ->
        ".zip"

      false ->
        "." <> (format |> String.downcase() |> String.replace_prefix(".", ""))
    end
  end

  def relevant_http_headers(%HTTPoison.Response{headers: headers}) do
    headers_to_keep = [
      "content-disposition",
      "content-encoding",
      "content-length",
      "content-type",
      "etag",
      "expires",
      "if-modified-since",
      "last-modified"
    ]

    headers |> Enum.into(%{}, fn {h, v} -> {String.downcase(h), v} end) |> Map.take(headers_to_keep)
  end
end