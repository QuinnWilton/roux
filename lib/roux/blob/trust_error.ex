defmodule Roux.Blob.TrustError do
  @moduledoc """
  Raised by `Roux.Blob.open!/1` (and returned by `Roux.Blob.open/1`) for
  a store whose files another user could have written: a root, or its
  `FORMAT` file, that the current OS user does not own or that is
  writable by its group or by everyone.

  A store's entries are decoded as the manifest's are, trusting that
  this tool wrote them for this user; that trust is only as good as the
  store's ownership and permissions. See `Roux.Blob` ("Trust").
  """

  @typedoc """
  Why the path is not trusted: `:not_owner` (another user owns it),
  `:writable_by_others` (group- or world-writable), or `:not_a_directory`
  / `:not_a_regular_file` (the root, or its `FORMAT`, is something else,
  a symbolic `FORMAT` among them).
  """
  @type reason :: :not_owner | :writable_by_others | :not_a_directory | :not_a_regular_file

  @type t :: %__MODULE__{
          path: Path.t(),
          reason: reason(),
          owner: non_neg_integer() | nil,
          user: non_neg_integer() | nil,
          mode: non_neg_integer() | nil
        }

  defexception [:path, :reason, :owner, :user, :mode]

  @impl true
  def message(%__MODULE__{path: path, reason: :not_owner, owner: owner, user: user}) do
    "refusing the blob store at #{path}: it is owned by uid #{owner}, not by this user " <>
      "(uid #{user}); another user could have written what it holds. " <>
      "chown it to this user, or choose another store root"
  end

  def message(%__MODULE__{path: path, reason: :writable_by_others, mode: mode}) do
    "refusing the blob store at #{path}: its mode #{format_mode(mode)} lets its group " <>
      "or everyone write to it, so another user could have written what it holds. " <>
      "Run `chmod go-w #{path}`, or choose another store root"
  end

  def message(%__MODULE__{path: path, reason: :not_a_directory}) do
    "refusing the blob store at #{path}: it is not a directory. Choose another store root"
  end

  def message(%__MODULE__{path: path, reason: :not_a_regular_file}) do
    "refusing the blob store's #{path}: it is not a regular file (a symbolic link, say). " <>
      "Remove the store and let it be created again, or choose another store root"
  end

  defp format_mode(nil), do: "(unknown)"
  defp format_mode(mode), do: "0" <> Integer.to_string(Bitwise.band(mode, 0o7777), 8)
end
