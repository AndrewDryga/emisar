defmodule Emisar.PublicAddress do
  @moduledoc """
  The shared outbound-network allow policy for caller- or tenant-selected hosts.

  Only ordinary global-unicast IPv4 and IPv6 addresses pass. Special-purpose,
  transition, documentation, local, multicast, and reserved ranges fail closed.
  DNS callers still own resolution and connection pinning; this module judges
  only the exact address they are about to dial.
  """

  @doc "True only for an IP address in the conservative global-unicast allow set."
  @spec global_unicast?(:inet.ip_address()) :: boolean()
  def global_unicast?({0, _, _, _}), do: false
  def global_unicast?({10, _, _, _}), do: false
  def global_unicast?({100, b, _, _}) when b in 64..127, do: false
  def global_unicast?({127, _, _, _}), do: false
  def global_unicast?({169, 254, _, _}), do: false
  def global_unicast?({172, b, _, _}) when b in 16..31, do: false
  def global_unicast?({192, 0, 0, _}), do: false
  def global_unicast?({192, 0, 2, _}), do: false
  def global_unicast?({192, 88, 99, _}), do: false
  def global_unicast?({192, 168, _, _}), do: false
  def global_unicast?({198, b, _, _}) when b in 18..19, do: false
  def global_unicast?({198, 51, 100, _}), do: false
  def global_unicast?({203, 0, 113, _}), do: false
  def global_unicast?({a, _, _, _}) when a >= 224, do: false
  def global_unicast?({_, _, _, _}), do: true

  # IPv4-mapped, NAT64, and 6to4 wrappers are special-purpose address space,
  # not a reason to trust the IPv4 address embedded inside them.
  def global_unicast?({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: false
  def global_unicast?({0x64, 0xFF9B, _, _, _, _, _, _}), do: false
  def global_unicast?({0x2002, _, _, _, _, _, _, _}), do: false

  # 2001::/23 holds IETF protocol assignments, including benchmarking,
  # ORCHIDv2, and Teredo. 2001:db8::/32 is the separate documentation range.
  def global_unicast?({0x2001, b, _, _, _, _, _, _}) when b <= 0x01FF, do: false
  def global_unicast?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: false

  # IANA's continuous reserved upper tail begins at 2c10::; 2c00::/12 spans
  # first hextets 2c00 through 2c0f and is the last RIR allocation before it.
  def global_unicast?({h, _, _, _, _, _, _, _}) when h >= 0x2C10, do: false

  def global_unicast?({h, _, _, _, _, _, _, _}) when h >= 0x2000 and h <= 0x2C0F,
    do: true

  def global_unicast?({_, _, _, _, _, _, _, _}), do: false
  def global_unicast?(_address), do: false
end
