defmodule Mix.Tasks.Hex.User do
  use Mix.Task
  alias Mix.Hex.Utils

  @shortdoc "Hex user tasks"

  @moduledoc """
  Hex user tasks.

  ### Register a new user

  `mix hex.user register`

  ### Print the current user

  `mix hex.user whoami`

  ### Authorize a new user

  Authorizes a new user on the local machine by generating a new API key and
  storing it in the Hex config.

  `mix hex.user auth`

  ### Deauthorize the user

  Deauthorizes the user from the local machine by removing the API key from the
  Hex config.

  `mix hex.user deauth`

  ### Test authentication

  Tests if authentication works with the stored API key.

  `mix hex.user test`

  ### Reset user password

  `mix hex.user reset password`
  """

  @switches [clean_pass: :boolean]

  def run(args) do
    Hex.start
    Hex.Utils.ensure_registry(update: false)

    {opts, rest, _} = OptionParser.parse(args, switches: @switches)

    case rest do
      ["register"] ->
        register(opts)
      ["whoami"] ->
        whoami()
      ["auth"] ->
        create_key(opts)
      ["deauth"] ->
        deauth()
      ["reset", "password"] ->
        reset_password()
      ["test"] ->
        test()
      _ ->
        Mix.raise "Invalid arguments, expected one of:\nmix hex.user register\n" <>
                  "mix hex.user auth\nmix hex.user whoami\nmix hex.user deauth\nmix hex.user reset password"
    end
  end

  defp whoami() do
    config = Hex.Config.read
    username = local_user(config)
    Hex.Shell.info(username)
  end

  defp reset_password() do
    name = Hex.Shell.prompt("Username or Email:") |> String.strip

    case Hex.API.User.password_reset(name) do
      {code, _} when code in 200..299 ->
        Hex.Shell.info "We’ve sent you an email containing a link that will allow you to reset your password for the next 24 hours. " <>
                       "Please check your spam folder if the email doesn’t appear within a few minutes."
      {code, body} ->
        Hex.Shell.error("Initiating password reset for #{name} failed")
        Hex.Utils.print_error_result(code, body)
    end
  end

  defp deauth() do
    config = Hex.Config.read
    username = local_user(config)

    config
    |> Keyword.drop([:username, :key])
    |> Hex.Config.write

    Hex.Shell.info "User `" <> username <> "` removed from the local machine. " <>
                   "To authenticate again, run `mix hex.user auth` " <>
                   "or create a new user with `mix hex.user register`"
  end

  defp register(opts) do
    clean? = Keyword.get(opts, :clean_pass, true)

    username = Hex.Shell.prompt("Username:")  |> String.strip
    email    = Hex.Shell.prompt("Email:")     |> String.strip
    password = Utils.password_get("Password:", clean?) |> String.strip

    unless is_nil(password) do
      confirm = Utils.password_get("Password (confirm):", clean?) |> String.strip
      if password != confirm do
        Mix.raise "Entered passwords do not match"
      end
    end

    Hex.Shell.info("Registering...")
    create_user(username, email, password)
  end

  defp create_user(username, email, password) do
    case Hex.API.User.new(username, email, password) do
      {code, _} when code in 200..299 ->
        Utils.generate_key(username, password)
        Hex.Shell.info("You are required to confirm your email to access your account, " <>
                       "a confirmation email has been sent to #{email}")
      {code, body} ->
        Hex.Shell.error("Registration of user #{username} failed")
        Hex.Utils.print_error_result(code, body)
    end
  end

  defp create_key(opts) do
    clean? = Keyword.get(opts, :clean_pass, true)

    username = Hex.Shell.prompt("Username:")          |> String.strip
    password = Utils.password_get("Password:", clean?) |> String.strip

    Utils.generate_key(username, password)
  end

  defp test do
    config = Hex.Config.read
    username = local_user(config)
    auth = Utils.auth_info(config)

    case Hex.API.User.get(username, auth) do
      {code, _} when code in 200..299 ->
        Hex.Shell.info("Successfully authed. Your key works.")
      {code, body} ->
        Hex.Shell.error("Failed to auth")
        Hex.Utils.print_error_result(code, body)
    end
  end

  defp local_user(config) do
    case Keyword.fetch(config, :username) do
      {:ok, username} ->
        username
      :error ->
        Mix.raise "No user authorised on the local machine. Run `mix hex.user auth` " <>
                  "or create a new user with `mix hex.user register`"
    end
  end
end
