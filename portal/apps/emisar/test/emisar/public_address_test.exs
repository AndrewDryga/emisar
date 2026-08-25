defmodule Emisar.PublicAddressTest do
  use ExUnit.Case, async: true
  alias Emisar.PublicAddress

  describe "global_unicast?/1" do
    test "refuses IPv4 special-purpose ranges" do
      for address <- [
            {0, 0, 0, 0},
            {10, 1, 1, 1},
            {100, 100, 100, 200},
            {127, 0, 0, 1},
            {169, 254, 169, 254},
            {172, 20, 1, 1},
            {192, 0, 0, 1},
            {192, 0, 2, 5},
            {192, 88, 99, 2},
            {192, 168, 1, 1},
            {198, 18, 0, 1},
            {198, 51, 100, 7},
            {203, 0, 113, 7},
            {224, 0, 0, 1},
            {255, 255, 255, 255}
          ] do
        refute PublicAddress.global_unicast?(address), "#{:inet.ntoa(address)} was allowed"
      end
    end

    test "refuses IPv6 special-purpose and transition ranges" do
      for address <- [
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFF02, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808},
            {0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808},
            {0x64, 0xFF9B, 1, 0, 0, 0, 0x0808, 0x0808},
            {0x2002, 0x0808, 0x0808, 0, 0, 0, 0, 1},
            {0x2001, 0x0002, 0, 0, 0, 0, 0, 1},
            {0x2001, 0x0020, 0, 0, 0, 0, 0, 1},
            {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
            {0x2C10, 0, 0, 0, 0, 0, 0, 1},
            {0x2D00, 0, 0, 0, 0, 0, 0, 1},
            {0x3000, 0, 0, 0, 0, 0, 0, 1},
            {0x3F00, 0, 0, 0, 0, 0, 0, 1},
            {0x3FF0, 0, 0, 0, 0, 0, 0, 1},
            {0x3FFE, 0, 0, 0, 0, 0, 0, 1},
            {0x3FFF, 0, 0, 0, 0, 0, 0, 1}
          ] do
        refute PublicAddress.global_unicast?(address), "#{:inet.ntoa(address)} was allowed"
      end
    end

    test "allows ordinary public addresses" do
      assert PublicAddress.global_unicast?({93, 184, 216, 34})
      assert PublicAddress.global_unicast?({8, 8, 8, 8})
      assert PublicAddress.global_unicast?({0x2606, 0x2800, 0, 0, 0, 0, 0, 1})
      assert PublicAddress.global_unicast?({0x2A00, 0x1450, 0, 0, 0, 0, 0, 1})
      assert PublicAddress.global_unicast?({0x2C0F, 0, 0, 0, 0, 0, 0, 1})
      assert PublicAddress.global_unicast?({0x2620, 0, 0, 0, 0, 0, 0, 1})
    end

    test "fails closed for a malformed address" do
      refute PublicAddress.global_unicast?({127, 0, 0})
      refute PublicAddress.global_unicast?("8.8.8.8")
    end
  end
end
