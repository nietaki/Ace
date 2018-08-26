defmodule Ace.HTTP1.Endpoint do
  @moduledoc false

  require Logger

  @packet_timeout 10000

  alias Raxx.{Response, Data, Tail}
  alias Ace.HTTP1

  use GenServer

  @enforce_keys [
    :status,
    :receive_state,
    :socket,
    :worker,
    :monitor,
    :channel,
    :keep_alive
  ]

  defstruct @enforce_keys

  @impl GenServer
  def init(args) do
    {:ok, args}
  end

  @impl GenServer
  def handle_call({:send, channel, parts}, from, state = %{channel: channel}) do
    {outbound, state} =
      Enum.reduce(parts, {"", state}, fn part, {buffer, state} ->
        {:ok, {outbound, next_state}} = send_part(part, state)
        {[buffer, outbound], next_state}
      end)

    Ace.Socket.send(state.socket, outbound)

    case state.status do
      {_, :complete} ->
        GenServer.reply(from, {:ok, channel})
        {:stop, :normal, state}

      {_, _incomplete} ->
        {:reply, {:ok, channel}, state}
    end
  end

  @impl GenServer
  def handle_info({t, s, packet}, state = %{socket: {t, s}}) do
    case HTTP1.Parser.parse(packet, state.receive_state) do
      {:ok, {parts, receive_state}} ->
        Enum.each(parts, fn part ->
          part = normalise_part(part, t)
          send(state.worker, {state.channel, part})
        end)

        :ok = Ace.Socket.set_active(state.socket)
        timeout = if HTTP1.Parser.done?(receive_state), do: :infinity, else: @packet_timeout
        {:noreply, %{state | receive_state: receive_state}, timeout}

      {:error, {:invalid_start_line, _line}} ->
        {:ok, {outbound, new_state}} =
          send_part(Raxx.response(:bad_request) |> Raxx.set_header("content-length", "0"), state)

        Ace.Socket.send(new_state.socket, outbound)
        {:stop, :normal, new_state}

      {:error, {:invalid_header_line, _line}} ->
        {:ok, {outbound, new_state}} =
          send_part(Raxx.response(:bad_request) |> Raxx.set_header("content-length", "0"), state)

        Ace.Socket.send(new_state.socket, outbound)
        {:stop, :normal, new_state}

      {:error, :start_line_too_long} ->
        {:ok, {outbound, new_state}} =
          send_part(Raxx.response(:uri_too_long) |> Raxx.set_header("content-length", "0"), state)

        Ace.Socket.send(state.socket, outbound)
        {:stop, :normal, new_state}

      {:error, :header_line_too_long} ->
        {:ok, {outbound, new_state}} =
          send_part(Raxx.response(:bad_request) |> Raxx.set_header("content-length", "0"), state)

        Ace.Socket.send(state.socket, outbound)
        {:stop, :normal, new_state}
    end
  end

  def handle_info(:timeout, state) do
    {:ok, {outbound, new_state}} =
      send_part(Raxx.response(:request_timeout) |> Raxx.set_header("content-length", "0"), state)

    Ace.Socket.send(state.socket, outbound)
    {:stop, :normal, new_state}
  end

  def handle_info({transport, _socket}, state)
      when transport in [:tcp_closed, :ssl_closed] do
    {:stop, :normal, state}
  end

  # NOTE if any data already sent then canot send 500
  def handle_info(
        {:DOWN, _ref, :process, pid, _reason},
        state = %{worker: pid, status: {_, :response}}
      ) do
    {:ok, {outbound, new_state}} =
      send_part(
        Raxx.response(:internal_server_error) |> Raxx.set_header("content-length", "0"),
        state
      )

    Ace.Socket.send(state.socket, outbound)
    {:stop, :normal, new_state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state = %{worker: pid}) do
    {:stop, reason, state}
  end

  defp normalise_part(request = %{scheme: nil}, :tcp), do: %{request | scheme: :http}
  defp normalise_part(request = %{scheme: nil}, :ssl), do: %{request | scheme: :https}
  defp normalise_part(part, _transport), do: part

  defp send_part(response = %Response{}, state = %{status: {up, :response}}) do
    case Raxx.HTTP1.serialize_response(response, connection: :close) do
      {head, :chunked} ->
        new_status = {up, :chunked_body}
        new_state = %{state | status: new_status}

        {:ok, {head, new_state}}

      {head, {:bytes, content_length}} ->
        new_status = {up, {:body, content_length}}
        new_state = %{state | status: new_status}

        {:ok, {head, new_state}}

      {head, {:complete, body}} ->
        new_status = {up, :complete}
        new_state = %{state | status: new_status}

        {:ok, {[head, body], new_state}}
    end
  end

  defp send_part(data = %Data{}, state = %{status: {up, {:body, remaining}}}) do
    remaining = remaining - :erlang.iolist_size(data.data)
    new_status = {up, {:body, remaining}}
    new_state = %{state | status: new_status}
    {:ok, {[data.data], new_state}}
  end

  defp send_part(%Tail{headers: []}, state = %{status: {up, {:body, 0}}}) do
    new_status = {up, :complete}
    new_state = %{state | status: new_status}
    {:ok, {[], new_state}}
  end

  defp send_part(%Data{data: data}, state = %{status: {_up, :chunked_body}}) do
    chunk = Raxx.HTTP1.serialize_chunk(data)
    {:ok, {[chunk], state}}
  end

  defp send_part(%Tail{headers: []}, state = %{status: {up, :chunked_body}}) do
    chunk = Raxx.HTTP1.serialize_chunk("")
    new_status = {up, :complete}
    new_state = %{state | status: new_status}

    {:ok, {[chunk], new_state}}
  end
end
