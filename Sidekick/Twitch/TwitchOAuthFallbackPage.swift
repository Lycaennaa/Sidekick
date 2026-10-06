enum TwitchOAuthFallbackPage {
    static let html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy"
          content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'self'">
    <title>Sidekick Twitch sign-in</title>
    </head>
    <body>
    <p id="message">Completing Twitch sign-in…</p>
    <script>
    (() => {
        const message = document.getElementById("message");
        const parameters = window.location.hash.slice(1);
        history.replaceState(null, "", window.location.pathname);
        if (!parameters) {
            message.textContent = "Twitch did not return a token. You may close this window.";
            return;
        }
        const request = new XMLHttpRequest();
        request.open("POST", "/token", true);
        request.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
        request.addEventListener("readystatechange", () => {
            if (request.readyState !== XMLHttpRequest.DONE) return;
            message.textContent = request.status === 200
                ? "Authentication successful. You may close this window."
                : "Authentication failed. You may close this window.";
        });
        request.send(parameters);
    })();
    </script>
    </body>
    </html>
    """
}
