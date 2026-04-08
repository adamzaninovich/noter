defmodule Noter.Jobs do
  @moduledoc """
  Runs background jobs (trim, peaks, upload processing) under a Task.Supervisor
  so they survive LiveView disconnects. Progress is broadcast via PubSub.
  """

  require Logger

  alias Noter.Notes.Runner
  alias Noter.{Sessions, Uploads}

  @registry Noter.JobRegistry
  @supervisor Noter.JobSupervisor
  @pubsub Noter.PubSub

  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(session_id))
  end

  def running?(session_id, job_type) do
    Registry.lookup(@registry, {session_id, job_type}) != []
  end

  def start_trim(session, start_seconds, end_seconds) do
    session_id = session.id

    if running?(session_id, :trim) do
      {:error, :already_running}
    else
      session = Sessions.get_session_with_campaign!(session_id)
      {:ok, session} = Sessions.update_session(session, %{status: "trimming"})

      {:ok, pid} =
        Task.Supervisor.start_child(@supervisor, fn ->
          run_trim_task(session, start_seconds, end_seconds)
        end)

      {:ok, pid}
    end
  end

  defp run_trim_task(session, start_seconds, end_seconds) do
    session_id = session.id
    Registry.register(@registry, {session_id, :trim}, [])

    on_progress = fn file, percent ->
      broadcast(session_id, {:trim_progress, file, percent})
    end

    case Uploads.trim_session(session, start_seconds, end_seconds, on_progress) do
      :ok ->
        finish_trim_task(session, session_id, start_seconds, end_seconds)

      error ->
        Logger.error("Trim failed for session #{session_id}: #{inspect(error)}")
        session = Sessions.get_session!(session_id)

        case Sessions.update_session(session, %{status: "trimming"}) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.error("Failed to revert session #{session_id} to trimming: #{inspect(reason)}")
        end

        broadcast(session_id, {:trim_complete, error})
    end
  end

  defp finish_trim_task(_session, session_id, start_seconds, end_seconds) do
    session = Sessions.get_session!(session_id)

    case Sessions.update_session(session, %{
           status: "trimming",
           trim_start_seconds: start_seconds,
           trim_end_seconds: end_seconds
         }) do
      {:ok, updated} ->
        broadcast(session_id, {:trim_complete, :ok, updated})

        # Auto-chain: start transcription after trim completes
        # WAV cleanup is deferred until transcription is durably started
        start_transcription_submit(updated)

      {:error, changeset} ->
        Logger.error("Failed to update session #{session_id} after trim: #{inspect(changeset)}")
        broadcast(session_id, {:trim_complete, {:error, "Failed to update session"}})
    end
  end

  def start_peaks(session) do
    session_id = session.id

    if running?(session_id, :peaks) do
      {:error, :already_running}
    else
      {:ok, pid} =
        Task.Supervisor.start_child(@supervisor, fn ->
          Registry.register(@registry, {session_id, :peaks}, [])

          with {:ok, _peaks_path} <- Uploads.generate_peaks(session_id),
               {:ok, duration} <- Uploads.get_duration(session_id),
               session = Sessions.get_session!(session_id),
               {:ok, updated} <-
                 Sessions.update_session(session, %{duration_seconds: duration}) do
            broadcast(session_id, {:peaks_ready, updated})
          else
            {:error, reason} ->
              Logger.error(
                "Peaks generation failed for session #{session_id}: #{inspect(reason)}"
              )

              broadcast(session_id, {:peaks_failed, reason})
          end
        end)

      {:ok, pid}
    end
  end

  def start_upload_processing(session_params, campaign, zip_path, aac_path, vocab_path) do
    {:ok, pid} =
      Task.Supervisor.start_child(@supervisor, fn ->
        run_upload_processing_task(session_params, campaign, zip_path, aac_path, vocab_path)
      end)

    {:ok, pid}
  end

  defp run_upload_processing_task(session_params, campaign, zip_path, aac_path, vocab_path) do
    case Sessions.create_session(campaign, session_params) do
      {:ok, session} ->
        Registry.register(@registry, {session.id, :upload}, [])
        broadcast_upload(campaign.id, {:processing_status, "Copying audio file..."})

        on_progress = fn status ->
          broadcast_upload(campaign.id, {:processing_status, status})
        end

        case Uploads.process_uploads(
               session,
               campaign,
               zip_path,
               aac_path,
               vocab_path,
               on_progress
             ) do
          {:ok, _renamed} ->
            finish_upload_processing_task(session, campaign)

          {:error, reason} ->
            Logger.error(
              "Upload processing failed for campaign #{campaign.id}: #{inspect(reason)}"
            )

            broadcast_upload(campaign.id, {:upload_processed, {:error, reason}})
        end

      {:error, changeset} ->
        Logger.error("Session creation failed for campaign #{campaign.id}: #{inspect(changeset)}")
        broadcast_upload(campaign.id, {:upload_processed, {:error, changeset}})
    end
  end

  defp finish_upload_processing_task(session, campaign) do
    session = Sessions.get_session!(session.id)

    case Sessions.update_session(session, %{status: "trimming"}) do
      {:ok, updated} ->
        broadcast_upload(campaign.id, {:upload_processed, {:ok, updated}})

      {:error, changeset} ->
        broadcast_upload(campaign.id, {:upload_processed, {:error, changeset}})
    end
  end

  def start_transcription_submit(session) do
    session_id = session.id

    cancel_existing_transcription(session)

    # Set status to transcribing immediately so it survives page refresh
    session = Sessions.get_session!(session_id)
    {:ok, _} = Sessions.update_session(session, %{status: "transcribing"})
    broadcast(session_id, {:transcription_status_changed, "transcribing"})

    Task.Supervisor.start_child(@supervisor, fn ->
      try do
        Registry.register(@registry, {session_id, :transcription_submit}, [])

        last_broadcast = :atomics.new(1, signed: true)
        :atomics.put(last_broadcast, 1, System.monotonic_time(:millisecond))

        on_progress = fn bytes_sent, total_bytes ->
          now = System.monotonic_time(:millisecond)
          last = :atomics.get(last_broadcast, 1)

          if now - last > 250 or bytes_sent == total_bytes do
            :atomics.put(last_broadcast, 1, now)
            broadcast(session_id, {:upload_progress, bytes_sent, total_bytes})
          end
        end

        case Noter.Transcription.submit_job(session_id, on_progress: on_progress) do
          {:ok, job_id} ->
            finish_transcription_submit(session_id, job_id)

          {:error, reason} ->
            revert_to_trimming(session_id)
            broadcast(session_id, {:transcription_submit_failed, reason})
        end
      rescue
        e ->
          Logger.error(
            "Transcription submit crashed for session #{session_id}: #{Exception.message(e)}"
          )

          revert_to_trimming(session_id)
          broadcast(session_id, {:transcription_submit_failed, "unexpected error"})
      end
    end)
  end

  defp finish_transcription_submit(session_id, job_id) do
    # Persist the job_id first — this is the point of no return.
    # Once persisted, reconnect logic can find and reconcile the remote job.
    session = Sessions.get_session!(session_id)

    {:ok, updated} =
      Sessions.update_transcription(session, %{transcription_job_id: job_id})

    # WAV cleanup is safe now: trim source is no longer needed since
    # the transcription job has the audio and the job_id is persisted.
    Uploads.cleanup_wav(session_id)

    try do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Noter.TranscriptionSupervisor,
          {Noter.Transcription.SSEClient, session_id: updated.id, job_id: job_id}
        )

      broadcast(session_id, {:transcription_submitted, job_id})
    rescue
      e ->
        Logger.error(
          "SSE client start failed for session #{session_id}: #{Exception.message(e)}, " <>
            "cancelling remote job #{job_id}"
        )

        Noter.Transcription.cancel_job(job_id)
        revert_to_trimming(session_id)
        broadcast(session_id, {:transcription_submit_failed, "unexpected error"})
    end
  end

  def cancel_existing_transcription(session) do
    if session.transcription_job_id do
      stop_sse_client(session.id)

      case Noter.Transcription.cancel_job(session.transcription_job_id) do
        :ok ->
          :ok

        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to cancel transcription job #{session.transcription_job_id}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  defp stop_sse_client(session_id) do
    case Registry.lookup(Noter.TranscriptionRegistry, session_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  defp revert_to_trimming(session_id) do
    case Sessions.update_session(Sessions.get_session!(session_id), %{status: "trimming"}) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Logger.error("Failed to revert session #{session_id} to trimming: #{inspect(err)}")
    end
  end

  defp topic(session_id), do: "session:#{session_id}:jobs"
  defp upload_topic(campaign_id), do: "campaign:#{campaign_id}:uploads"

  defp broadcast(session_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, topic(session_id), message)
  end

  defp broadcast_upload(campaign_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, upload_topic(campaign_id), message)
  end

  def subscribe_uploads(campaign_id) do
    Phoenix.PubSub.subscribe(@pubsub, upload_topic(campaign_id))
  end

  def get_notes_progress(session_id) do
    Runner.get_progress(session_id)
  end

  def start_notes_generation(session, opts \\ []) do
    session_id = session.id

    if running?(session_id, :notes) do
      {:error, :already_running}
    else
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Noter.NotesSupervisor,
          {Runner, session_id: session_id, pipeline_opts: opts}
        )

      {:ok, :started}
    end
  end
end
