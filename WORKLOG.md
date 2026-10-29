# Worklog

## 2026-10-29 - device crash audit and detail verification

- Reviewed the retained build-15 Auto Layout abort from the phone crash audit in
  [issue #7](https://github.com/oliverames/clipboard/issues/7). Commit
  `21d3460` had already removed the invalid width constraint between labels in
  different stacks and replaced the old metadata implementation.
- Built current source `3354cc9` into a separate development fixture and exercised
  the unchanged detail controller on a physical iPhone with five synthetic cases:
  text, link, image, code and a long list-name metadata value. Every fresh launch
  reached and rendered the detail and metadata cards. Reports matched each case's
  launch PID and timestamp; screenshots were visually reviewed.
- The fixture used an in-memory database, separate bundle identity, no App Group
  or iCloud entitlements, no embedded extensions, and disabled capture, telemetry
  startup and link previews. Only synthetic records were used. The fixture was
  removed afterward and its absence verified. The historical crash issue is closed;
  no production code change was needed. This was detail-construction verification,
  not a full copy, share or monitoring regression run.

- NEW at wrap-up: [issue #8](https://github.com/oliverames/clipboard/issues/8)
  records the long-list metadata label wrapping observed in the same synthetic
  run. The value remained visible and no crash occurred, but `Lists` broke across
  two lines. It remains separate from the resolved crash. Preserve the existing
  accessibility-size stacked layout when correcting horizontal space allocation;
  shared-device ownership had already passed to another active task.
