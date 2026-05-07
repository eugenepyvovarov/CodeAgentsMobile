# Change Create Agent Button Color To Orange

## Overview

Change the Agents screen empty-state `Create Agent` button from blue to orange while keeping the existing behavior and layout unchanged.

## Acceptance Criteria

- [x] The visible `Create Agent` button on the Agents screen uses an orange background instead of the previous blue background.
- [x] The button text remains white and readable.
- [x] Tapping `Create Agent` still opens the existing new-agent sheet without navigation or workflow regressions.
- [x] Native iOS visual validation captures baseline and current full-screen simulator screenshots for the changed Agents screen.
- [x] Demo evidence captures full-screen simulator screenshots and video for the create-agent flow.

## Task List

- [x] Update the Agents screen `Create Agent` CTA styling.
- [x] Keep create-agent behavior unchanged.
- [x] Make the native iOS simulator evidence script capture the Agents screen visual checkpoints.
- [x] Run repository CI and native evidence commands for the PR branch.

## Demo Scenario

### Scenario Identifier

agents-create-agent-flow

### Repo Command

/bin/bash ./scripts/ios-simulator-evidence.sh demo

### Steps

1. Launch the app in a clean native iOS simulator.
2. Open the Agents screen empty state.
3. Capture the visible `Create Agent` CTA.
4. Tap `Create Agent`.
5. Capture the presented new-agent sheet.

### Screenshot Checkpoints

- agents-empty-create-agent: Full-screen simulator screenshot of the Agents screen showing the orange `Create Agent` CTA.
- new-agent-sheet: Full-screen simulator screenshot after tapping `Create Agent`, showing the new-agent sheet.

## Visual Validation

### Identifier

agents-create-agent-orange

### Capture Command

/bin/bash ./scripts/ios-simulator-evidence.sh visual

### Steps

1. Build and launch the app in a clean native iOS simulator.
2. Open the Agents screen empty state.
3. Capture a full-screen simulator screenshot of the `Create Agent` CTA.

### Full-Page Checkpoints

- agents-empty-create-agent: Full-screen simulator screenshot of the Agents screen showing the `Create Agent` CTA.

### Expected Comparisons

- Current screenshot shows the `Create Agent` CTA background as orange where baseline shows blue.
- CTA text remains white and readable.
- Agents screen layout, spacing, shape, typography, navigation, and unrelated controls remain visually unchanged.

## Deployment

No production deployment is required for this PR. The change ships with the next iOS app build/TestFlight artifact after merge.

## Open Questions

None.
