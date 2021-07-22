defmodule Elementary.AppcenterDashboard.Appstream do
  @moduledoc """
  A GenServer that handles all of the Appstream parsing from the deployed
  repository.
  """

  use GenServer

  alias Elementary.AppcenterDashboard.Projects

  @type t :: %{
          name: String.t(),
          rdnn: String.t(),
          icon: String.t()
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :refresh, 2000)
    {:ok, %{components: [], opts: opts}}
  end

  @doc """
  Downloads the Appstream information and parses it for use in other functions.

  TODO: Make it uncompress in memory instead of writing to a file
  """
  @impl true
  def handle_info(:refresh, state) do
    remote_url = state.opts[:file]
    local_dir = System.tmp_dir!()
    local_compressed_file = Path.join(local_dir, "appstream.xml.gz")

    {:ok, response} =
      :get
      |> Finch.build(remote_url)
      |> Finch.request(FinchPool)

    File.write!(local_compressed_file, response.body)

    components =
      local_compressed_file
      |> File.stream!([{:read_ahead, 100_000}, :compressed])
      |> Enum.to_list()
      |> IO.iodata_to_binary()
      |> Floki.parse_document!()
      |> Floki.find("component")
      |> Enum.map(&parse_appstream_data(&1, state))
      |> Enum.group_by(& &1.rdnn)
      |> Map.values()
      |> Enum.map(fn appstream_datas ->
        Enum.reduce(appstream_datas, %{}, &Map.merge/2)
      end)

    Enum.each(components, &update_project/1)
    File.rmdir(local_dir)
    Process.send_after(self(), :refresh, 5 * 60 * 1000)

    {:noreply, Map.put(state, :components, components)}
  end

  defp update_project(component) do
    if pid = Projects.find(:rdnn, component.rdnn) do
      Projects.update(pid, component)
    end
  end

  defp parse_appstream_data(component, state) do
    name =
      component
      |> Floki.find("name")
      |> Floki.filter_out(%Floki.Selector{
        attributes: [
          %Floki.Selector.AttributeSelector{
            attribute: "xml:lang"
          }
        ]
      })
      |> Floki.text()

    rdnn =
      component
      |> Floki.find("id")
      |> Enum.at(0)
      |> Floki.text()

    icon_filename =
      component
      |> Floki.find("icon[type=\"cached\"][width=\"64\"]")
      |> Floki.text()

    icon_path =
      if icon_filename != "",
        do: Path.join([state.opts[:icons], "64x64", icon_filename]),
        else: nil

    %{
      name: name,
      rdnn: rdnn,
      icon: icon_path
    }
  end
end
