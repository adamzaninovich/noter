defmodule Noter.Jobs do
  @moduledoc """
  Runs background jobs (trim, peaks, upload processing) under a Task.Supervisor
  so they survive LiveView disconnects. Progress is broadcast via PubSub.
  """

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
        broadcast(session_id, {:trim_complete, error})
    end
  end

  defp finish_trim_task(_session, session_id, start_seconds, end_seconds) do
    session = Sessions.get_session!(session_id)

    case Sessions.update_session(session, %{
           status: "trimmed",
           trim_start_seconds: start_seconds,
           trim_end_seconds: end_seconds
         }) do
      {:ok, updated} ->
        Uploads.cleanup_wav(session_id)
        broadcast(session_id, {:trim_complete, :ok, updated})

      {:error, _changeset} ->
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
            broadcast_upload(campaign.id, {:upload_processed, {:error, reason}})
        end

      {:error, changeset} ->
        broadcast_upload(campaign.id, {:upload_processed, {:error, changeset}})
    end
  end

  defp finish_upload_processing_task(session, campaign) do
    session = Sessions.get_session!(session.id)

    case Sessions.update_session(session, %{status: "uploaded"}) do
      {:ok, _} ->
        broadcast_upload(campaign.id, {:upload_processed, {:ok, session}})

      {:error, changeset} ->
        broadcast_upload(campaign.id, {:upload_processed, {:error, changeset}})
    end
  end

  def start_transcription_submit(session) do
    session_id = session.id

    cancel_existing_transcription(session)

    Task.Supervisor.start_child(@supervisor, fn ->
      case Noter.Transcription.submit_job(session_id) do
        {:ok, job_id} ->
          session = Sessions.get_session!(session_id)

          {:ok, updated} =
            Sessions.update_transcription(session, %{
              status: "transcribing",
              transcription_job_id: job_id
            })

          {:ok, _pid} =
            DynamicSupervisor.start_child(
              Noter.TranscriptionSupervisor,
              {Noter.Transcription.SSEClient, session_id: updated.id, job_id: job_id}
            )

          broadcast(session_id, {:transcription_submitted, job_id})

        {:error, reason} ->
          broadcast(session_id, {:transcription_submit_failed, reason})
      end
    end)
  end

  def cancel_existing_transcription(session) do
    if session.transcription_job_id do
      stop_sse_client(session.id)
      Noter.Transcription.cancel_job(session.transcription_job_id)
    end

    :ok
  end

  defp stop_sse_client(session_id) do
    case Registry.lookup(Noter.TranscriptionRegistry, session_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
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
end
