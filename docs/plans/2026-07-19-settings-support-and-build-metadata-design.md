# Settings Support Entry and Gitea Build Metadata

## Goal

Let users reopen the existing author-support sheet from Settings, show the
installed app's version and build number, and keep Gitea as the authoritative
source of release build numbers.

## Settings experience

Add a `Support CodeAgents` button to the existing About section. The button
presents `AuthorSupportPromptSheet` directly, regardless of the recurring
prompt's schedule or permanent opt-out state. Manually opening the sheet does
not record a scheduled presentation. The existing `Don't show this again`
action still updates the recurring-prompt preference when explicitly selected.

Display the bundled metadata as `1.7 (4636)`, using
`CFBundleShortVersionString` and `CFBundleVersion`. Missing metadata degrades to
the available value or an em dash.

## Build metadata

`VERSIONS.TXT` remains the marketing-version source of truth. The managed
production-artifact workflow already exports the Gitea run number as
`OPENCODE_PRODUCTION_ARTIFACT_RUN_NUMBER`; `scripts/artifact.sh` resolves that
value before the project default.

The TestFlight path continues passing the resolved values to `asc publish`.
The simulator artifact path now passes the same values to XcodeBuildMCP as
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` overrides, so artifact
metadata and the built bundle cannot disagree. Local direct Xcode builds use
the committed fallback build number and must not invent timestamp counters.

## Validation

- Unit-test version/build display formatting.
- Unit-test Xcode build-setting payload generation and invalid inputs.
- Run the canonical CI workflow.
- Build, install, and launch on the primary iPhone.
- Read the installed app bundle metadata to confirm version `1.7` and the
  selected build number.
