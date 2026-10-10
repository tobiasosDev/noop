# CLAUDE.md

Shared repository guidance lives in [AGENTS.md](AGENTS.md).

@AGENTS.md

## Deploying to TestFlight

After a change is merged and the user wants it on their phone, run `Tools/testflight-upload.sh --dry-run`, then `Tools/testflight-upload.sh`. Report the marketing version and the build number. Settings stay in `~/.config/noop/testflight.env`; see `docs/TESTFLIGHT.md`.

When a GitHub push webhook wakes you, run `Tools/testflight-deploy-main.sh` once. Report its summary line, `Deployed <shortsha> as <version> (<build>)`, or `Already deployed <sha>` when that commit is already uploaded. The script waits for a deploy already in progress, then publishes the newest `main`. Do not start a second upload beside it.
