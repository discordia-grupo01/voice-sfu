defmodule DiscordiaSignaling.Voice.ReplicaPermissionsTest do
  use ExUnit.Case, async: true

  alias DiscordiaSignaling.Voice.ReplicaPermissions

  test "owner and administrator receive CONNECT without overrides" do
    roles = %{"role" => %{"permissions" => [], "is_everyone" => false}}

    assert ReplicaPermissions.can?(
             ReplicaPermissions.effective(true, ["role"], roles, %{}),
             "CONNECT"
           )

    admin_roles = %{"role" => %{"permissions" => ["ADMINISTRATOR"], "is_everyone" => false}}

    assert ReplicaPermissions.can?(
             ReplicaPermissions.effective(false, ["role"], admin_roles, %{}),
             "CONNECT"
           )
  end

  test "a regular role without CONNECT is denied" do
    roles = %{"role" => %{"permissions" => ["VIEW_CHANNELS"], "is_everyone" => false}}

    refute ReplicaPermissions.can?(
             ReplicaPermissions.effective(false, ["role"], roles, %{}),
             "CONNECT"
           )
  end

  test "role and channel overrides follow everyone then role precedence" do
    roles = %{
      "everyone" => %{"permissions" => ["CONNECT"], "is_everyone" => true},
      "moderator" => %{"permissions" => [], "is_everyone" => false}
    }

    overrides = %{
      "everyone" => %{"allow" => [], "deny" => ["CONNECT"]},
      "moderator" => %{"allow" => ["CONNECT"], "deny" => []}
    }

    assert ReplicaPermissions.can?(
             ReplicaPermissions.effective(false, ["everyone", "moderator"], roles, overrides),
             "CONNECT"
           )
  end

  test "a role override can restore CONNECT denied by @everyone" do
    roles = %{
      "everyone" => %{"permissions" => ["CONNECT"], "is_everyone" => true},
      "member-role" => %{"permissions" => [], "is_everyone" => false}
    }

    overrides = %{
      "everyone" => %{"allow" => [], "deny" => ["CONNECT"]},
      "member-role" => %{"allow" => ["CONNECT"], "deny" => []}
    }

    assert ReplicaPermissions.can?(
             ReplicaPermissions.effective(false, ["everyone", "member-role"], roles, overrides),
             "CONNECT"
           )
  end
end
