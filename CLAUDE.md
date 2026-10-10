# CLAUDE.md

Shared repository guidance lives in [AGENTS.md](AGENTS.md).

@AGENTS.md

## Deploying to TestFlight

After a change is merged and the user wants it on their phone, run `Tools/testflight-upload.sh --dry-run`, then `Tools/testflight-upload.sh`. Report the marketing version and the build number. Settings stay in `~/.config/noop/testflight.env`; see `docs/TESTFLIGHT.md`.
