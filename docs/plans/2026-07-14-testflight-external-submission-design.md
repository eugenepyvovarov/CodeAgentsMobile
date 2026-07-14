# TestFlight External Submission Design

## Problem

The production artifact workflow uploads a valid build and assigns it to the
external TestFlight group, but it does not submit the build for Beta App
Review. Recent builds therefore remain in `READY_FOR_BETA_SUBMISSION`. Once the
last externally approved build expires, the public invitation link reports
that the beta is not accepting new testers even though the link is enabled and
the group is below its tester limit.

## Decision

Every explicit production/TestFlight artifact publication will submit the
uploaded build for external Beta App Review. The existing `asc publish
testflight` invocation will add `--submit --confirm`. This is preferable to a
manual follow-up or another environment flag because the artifact command is
already an intentional production release operation and the configured group
is external.

The command continues to wait for upload processing, assign the configured
group, preserve automatic tester notification, and use the existing timeout.
If App Store Connect rejects the submission or required metadata is missing,
the artifact command fails and the production workflow reports failure instead
of claiming that a non-distributable build was successfully released.

## Rollout and Verification

Build 4630 will be submitted immediately using its App Store Connect build ID
and the existing external group ID. Verification requires checking that its
external state advances from `READY_FOR_BETA_SUBMISSION` to an external review
or testing state and that the public invitation no longer reports that it is
closed once Apple makes the build available.

Future releases use the updated script automatically. Shell syntax validation
guards the release entrypoint, while the live App Store Connect state is the
authoritative integration check because external submission cannot be fully
simulated locally.
