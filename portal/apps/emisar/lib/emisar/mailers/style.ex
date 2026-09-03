defmodule Emisar.Mailers.Style do
  @moduledoc "Shared colors, font stack, and inbox-preview padding for HTML email."

  def ground, do: "#09090b"
  def surface, do: "#111114"
  def hairline, do: "#27272a"
  def ink, do: "#fafafa"
  def ink_soft, do: "#a1a1aa"
  def brand, do: "#8df0ca"
  def rose, do: "#fda4af"
  def amber, do: "#fddf7f"

  def font,
    do: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"

  def preview_pad, do: String.duplicate("&#847;&zwnj;&nbsp;", 40)
end
