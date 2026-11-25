# Known issues

Scored Likelihood (1–10) × Impact (1–10). Items under 10 are logged and left alone unless asked.

## Open

None.

## Decided, not changed

- **The dock stays live while signed out.** With the sign-in guard in `materialToFile`, Notes,
  Reminders and Mail then file the composed prompt, which is still useful. Handoffs refuse with
  "Sign in to TerrierGPT first".
- **The Team ID is still in git history** (commits before `Config/Signing.xcconfig`). A Team ID is
  not a secret, so the history is not rewritten.
