defmodule KnraWeb.Reporting.Base do
  @moduledoc "Shared filter handling for the Reporting LiveViews (filters live in the URL)."

  defmacro __using__(path: path) do
    quote do
      on_mount {KnraWeb.LiveHooks, {:authorize, :view_reports}}

      import KnraWeb.ReportComponents

      @impl true
      def handle_params(params, _uri, socket) do
        filters = Knra.Reporting.filters(params)
        lanes = Knra.Devices.list_lanes()

        {:noreply,
         socket
         |> assign(filters: filters, lanes: lanes)
         |> assign(:lane_name, Enum.find_value(lanes, &(&1.id == filters.lane_id && &1.name)))
         |> load_report()}
      end

      @impl true
      def handle_event("filter", params, socket) do
        query =
          params
          |> Map.take(~w(from to lane_id))
          |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
          |> URI.encode_query()

        {:noreply, push_patch(socket, to: unquote(path) <> "?" <> query)}
      end

      def handle_event("range", %{"from" => from, "to" => to}, socket) do
        params =
          socket.assigns.filters
          |> Knra.Reporting.to_params()
          |> Map.merge(%{"from" => from, "to" => to})

        {:noreply, push_patch(socket, to: unquote(path) <> "?" <> URI.encode_query(params))}
      end

      @impl true
      def handle_info(_, socket), do: {:noreply, socket}
    end
  end
end
