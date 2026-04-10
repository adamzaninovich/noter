defmodule NoterWeb.SessionLive.UploadHelpers do
  @moduledoc """
  Shared upload UI components and helpers for session LiveViews.
  """
  use NoterWeb, :html

  def upload_entries(assigns) do
    ~H"""
    <div :for={entry <- @entries} class="flex items-center gap-3">
      <div class="flex-1">
        <div class="text-sm mb-1">
          <span class="truncate max-w-xs">{entry.client_name}</span>
        </div>
        <progress class="progress progress-primary w-full" value={entry.progress} max="100">
          {entry.progress}%
        </progress>
        <div :for={err <- upload_errors(@upload, entry)} class="text-error text-sm mt-1">
          {upload_error_to_string(err)}
        </div>
      </div>
    </div>
    """
  end

  def upload_error_to_string(:too_large), do: "File is too large"
  def upload_error_to_string(:not_accepted), do: "File type not accepted"
  def upload_error_to_string(:too_many_files), do: "Too many files"
  def upload_error_to_string(err), do: "Upload error: #{inspect(err)}"

  def consume_to_tmp(meta, entry) do
    tmp_path =
      Path.join(System.tmp_dir!(), "noter-upload-#{entry.uuid}#{Path.extname(entry.client_name)}")

    File.cp!(meta.path, tmp_path)
    {:ok, tmp_path}
  end

  def cancel_upload_by_ref(socket, ref, upload_ref) do
    upload_name =
      case upload_ref do
        r when r == socket.assigns.uploads.zip_file.ref -> :zip_file
        r when r == socket.assigns.uploads.vocab_file.ref -> :vocab_file
        _ -> nil
      end

    if upload_name do
      Phoenix.LiveView.cancel_upload(socket, upload_name, ref)
    else
      socket
    end
  end
end
