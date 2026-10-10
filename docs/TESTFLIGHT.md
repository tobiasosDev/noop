# TestFlight

`Tools/testflight-upload.sh` archives the iOS app, the widget extension, the watch app, and the watch complications, then uploads that archive to TestFlight. After the one-time setup below, the command takes no flags.

`MARKETING_VERSION` in `project.yml` is the marketing version. The build number is a timestamp, `YYYYMMDDHHMM`, so each upload is unique without editing `project.yml`.

## One-time setup

1. **App Store Connect app record.** Create the app for bundle id `<BUNDLE_ID_PREFIX>.noop`. The other targets use `<prefix>.noop.widgets`, `<prefix>.noop.watch`, and `<prefix>.noop.watch.complications`. The upload needs an existing app record for the iOS bundle id.

2. **App Store Connect API key.** Create a key and store the `.p8` at `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` (mode 600). When `ASC_KEY_PATH` is omitted, the script looks in that directory. The key file stays outside the repo. Omit the key ID, issuer, and path together to use the Apple ID already signed in to Xcode.

3. **Distribution certificate and profiles.** Install an Apple Distribution certificate. For manual signing, install an `IOS_APP_STORE` profile for each bundle id above. Name each profile `<PROFILE_PREFIX> <bundle id>`. The default prefix, when the config omits `PROFILE_PREFIX`, is `NOOP AppStore`.

4. **App Group.** Register an App Group for the team and set `APP_GROUP_ID` to it. The script passes that value as an archive build setting. `project.yml` sets `APP_GROUP_ID` at project level (`group.<BUNDLE_ID_PREFIX>.noop.staging`), which overrides an xcconfig, so the command-line setting is what the archive uses.

5. **Local config.** Copy [`Config/testflight.env.example`](../Config/testflight.env.example) to `~/.config/noop/testflight.env`, or to the path in `NOOP_TESTFLIGHT_CONFIG`, and `chmod 600` the file. Lines are `KEY=VALUE`. The script does not execute the file. Blank lines and `#` comments are ignored. Unknown keys fail the run.

   Precedence is command-line flags, then environment variables, then the config file, then the script defaults. If the default config path is missing, behaviour matches a checkout with no config file: `Config/BundleIdSecrets.xcconfig` still supplies the bundle prefix (see [`Config/BundleIdSecrets.example.xcconfig`](../Config/BundleIdSecrets.example.xcconfig)).

   When `BUNDLE_ID_PREFIX` comes from the environment or the config file, the script passes `BUNDLE_ID_PREFIX` and `DEVELOPMENT_TEAM` into the archive. A fresh worktree then does not need `Config/BundleIdSecrets.xcconfig`. `Strand.xcodeproj` is generated and is not committed.

6. **Signing keychain, when the distribution key is not in the login keychain.** Set `SIGNING_KEYCHAIN` to that keychain file and `SIGNING_KEYCHAIN_PASSWORD_SERVICE` to the login-keychain generic-password service that stores its password. Before archiving, the script reads the password and unlocks the keychain for two hours. The password is not printed. Store it with `security add-generic-password -s "<service>" -a "$USER" -w`.

7. **XcodeGen.** `xcodegen` must be on `PATH` (`brew install xcodegen`). The script runs `xcodegen generate` before the archive and fails if the command is missing.

## Deploy

```bash
Tools/testflight-upload.sh --dry-run
Tools/testflight-upload.sh
```

`--dry-run` prints the bundle prefix, team, app group, signing mode, profile prefix, API key ID, issuer ID, whether the key file exists, and the signing keychain path. It does not build, and it does not print the API key or the keychain password.

`--archive-only` archives and skips export and upload. `--manual-profiles` is the same as `EXPORT_SIGNING=manual`.

## Automatic deploys from main

`Tools/testflight-deploy-main.sh` is the unattended entry point. A GitHub push webhook in T3 starts an agent session on this Mac, and that session runs the script once. The Mac has to be on. Nothing is uploaded while it is asleep or off.

The script fetches `origin/main` (override with `NOOP_DEPLOY_REMOTE` and `NOOP_DEPLOY_BRANCH`) into a detached worktree at `~/.noop-deploy/main` (`NOOP_DEPLOY_DIR`). It creates that worktree on first use, attached to the clone that contains the script, and does not check out or clean any other worktree. `Tools/testflight-upload.sh` then runs from the deploy worktree, so the archive is that commit. `build/` and `DerivedData/` in the deploy worktree are left in place. Other untracked files there are removed only when `git clean` would actually delete something.

One deploy holds `~/.noop-deploy/lock`. A second run waits until that deploy finishes, for up to 60 minutes, and then fetches again, so a push that arrives during an upload is deployed afterwards instead of being dropped. A lock whose pid is no longer running is removed and the next run takes it. `NOOP_DEPLOY_REF` checks out a local commit and skips the fetch.

The full SHA of the last successful upload is written to `~/.config/noop/testflight-last-deployed` (`NOOP_DEPLOY_STATE`). That file starts out absent. The same SHA prints `Already deployed <sha>` and exits 0 unless `--force` is set. A failed upload does not update the file. `--dry-run` resolves the commit and passes `--dry-run` to the upload script, so nothing is archived and the state file stays unchanged.

Logs are `~/.noop-deploy/logs/<timestamp>-<shortsha>.log`. On success the script prints `Deployed <shortsha> as <version> (<build>)`.

## Troubleshooting

**`No Accounts`.** Xcode has no Apple ID signed in, and no App Store Connect API key was provided. Set `ASC_KEY_ID` and `ASC_ISSUER_ID`, and set `ASC_KEY_PATH` when the `.p8` is not in `~/.appstoreconnect/private_keys`.

**`Application Group ... is not available`.** The App Group on the archive is not registered to the team, or it does not match the profiles. Register the group and set `APP_GROUP_ID`. The project default `group.<prefix>.noop.staging` is not used once `APP_GROUP_ID` is set in the config.

**`Cloud signing permission error`.** Automatic export asked Apple to sign in the cloud, and the API key or account cannot. Set `EXPORT_SIGNING=manual` and install the `IOS_APP_STORE` profiles named `<PROFILE_PREFIX> <bundle id>`. Manual export does not pass `-allowProvisioningUpdates`.

**`errSecInternalComponent`.** The Apple Distribution private key is in a locked keychain, so `codesign` cannot use it. Set `SIGNING_KEYCHAIN` and `SIGNING_KEYCHAIN_PASSWORD_SERVICE`. The script unlocks that keychain before archiving. A missing login-keychain item fails the script with a message naming the service, before the build starts.

**Missing app record.** App Store Connect has no app for the archived bundle id (`No suitable application records were found` and similar). Create the app record for `<BUNDLE_ID_PREFIX>.noop`. The prefix, the profiles, and that record have to be the same bundle id.

## What stays out of git

Account ids, the API key, and the keychain password do not belong in the repo. Keep them in `~/.config/noop/testflight.env` and in `~/.appstoreconnect/private_keys`. [`Config/testflight.env.example`](../Config/testflight.env.example) has placeholders only.
