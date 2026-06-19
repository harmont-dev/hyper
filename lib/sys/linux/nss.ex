defmodule Sys.Linux.Nss do
  @moduledoc "NSS (Name Service Switch) utilities — queries users and groups via `getent`."

  defmodule Passwd do
    @moduledoc "The passwd database (`getent passwd`)."
    @getent_db "passwd"

    defmodule Spec do
      @moduledoc "A parsed `passwd` entry."

      @type t :: %__MODULE__{
              name: String.t(),
              password: String.t(),
              uid: non_neg_integer(),
              gid: non_neg_integer(),
              gecos: String.t(),
              home_dir: Path.t(),
              shell: Path.t()
            }
      defstruct [:name, :password, :uid, :gid, :gecos, :home_dir, :shell]
    end

    @doc "Queries the system for passwd entries."
    @spec entries ::
            {:ok, [Spec.t()]}
            | {:error,
               {:getent_failed, non_neg_integer()} | :getent_unavailable | :invalid_format}
    def entries do
      with {:ok, output} <- Sys.Linux.Nss.getent(@getent_db) do
        output
        |> String.split("\n", trim: true)
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
          case parse(line) do
            {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
      end
    end

    # passwd line: name:password:uid:gid:gecos:home_dir:shell
    @spec parse(String.t()) :: {:ok, Spec.t()} | {:error, :invalid_format}
    defp parse(line) do
      with [name, password, uid_str, gid_str, gecos, home_dir, shell] <- String.split(line, ":"),
           {uid, ""} <- Integer.parse(uid_str),
           {gid, ""} <- Integer.parse(gid_str) do
        {:ok,
         %Spec{
           name: name,
           password: password,
           uid: uid,
           gid: gid,
           gecos: gecos,
           home_dir: home_dir,
           shell: shell
         }}
      else
        _ -> {:error, :invalid_format}
      end
    end
  end

  defmodule Group do
    @moduledoc "The group database (`getent group`)."
    @getent_db "group"

    defmodule Spec do
      @moduledoc "A parsed `group` entry."

      @type t :: %__MODULE__{
              name: String.t(),
              password: String.t(),
              gid: non_neg_integer(),
              members: [String.t()]
            }
      defstruct [:name, :password, :gid, :members]
    end

    @doc "Queries the system for group entries."
    @spec entries ::
            {:ok, [Spec.t()]}
            | {:error,
               {:getent_failed, non_neg_integer()} | :getent_unavailable | :invalid_format}
    def entries do
      with {:ok, output} <- Sys.Linux.Nss.getent(@getent_db) do
        output
        |> String.split("\n", trim: true)
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
          case parse(line) do
            {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
      end
    end

    # group line: name:password:gid:member1,member2,...
    @spec parse(String.t()) :: {:ok, Spec.t()} | {:error, :invalid_format}
    defp parse(line) do
      with [name, password, gid_str, members] <- String.split(line, ":", parts: 4),
           {gid, ""} <- Integer.parse(gid_str) do
        {:ok,
         %Spec{
           name: name,
           password: password,
           gid: gid,
           members: String.split(members, ",", trim: true)
         }}
      else
        _ -> {:error, :invalid_format}
      end
    end
  end

  @doc "Run `getent <database>` and return its raw output."
  @spec getent(String.t()) ::
          {:ok, binary()} | {:error, {:getent_failed, non_neg_integer()} | :getent_unavailable}
  def getent(database) do
    case System.cmd("getent", [database], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, code} -> {:error, {:getent_failed, code}}
    end
  rescue
    _ -> {:error, :getent_unavailable}
  end
end
