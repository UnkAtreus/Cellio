# Native UX/UI checklist

Every UX/UI change needs a dedicated UX/UI expert before implementation and a review of the resulting native candidate.

- Define the user task, information hierarchy, changed interaction states and observable acceptance. Reuse native controls and accepted behavior.
- Keep content top-aligned, cards flat/readable, labels leading and switches/actions trailing. Reserve stable space for status, scrollbars and pending/failure text.
- Review System/Light/Dark, the minimum window size, native keyboard actions, contextual Back/focus, accessible names and non-color status. Check relevant Reduce Motion behavior.
- Verify actual transitions: repeated input, cancellation, pending/failure, monitor toggles, disclosure expansion and hover-to-copy. A screenshot or passing core suite alone does not prove an interaction.
- Preserve device identity when readings are absent, stale, disconnected or paused. A mouse stays a mouse; AirPods stay AirPods. Settings and menu use the same identity mapping.
- Check one/two/three selected AirPods parts, including Case-only. Component selection, monitoring, menu visibility and notifications have distinct meanings.
- Keep ordinary copy short. Technical diagnostics belong behind explicit copy; unknown/coarse/retained data must stay honest.
- Record the exact candidate and the evidence reviewed. State missing hardware/OS/accessibility evidence. Return one focused repair list or bounded PASS; do not broaden validation after resolved checks without a new concern.
