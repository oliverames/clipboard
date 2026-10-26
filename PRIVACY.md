# Clipboard Privacy

Ames Consulting, LLC develops Clipboard. Clipboard has no accounts, no sync, no advertising and no analytics, and it does not sell personal information or use diagnostic information for cross-app tracking.

Your clipboard history stays on your iPhone, in an App Group container shared by the app and its extensions. Location is used only to tag clippings. To show the town a clipping was copied in, Clipboard sends that clipping's coordinates to Apple Maps once and stores the name with the clipping. Link previews contact the page you copied, and App Store icons come from Apple's iTunes Search API. Turn off link previews in Settings to stop those requests.

## Crash reports

When Share Crash Reports is on in a build that includes crash reporting, the Clipboard app sends crash, freeze and error reports to Sentry for Ames Consulting, LLC. They help find and fix crashes, freezes over two seconds, terminations by the system, and a history database that fails to load. A report can include the app version and build, the iOS version, the device model, technical stack traces, Apple's MetricKit hang and CPU summaries, and short fixed event labels with counts and error codes. The widget and keyboard extensions don't send reports.

Reports never include what you copied: no clipping text, rich text, images, links, item titles, list names, search terms or file names, and no clipping's location or town. Exception messages from the system are dropped unless they match a known technical format, because they can quote the item they failed on. Reports also leave out the device's name, locale and time zone, and your IP address. Every remaining string is scrubbed on the device before it is sent, and the Sentry project is set not to store IP addresses. Clipboard does not add a user or installation identity to reports, and it sends no sessions, performance traces, screenshots, view hierarchies or screen recordings. Sentry receives the connection information it needs to accept an Internet request.

Share Crash Reports is on by default and can be turned off in Settings, next to Diagnostics. Turning it off stops the reporter at once. Reports may wait in a small local cache while the device is offline. Turning the switch off does not recall reports Sentry has already received, which it keeps under the project's retention limits. Builds made without the Sentry key, including forks, never send reports.

The capture ledger behind Settings > Diagnostics is separate. It records only change counts, event kinds and times, and it never leaves the device.

Sentry handles the reports it receives under its [privacy policy](https://sentry.io/privacy/), and Ames Consulting controls the data submitted to its Sentry project. Contact [Ames Consulting](https://ames.consulting/contact/) with questions about received reports.

Effective October 26, 2026.
