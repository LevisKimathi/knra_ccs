defmodule Knra.Time do
  @moduledoc """
  Time helpers. The system records UTC and displays East Africa Time (UTC+3,
  no daylight saving), so a fixed offset is used instead of a tz database.
  """

  @offset_seconds 3 * 3600
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  def now, do: DateTime.utc_now(:second)

  def to_local(%DateTime{} = dt), do: DateTime.add(dt, @offset_seconds, :second) |> DateTime.to_naive()

  def today, do: now() |> to_local() |> NaiveDateTime.to_date()

  def year, do: today().year

  @doc "UTC instant at which the given Nairobi calendar date starts."
  def start_of_day_utc(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(-@offset_seconds, :second)
  end

  @doc "Formats a UTC datetime as `05 Aug 2026 10:12` in Nairobi time."
  def format(nil), do: "—"

  def format(%DateTime{} = dt) do
    l = to_local(dt)
    "#{pad(l.day)} #{Enum.at(@months, l.month - 1)} #{l.year} #{pad(l.hour)}:#{pad(l.minute)}"
  end

  def format_date(nil), do: "—"
  def format_date(%Date{} = d), do: "#{pad(d.day)} #{Enum.at(@months, d.month - 1)} #{d.year}"

  def format_time(nil), do: "—"

  def format_time(%DateTime{} = dt) do
    l = to_local(dt)
    "#{pad(l.hour)}:#{pad(l.minute)}"
  end

  @doc "ISO-8601 with the +03:00 offset, as KenTrade expects."
  def iso_local(%DateTime{} = dt) do
    l = to_local(dt)
    NaiveDateTime.to_iso8601(NaiveDateTime.truncate(l, :second)) <> "+03:00"
  end

  @doc "Human wait time: `4 min`, `2 h 05 min`, `3 d`."
  def ago(nil), do: "—"

  def ago(%DateTime{} = dt) do
    mins = max(div(DateTime.diff(now(), dt, :second), 60), 0)

    cond do
      mins < 60 -> "#{mins} min"
      mins < 1440 -> "#{div(mins, 60)} h #{pad(rem(mins, 60))} min"
      true -> "#{div(mins, 1440)} d"
    end
  end

  def minutes_since(%DateTime{} = dt), do: div(DateTime.diff(now(), dt, :second), 60)

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
