defmodule DiscordiaSignaling.Voice.ReplicaPermissions do
  @all ~w(VIEW_CHANNELS SEND_MESSAGES MANAGE_CHANNELS MANAGE_ROLES KICK_MEMBERS BAN_MEMBERS MANAGE_SERVER ADMINISTRATOR CREATE_INVITE MANAGE_MESSAGES MENTION_EVERYONE ADD_REACTIONS CONNECT)

  def effective(owner?, role_ids, roles, overrides) do
    base =
      role_ids
      |> Enum.flat_map(fn id -> normalize_permissions(get_in(roles, [id, "permissions"])) end)
      |> MapSet.new()

    if owner? or MapSet.member?(base, "ADMINISTRATOR") do
      MapSet.new(@all)
    else
      apply_overrides(base, role_ids, roles, overrides)
    end
  end

  def can?(permissions, name), do: MapSet.member?(permissions, name)

  defp apply_overrides(base, role_ids, roles, overrides) do
    {everyone, other} =
      Enum.split_with(role_ids, fn id -> get_in(roles, [id, "is_everyone"]) == true end)

    after_everyone =
      Enum.reduce(everyone, base, fn id, acc -> apply_one(acc, Map.get(overrides, id)) end)

    {allow, deny} =
      Enum.reduce(other, {[], []}, fn id, {allows, denies} ->
        case Map.get(overrides, id) do
          %{"allow" => allow, "deny" => deny} ->
            {normalize_permissions(allow) ++ allows, normalize_permissions(deny) ++ denies}

          _ ->
            {allows, denies}
        end
      end)

    after_everyone |> MapSet.difference(MapSet.new(deny)) |> MapSet.union(MapSet.new(allow))
  end

  defp apply_one(set, %{"allow" => allow, "deny" => deny}) do
    set
    |> MapSet.difference(MapSet.new(normalize_permissions(deny)))
    |> MapSet.union(MapSet.new(normalize_permissions(allow)))
  end

  defp apply_one(set, _), do: set

  defp normalize_permissions(permissions) when is_list(permissions) do
    Enum.filter(permissions, &is_binary/1)
  end

  defp normalize_permissions(permissions) when is_binary(permissions) do
    case Jason.decode(permissions) do
      {:ok, decoded} -> normalize_permissions(decoded)
      _ -> []
    end
  end

  defp normalize_permissions(_permissions), do: []
end
