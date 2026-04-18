defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            window.SymphonyHooks = window.SymphonyHooks || {};
            window.SymphonyHooks.SessionShortcuts = {
              mounted: function () {
                var el = this.el;

                this._handler = function (event) {
                  if (event.defaultPrevented) return;
                  if (event.metaKey || event.ctrlKey || event.altKey) return;
                  if (event.target && ["INPUT", "TEXTAREA", "SELECT"].includes(event.target.tagName)) return;

                  var key = String(event.key || "").toLowerCase();

                  if (key === "c") {
                    var checkin = el.dataset.checkinUrl;
                    if (checkin) window.location.assign(checkin);
                    return;
                  }

                  if (key === "d") {
                    var debug = el.dataset.debugUrl;
                    if (debug) window.location.assign(debug);
                    return;
                  }

                  if (key === "v") {
                    var isRaw = new URL(window.location.href).searchParams.get("view") === "raw";
                    var nextUrl = isRaw ? el.dataset.debugCondensedUrl : el.dataset.debugRawUrl;
                    if (nextUrl) window.location.assign(nextUrl);
                  }
                };

                window.addEventListener("keydown", this._handler);
              },
              destroyed: function () {
                if (this._handler) window.removeEventListener("keydown", this._handler);
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: window.SymphonyHooks
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
