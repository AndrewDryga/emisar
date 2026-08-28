defmodule EmisarWeb.Gettext do
  @moduledoc """
  Kept deliberately, with zero translations and one English catalog: this is
  not idle scaffolding. `CoreComponents.translate_error/1` routes EVERY
  changeset error through `dngettext`, so this layer does the `%{count}`
  interpolation and plural selection for every form error in the product.
  Removing it means hand-rolling both to drop a dependency Phoenix ships by
  default.

  Internationalization with a gettext-based API.

  By using [Gettext](https://hexdocs.pm/gettext), your module compiles translations
  that you can use in your application. To use this Gettext backend module,
  call `use Gettext` and pass it as an option:

      use Gettext, backend: EmisarWeb.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://hexdocs.pm/gettext) for detailed usage.
  """
  use Gettext.Backend, otp_app: :emisar_web
end
