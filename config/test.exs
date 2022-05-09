import Config

alias Datagouvfr.Authentication

# avoid test failures with VCR, as tzdata tries to update
config :tzdata, :autoupdate, :disabled

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :transport, TransportWeb.Endpoint,
  # If you change this, there are hardcoded refs in the source to update
  http: [port: 5100],
  server: true

# Page cache would make tests brittle, so disable it by default
config :gbfs, :disable_page_cache, true

config :unlock,
  config_fetcher: Unlock.Config.Fetcher.Mock,
  http_client: Unlock.HTTP.Client.Mock,
  # Used for config testing
  github_config_url: "https://localhost/some-github-url",
  github_auth_token: "some-test-github-auth-token"

# Use stubbing to enjoy disconnected tests & allow setting mocks expectations
config :transport,
  cache_impl: Transport.Cache.Null,
  ex_aws_impl: Transport.ExAWS.Mock,
  httpoison_impl: Transport.HTTPoison.Mock,
  history_impl: Transport.History.Fetcher.Mock,
  gtfs_validator: Shared.Validation.Validator.Mock,
  gbfs_validator_impl: Shared.Validation.GBFSValidator.Mock,
  rambo_impl: Transport.Rambo.Mock,
  notifications_impl: Transport.Notifications.FetcherMock,
  gbfs_metadata_impl: Transport.Shared.GBFSMetadata.Mock,
  availability_checker_impl: Transport.AvailabilityChecker.Mock,
  jsonschema_validator_impl: Shared.Validation.JSONSchemaValidator.Mock,
  tableschema_validator_impl: Shared.Validation.TableSchemaValidator.Mock,
  schemas_impl: Transport.Shared.Schemas.Mock,
  hasher_impl: Hasher.Mock,
  validator_selection: Transport.ValidatorsSelection.Mock,
  data_visualization: Transport.DataVisualization.Mock,
  notifications_api_token: "secret",
  s3_buckets: %{
    history: "resource-history-test",
    on_demand_validation: "on-demand-validation-test"
  }

config :ex_aws,
  cellar_organisation_id: "fake-cellar_organisation_id"

config :datagouvfr,
  community_resources_impl: Datagouvfr.Client.CommunityResources.Mock,
  authentication_impl: Datagouvfr.Authentication.Mock,
  user_impl: Datagouvfr.Client.User.Mock

# capture all info logs and up during tests
config :logger, level: :debug

# ... but show only warnings and up on the console
config :logger, :console, level: :warn

# Configure data.gouv.fr authentication
config :oauth2, Authentication,
  site: "https://demo.data.gouv.fr",
  client_id: "my_client_id",
  client_secret: "my_client_secret"

# Validator configuration
config :transport, gtfs_validator_url: System.get_env("GTFS_VALIDATOR_URL") || "http://127.0.0.1:7878"

config :exvcr,
  vcr_cassette_library_dir: "test/fixture/cassettes",
  filter_request_headers: ["authorization"]

config :transport, DB.Repo,
  url: System.get_env("PG_URL_TEST") || System.get_env("PG_URL") || "ecto://postgres:postgres@localhost/transport_test",
  pool: Ecto.Adapters.SQL.Sandbox

# temporary stuff, yet this is not DRY
config :transport,
  datagouvfr_site: "https://demo.data.gouv.fr",
  # NOTE: some tests still rely on ExVCR cassettes at the moment. We configure the
  # expected host here, until we move to a behaviour-based testing instead.
  gtfs_validator_url: "https://validation.transport.data.gouv.fr"

secret_key_base = "SOME-LONG-SECRET-KEY-BASE-FOR-TESTING-SOME-LONG-SECRET-KEY-BASE-FOR-TESTING"

config :transport, TransportWeb.Endpoint,
  secret_key_base: secret_key_base,
  live_view: [
    # NOTE: unsure if this is actually great to reuse the same value
    signing_salt: secret_key_base
  ]

# NOTE: adding some explicit values so that we can test the
# behaviour of the client with regard to those credentials,
# but these are not real keys.
config :transport, Mailjet.Client,
  mailjet_user: "TEST_MJ_APIKEY_PUBLIC",
  mailjet_key: "TEST_MJ_APIKEY_PRIVATE"

config :transport, :email_sender_impl, Transport.EmailSender.Mock
