// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration

const plugin = require("tailwindcss/plugin")

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/emisar_web.ex",
    "../lib/emisar_web/**/*.*ex"
  ],
  theme: {
    extend: {
      colors: {
        // emisar brand accent — the emerald gate. `brand-400` is the exact
        // logo green (#36E6A5, see images/emisar-icon.svg); `brand-500` is the
        // button resting fill (dark text reads on it) that hovers up to the
        // logo green. The marketing site uses this as its accent; semantic
        // pass/pending/deny chips stay on emerald/amber/rose via `<.chip>`.
        brand: {
          50: "#e7fdf4",
          100: "#c8fae5",
          200: "#95f3cd",
          300: "#57ecb2",
          400: "#36e6a5",
          500: "#14cf8d",
          600: "#05a974",
          700: "#07835b",
          800: "#0a6749",
          900: "#0a543c",
          950: "#032f22",
        },
      }
    },
  },
  plugins: [
    require("@tailwindcss/forms"),
    require("@tailwindcss/container-queries"),
    // Allows prefixing tailwind classes with LiveView classes to add rules
    // only when LiveView classes are applied, for example:
    //
    //     <div class="phx-click-loading:animate-ping">
    //
    plugin(({addVariant}) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({addVariant}) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({addVariant}) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),
  ]
}
