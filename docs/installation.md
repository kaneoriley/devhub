# Local installation and upgrades

The application menu's **Check for Updates…** opens `InstallationView`. `Installation` reads the build identity, persists the chosen Applications directory in UserDefaults, checks the installed bundle, builds, and stages its replacement. This is a local-source workflow, with no release feed, version-number comparison, or automatic Git pull.

## Identity rules

Both build time and runtime use `Sources/BuildIdentity/BuildIdentity.swift`:

1. Run `git ls-files --cached --others --exclude-standard -z` in the checkout.
2. Deduplicate and sort paths. Hash each UTF-8 path followed by NUL and the SHA-256 digest of its current contents. Missing tracked files contribute the empty-content digest.
3. SHA-256 that stream. Git staging and commits alone do not change it; changed, deleted, or new non-ignored files do. Ignored build output is excluded.

`BuildInfoTool` embeds this fingerprint, the checkout's absolute path, its Git commit, and whether `git status --porcelain=v1 --untracked-files=normal` reports a modified working tree in `Contents/Resources/build-info.plist`. The content fingerprint determines local upgrade availability and local-source prompts; the commit and dirty flag are informational. Committing an installed working tree or creating an empty commit must not offer a rebuild when the fingerprint matches. The UI shows installed and checkout commits, marking modified trees, and distinguishes actual source changes at the same commit from changes at a different commit. `build.sh` checks identity before and after compilation and rejects a changing checkout. Do not replace the fingerprint with `git rev-parse HEAD` alone: that would miss local edits.

An absent installation offers Install. A matching source hash disables Upgrade, regardless of commit or dirty-state differences. A differing hash or missing installed identity enables Upgrade, provided the source checkout is readable. A missing checkout disables both actions and explains the source issue. There is no machine-specific Applications path in the repository.

## Fetching and startup prompts

`GitSourceUpdates.swift` reads the current symbolic branch and its upstream with `for-each-ref`'s upstream atoms. Opening the installation window and Check Again fetch only that configured remote branch into its tracking ref. There is no hardcoded remote name or default branch. Explicit refspecs with an empty `--refmap` prevent custom fetch mappings from updating unrelated local refs. Tags, submodules, automatic maintenance, and writing FETCH_HEAD are disabled for this check. Local upstream branches can be compared without a network fetch. Detached checkouts and missing upstreams explain why remote updates cannot be checked.

After a successful fetch, `rev-list --left-right --count HEAD...<upstream>` supplies ahead/behind counts. Incoming commits show a notice to update the checkout using Git. Diverged branches explain that local commits must also be reconciled. A changed branch/tracking configuration during fetch invalidates the result, and fetch failures are shown rather than treating old tracking data as current. Noninteractive Git credentials and a timeout prevent a background check from waiting indefinitely. Local install/build availability is independent of fetch success.

These rules follow Git's official [fetch/refmap documentation](https://git-scm.com/docs/git-fetch), [upstream revision syntax](https://git-scm.com/docs/git-rev-parse), and [left/right commit counts](https://git-scm.com/docs/git-rev-list), checked 2026-11-02. Preserve the distinction between fetching remote-tracking refs and changing the checked-out branch. DevHub never automatically pulls, merges, rebases, or checks out source files.

`Installation.checkAtStartup()` runs at most once per app launch. `checkOnActivation()` also runs when the app becomes active after being in the background. Enabled automatic checks coalesce with each other and any in-flight manual check, then prompt if the running build differs from the checkout or incoming upstream commits exist. A signature of the source identity, notice, and pending commit IDs prevents repeatedly prompting for the same changes during a session. New source or upstream changes can prompt again. Checks do not prompt over an already-open installation window. The UserDefaults preference `installation.updatePrompts` defaults to true; the **Show update prompts** switch disables all automatic checks/prompts while preserving manual checks. Switching between windows within the app refreshes local information without another network fetch.

`PendingCommits` uses Git's reachability rules to list commits reachable from local HEAD and the successfully fetched upstream, excluding commits reachable from the running build's embedded commit. Duplicate ancestors appear once. The startup sheet lists subjects and abbreviated hashes in a scroll area capped at 220 points. It shows at most 100 commits and indicates when more exist. A missing installed revision (for example in a shallow or replaced checkout) explains that history is unavailable without suppressing the update prompt; updates containing only local working-tree changes explain why there are no new commit messages.

`GitSourceUpdatesTests.swift` uses disposable local Git remotes to cover incoming commits, ahead/diverged branches, non-default remote names, dirty files/index preservation, removed remote branches, missing upstreams, detached HEAD, failures and timeouts. Startup coverage checks prompt eligibility and the persistent opt-out. No test fetches a real network remote.

For live verification, close the installation window and relaunch with a source change after the installed build. Confirm the startup sheet appears once, opens Check for Updates, and lists any missing commits in its capped scroll area. Check the startup preference survives a relaunch, manual checking still fetches with prompts disabled, and enabled Install/Upgrade actions use the accent colour.

## Replacement lifecycle

In-app builds set `DEVHUB_BUILD_OUTPUT` to a temporary output directory, preserving an app opened from `build/DevHub.app`. `DEVHUB_STEP` lines from `build.sh` drive approximate progress without embedding a terminal. Command failures include a bounded output tail in the error dialog.

DevHub uses `ditto` to stage the entire bundle in the target Applications directory and verifies its signature before quitting. It copies `scripts/install-update.sh` into that staging directory and starts it independently using `DetachedProcess`. The helper waits for the original PID to exit, moves the previous bundle aside, renames the staged bundle into place, and opens it. Failures restore the previous bundle where available; an error receipt in Application Support/DevHub is displayed when the installation window is next opened. Do not merge resources into an existing app bundle or delete the old bundle before build/signature validation succeeds.

`DetachedProcess` creates a new POSIX session, closes inherited descriptors, redirects standard streams to `/dev/null`, and disclaims macOS process responsibility. This keeps both the replacement helper and launched Android emulators independent of app termination. The responsibility SPI follows [Chromium's macOS launcher](https://chromium.googlesource.com/chromium/src/+/lkgr/base/process/launch_mac.cc) (`responsibility_spawnattrs_setdisclaim`); check the installed Darwin spawn headers and that upstream implementation before changing it. Failure to establish independence is reported, rather than silently launching an app-owned process. Explicit device Shut Down still uses the platform's normal shutdown operation.

Run `InstallationTests.swift` for fingerprint, installation-status, command-error and detached-session coverage. Verify a real in-app upgrade: the process ID changes, the installed signature verifies, only one DevHub runs, the installed/current hashes match, and a DevHub-started emulator stays connected with its original PID across the restart. Test ordinary Quit and force termination too.
