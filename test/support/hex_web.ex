defmodule HexTest.HexWeb do
  import ExUnit.Assertions

  @mixfile_template """
  defmodule ~s.NoConflict.Mixfile do
    use Mix.Project

    def project do
      [app: :~s,
       version: "~s",
       deps: deps()]
    end

    defp deps do
      ~s
    end
  end
  """

  def init do
    check_hexweb()
    mix = hexweb_mix() |> List.to_string

    cmd(mix, ["ecto.drop", "-r", "HexWeb.Repo", "--quiet"])
    cmd(mix, ["ecto.create", "-r", "HexWeb.Repo", "--quiet"])
    cmd(mix, ["ecto.migrate", "-r", "HexWeb.Repo"])
  end

  def start do
    path = String.to_char_list(path())
    key = Path.join(__DIR__, "../fixtures/test_priv.pem")
          |> File.read!
          |> String.to_char_list

    env = [
      {'MIX_ENV', 'hex'},
      {'PATH', path},
      {'HEX_SIGNING_KEY', key}
    ]

    spawn_link(fn ->
      port = Port.open({:spawn_executable, hexweb_mix()}, [
                       :exit_status,
                       :use_stdio,
                       :stderr_to_stdout,
                       :binary,
                       :hide,
                       env: env,
                       cd: hexweb_dir(),
                       args: ["phoenix.server"]])

      fun = fn fun ->
        receive do
          {^port, {:data, data}} ->
            IO.write(data)
            fun.(fun)
          {^port, {:exit_status, status}} ->
            IO.puts "HexWeb quit with status #{status}"
            System.exit(status)
        end
      end

      fun.(fun)
    end)

    wait_on_start()
  end

  defp check_hexweb do
    dir = hexweb_dir()

    unless File.exists?(dir) do
      IO.puts "Unable to find #{dir}, make sure to clone the hex_web repository " <>
              "into it to run integration tests"
      System.exit(1)
    end
  end

  defp hexweb_dir do
    System.get_env("HEXWEB_PATH") || "../hex_web"
  end

  defp hexweb_mix do
    if path = hexweb_elixir() do
      path = String.to_char_list(path)
      :os.find_executable('mix', path)
    else
      :os.find_executable('mix')
    end
  end

  defp hexweb_elixir do
    if path = System.get_env("HEXWEB_ELIXIR_PATH") do
      path |> Path.expand |> Path.join("bin")
    end
  end

  defp hexweb_otp do
    if path = System.get_env("HEXWEB_OTP_PATH") do
      path |> Path.expand |> Path.join("bin")
    end
  end

  defp cmd(command, args) do
    opts = [
        stderr_to_stdout: true,
        into: IO.stream(:stdio, :line),
        env: [{"MIX_ENV", "hex"}, {"PATH", path()}],
        cd: hexweb_dir()]

    0 = System.cmd(command, args, opts) |> elem(1)
  end

  defp path do
    [hexweb_elixir(), hexweb_otp(), System.get_env("PATH")]
    |> Enum.join(":")
  end

  defp wait_on_start do
    case :httpc.request(:get, {'http://localhost:4043', []}, [], []) do
      {:ok, _} ->
        :ok
      {:error, _} ->
        :timer.sleep(10)
        wait_on_start()
    end
  end

  def new_user(username, email, password, key) do
    {201, _, _} = Hex.API.User.new(username, email, password)
    {201, %{"secret" => secret}, _} = Hex.API.Key.new(key, [user: username, pass: password])
    [username: username, key: secret]
  end

  def new_key(auth) do
    {201, %{"secret" => secret}, _} = Hex.API.Key.new("key", auth)
    [key: secret]
  end

  def new_package(name, version, deps, meta, auth) do
    reqs =
      Enum.filter(deps, fn
        {_app, _req, opts} -> !(opts[:path] || opts[:git] || opts[:github])
        _ -> true
      end)

    reqs = Enum.into(reqs, %{}, fn
      {app, req} ->
        {app, %{app: app, requirement: req, optional: false}}
      {app, req, opts} ->
        default_opts = %{app: app, requirement: req, optional: false}
        {opts[:hex] || app, Dict.merge(default_opts, opts)}
    end)

    meta =
      meta
      |> Map.merge(%{name: name, version: version, requirements: reqs})
      |> Map.put_new(:description, "empty")
      |> Map.put_new(:app, name)
      |> Map.put_new(:build_tools, ["mix"])

    deps = inspect(deps, pretty: true)
    module = String.capitalize(name)
    mixfile = :io_lib.format(@mixfile_template, [module, name, version, deps])

    files = [{"mix.exs", List.to_string(mixfile)}]
    tar = Hex.Tar.create(meta, files)

    {result, %{"version" => ^version}, _} = Hex.API.Release.new(name, tar, auth)
    assert result in [200, 201]
  end
end
