# P920 Edge TTS for GitHub Pages

GitHub Pages cannot run Python. This deployment runs the existing
`reader_app_server.py` on P920 and exposes only its HTTPS reverse proxy to
devices in the same Tailscale tailnet.

## One-time install on P920

Copy this repository to P920, then run:

```bash
cd /path/to/reading_new
bash deploy/p920/install-edge-tts.sh
```

The installer creates a Python virtual environment, installs `edge-tts`,
starts a persistent user service on `127.0.0.1:8767`, and configures
Tailscale Serve on HTTPS port `8443`.

The reader uses:

```text
https://p920.tail1462ad.ts.net:8443/api/tts/edge
```

The endpoint accepts `text`, `voice` (`en-US-AriaNeural` or
`en-US-GuyNeural`), and `speed` (0.6–1.8). It allows the GitHub Pages origin
through CORS, but Tailscale Serve keeps the endpoint private to the tailnet.

## Verify and operate

```bash
systemctl --user status reader-edge-tts.service
tailscale serve status
curl -sS https://p920.tail1462ad.ts.net:8443/api/tts/edge
```

For a browser test, open the GitHub Pages reader from a device signed in to
the same tailnet, hover a paragraph speaker, choose a voice/speed, and play.
If the request cannot connect, confirm Tailscale is connected and that the
tailnet has HTTPS certificates enabled.

Do not use `tailscale funnel` for this service: that would expose an
unauthenticated speech endpoint to the public internet.
