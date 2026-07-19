# Recurring Author Support Prompt

## Goal

Add a friendly, non-blocking support sheet that appears immediately on the first
eligible launch and then no more than once every 14 days. It invites people to
follow the author on X first, followed by optional open-source sponsorship links.

## Experience

Present a polished SwiftUI sheet from the app root with this copy:

> **Help CodeAgents grow**
>
> CodeAgents is independently developed and open source. If it’s useful to you,
> following the author helps more people discover it. You can also support the
> time spent maintaining and improving the project.
>
> No pressure—thank you for using CodeAgents.

Actions appear in this order:

1. Follow `@selfhosted_ai` on X
2. Sponsor on GitHub
3. Support on Patreon
4. Buy Me a Coffee
5. Don’t show this again
6. Maybe later

Opening an external link does not dismiss the sheet. The sheet remains available
when the user returns so they can visit another destination. “Maybe later” and
interactive swipe dismissal close it until the next eligible date. Selecting
“Don’t show this again” saves a permanent local opt-out and dismisses the sheet.

## Scheduling and persistence

Use a small `UserDefaults`-backed schedule store with two values:

- the most recent presentation date;
- a permanent opt-out Boolean.

The prompt is eligible when the opt-out is false and either no presentation date
exists or at least 14 days have elapsed. Record the date when the sheet is
presented, not when it is dismissed, so a crash or force quit cannot immediately
show it again. Re-check eligibility when the root view first appears and whenever
the scene becomes active.

No link taps, sponsorship choices, or other interaction data are collected.

## UI and accessibility

Use one root-level sheet so it works from both the projects list and active-agent
tabs. The content scrolls for Dynamic Type, uses semantic system colors and SF
Symbols, and gives each action a clear accessibility label and hint. The X action
is the primary filled button; sponsorship destinations are secondary card rows.

Sponsorship is explicitly optional and does not unlock app functionality.

## Links

- X: `https://x.com/selfhosted_ai`
- GitHub Sponsors: `https://github.com/sponsors/eugenepyvovarov`
- Patreon: `https://patreon.com/selfhosted_ninja`
- Buy Me a Coffee: `https://buymeacoffee.com/selfhostedninja`

## Validation

Add unit coverage for:

- immediate first presentation;
- suppression before 14 days;
- presentation at the 14-day boundary;
- permanent opt-out;
- invalid persisted date data;
- presentation date recording.

Run the focused tests and the repository’s canonical CI workflow on an available
iPhone simulator. Update the public CodeAgents Mobile project page with a concise
note that the app offers optional author-follow and open-source sponsorship links.
