defmodule DarkwoodWeb.IncidentShowLive do
  use DarkwoodWeb, :live_view
  import DarkwoodWeb.IncidentComponents, only: [aggregation_badge: 1]
  alias Darkwood.Incidents
  alias DarkwoodWeb.Presence

  @statuses ~w(investigating identified mitigated resolved)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Incidents.get_incident_with_events(id) do
      nil ->
        {:ok, socket |> put_flash(:error, "Incident not found.") |> push_navigate(to: ~p"/")}

      incident ->
        annotations = Incidents.list_annotations(incident)

        socket =
          socket
          |> assign(:page_title, incident.title)
          |> assign(:incident, incident)
          |> assign(:statuses, @statuses)
          |> assign(:users, [])
          |> assign(:annotation_form, annotation_form())
          |> assign(:event_annotation_form, annotation_form())
          |> stream(:events, incident.events)
          |> stream(:annotations, annotations)

        if connected?(socket) do
          :ok = Incidents.subscribe(incident.id)

          presence_key = "#{socket.assigns.client_id}:#{socket.id || System.unique_integer([:positive])}"

          {:ok, _} =
            Presence.track(self(), Incidents.topic(incident.id), presence_key, %{
              display_name: socket.assigns.display_name,
              joined_at: DateTime.utc_now()
            })

          {:ok, assign(socket, :users, present_users(incident.id))}
        else
          {:ok, socket}
        end
    end
  rescue
    Ecto.Query.CastError ->
      {:ok, socket |> put_flash(:error, "Incident not found.") |> push_navigate(to: ~p"/")}
  end

  @impl true
  def handle_event("annotate", %{"annotation" => params}, socket),
    do: save_annotation(params, :annotation_form, socket)

  def handle_event("annotate_event", %{"annotation" => params}, socket),
    do: save_annotation(params, :event_annotation_form, socket)

  def handle_event("status", %{"status" => status}, socket) when status in @statuses do
    case Incidents.update_incident_status(socket.assigns.incident, status) do
      {:ok, incident} ->
        {:noreply, assign(socket, :incident, %{socket.assigns.incident | status: incident.status})}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Status could not be updated.")}
    end
  end

  def handle_event("status", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid status.")}

  @impl true
  def handle_info({:annotation_created, _annotation}, socket),
    do: {:noreply, reload_annotations(socket)}

  def handle_info({:event_created, event}, socket) do
    # Incremental fast path for the common in-order case; re-stream sorted
    # when a late/out-of-order event arrives so the timeline stays chronological.
    events = socket.assigns.incident.events

    if in_order_append?(events, event) do
      socket =
        socket
        |> stream_insert(:events, event, at: -1)
        |> assign(:incident, %{socket.assigns.incident | events: events ++ [event]})

      {:noreply, socket}
    else
      updated = sort_events_asc(events ++ [event])

      socket =
        socket
        |> stream(:events, updated, reset: true)
        |> assign(:incident, %{socket.assigns.incident | events: updated})

      {:noreply, socket}
    end
  end

  def handle_info({:event_updated, event}, socket) do
    # Aggregation only rewrites metadata; occurred_at never moves, so an
    # in-place stream update preserves chronological order.
    events =
      Enum.map(socket.assigns.incident.events, fn e ->
        if e.id == event.id, do: event, else: e
      end)

    socket =
      socket
      |> stream_insert(:events, event)
      |> assign(:incident, %{socket.assigns.incident | events: events})

    {:noreply, socket}
  end

  def handle_info({:incident_updated, incident}, socket),
    do: {:noreply, assign(socket, :incident, %{socket.assigns.incident | status: incident.status})}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, assign(socket, :users, present_users(socket.assigns.incident.id))}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp save_annotation(params, form_key, socket) do
    attrs = Map.put(params, "author_name", socket.assigns.display_name)

    case Incidents.create_annotation(socket.assigns.incident, attrs) do
      {:ok, _annotation} ->
        {:noreply, socket |> assign(form_key, annotation_form()) |> reload_annotations()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form_key, to_form(Map.put(changeset, :action, :insert)))}

      {:error, :event_not_in_incident} ->
        {:noreply, put_flash(socket, :error, "Selected event does not belong to this incident.")}
    end
  end

  defp reload_annotations(socket),
    do:
      stream(socket, :annotations, Incidents.list_annotations(socket.assigns.incident),
        reset: true
      )

  defp annotation_form, do: Incidents.change_annotation() |> to_form()

  defp present_users(id) do
    Incidents.topic(id)
    |> Presence.list()
    |> Enum.map(fn {_key, %{metas: metas}} -> List.first(metas) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.display_name)
    |> Enum.sort_by(& &1.display_name)
  end

  # Stable DOM id per display name. The raw `phx_ref` belongs to a single
  # Presence meta, so it flips whenever the winning tab changes after the
  # `uniq_by display_name` collapse above — causing needless DOM churn.
  defp presence_id(display_name) when is_binary(display_name) do
    :erlang.phash2(display_name) |> Integer.to_string()
  end

  defp presence_id(_), do: "unknown"

  defp in_order_append?([], _event), do: true

  defp in_order_append?(events, event) do
    last = List.last(events)

    case DateTime.compare(event.occurred_at, last.occurred_at) do
      :lt -> false
      _ -> true
    end
  end

  defp sort_events_asc(events) do
    Enum.sort(events, fn a, b ->
      case DateTime.compare(a.occurred_at, b.occurred_at) do
        :lt -> true
        :gt -> false
        :eq -> a.id <= b.id
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <.link navigate={~p"/"} class="text-sm text-slate-400 hover:text-white">← All incidents</.link>
        <header id="incident-header" class="rounded-2xl border border-slate-800 bg-slate-950 p-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p class="text-xs uppercase tracking-[0.25em] text-amber-400">
                {@incident.severity} incident
              </p><h1 class="mt-2 text-3xl font-semibold text-white">{@incident.title}</h1><p
                :if={@incident.summary}
                class="mt-3 max-w-3xl text-slate-400"
              >
                {@incident.summary}
              </p>
            </div><span
              id="incident-status"
              class="rounded-full border border-amber-700 bg-amber-950 px-4 py-2 text-sm font-semibold uppercase text-amber-300"
            >{@incident.status}</span>
          </div>
          <div id="status-controls" class="mt-6 flex flex-wrap gap-2">
            <button
              :for={status <- @statuses}
              id={"status-#{status}"}
              phx-click="status"
              phx-value-status={status}
              class={[
                "rounded-lg border px-3 py-2 text-sm capitalize transition",
                if(to_string(@incident.status) == status,
                  do: "border-amber-400 bg-amber-400 text-slate-950",
                  else: "border-slate-700 text-slate-300 hover:border-slate-500"
                )
              ]}
            >{status}</button>
          </div>
        </header>

        <section id="presence" class="rounded-xl border border-slate-800 bg-slate-950 p-5">
          <h2 class="text-xs font-semibold uppercase tracking-wider text-slate-500">
            Connected responders
          </h2><div class="mt-3 flex flex-wrap gap-2">
            <span
              :for={user <- @users}
              id={"presence-#{presence_id(user.display_name)}"}
              class="rounded-full bg-emerald-950 px-3 py-1 text-sm text-emerald-300"
            >● {user.display_name}</span><span :if={@users == []} class="text-sm text-slate-500">Connecting…</span>
          </div>
        </section>

        <section>
          <h2 class="text-lg font-semibold text-white">Event timeline</h2><div
            id="event-timeline"
            phx-update="stream"
            class="mt-4 space-y-3"
          >
            <article
              :for={{id, event} <- @streams.events}
              id={id}
              class="grid gap-3 rounded-xl border border-slate-800 bg-slate-950 p-5 sm:grid-cols-[9rem_1fr]"
            >
              <time class="font-mono text-xs text-slate-500">{Calendar.strftime(
                event.occurred_at,
                "%H:%M:%S.%f"
              )}</time><div>
                <div class="flex flex-wrap items-center gap-2 text-xs uppercase tracking-wider">
                  <span class="text-amber-400">{event.kind}</span><span class="text-slate-500">{event.level}</span><.aggregation_badge event={event} />
                </div><p class="mt-2 text-slate-100">{event.message}</p><pre class="mt-3 overflow-x-auto whitespace-pre-wrap text-xs text-slate-500">{Jason.encode!(event.metadata, pretty: true)}</pre>
              </div>
            </article>
          </div>
        </section>

        <section class="grid gap-5 lg:grid-cols-2">
          <div class="rounded-xl border border-slate-800 bg-slate-950 p-5">
            <h2 class="font-semibold text-white">Incident annotation</h2><.form
              for={@annotation_form}
              id="annotation-form"
              phx-submit="annotate"
              class="mt-4 space-y-3"
            >
              <.input
                id="incident-annotation-body"
                field={@annotation_form[:body]}
                type="textarea"
                label="Note"
                maxlength="2000"
              /><button
                id="annotation-submit"
                class="rounded-lg bg-amber-400 px-4 py-2 font-semibold text-slate-950"
              >Add annotation</button>
            </.form>
          </div>
          <div class="rounded-xl border border-slate-800 bg-slate-950 p-5">
            <h2 class="font-semibold text-white">Annotate an event</h2><.form
              for={@event_annotation_form}
              id="event-annotation-form"
              phx-submit="annotate_event"
              class="mt-4 space-y-3"
            >
              <.input
                field={@event_annotation_form[:event_id]}
                type="select"
                label="Event"
                prompt="Choose an event"
                options={Enum.map(@incident.events, &{&1.message, &1.id})}
              /><.input
                id="event-annotation-body"
                field={@event_annotation_form[:body]}
                type="textarea"
                label="Note"
                maxlength="2000"
              /><button
                id="event-annotation-submit"
                class="rounded-lg bg-amber-400 px-4 py-2 font-semibold text-slate-950"
              >Annotate event</button>
            </.form>
          </div>
        </section>

        <section>
          <h2 class="text-lg font-semibold text-white">Annotations</h2><div
            id="annotations"
            phx-update="stream"
            class="mt-4 space-y-3"
          >
            <p id="annotations-empty" class="hidden only:block text-slate-500">No annotations yet.</p><article
              :for={{id, annotation} <- @streams.annotations}
              id={id}
              class="rounded-xl border border-slate-800 bg-slate-950 p-4"
            >
              <div class="flex justify-between gap-4 text-xs text-slate-500">
                <span>{annotation.author_name}<span :if={annotation.event}> · event {annotation.event.kind}</span></span><time>{Calendar.strftime(
                  annotation.inserted_at,
                  "%H:%M UTC"
                )}</time>
              </div><p class="mt-2 whitespace-pre-wrap text-slate-200">{annotation.body}</p>
            </article>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
