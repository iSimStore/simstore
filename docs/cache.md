# Cache behavior

Both caches live under `URL.cachesDirectory/<application identifier>/`. The identifier comes from the main bundle; unbundled command-line processes use their process name. macOS may reclaim these disposable files. Missing cache files are normal and do not prevent a network download.

## Catalog index

The catalog is stored as `index.json`. On the first refresh of a `CatalogStore`, SimStore validates the disk copy and displays it immediately when valid, then requests the current index from the builds repository's `latest` release. Later refreshes keep the current in-memory catalog visible while requesting an update. The browser requests the catalog when it first appears and when using Refresh Catalog; there is no periodic refresh or time-based expiry.

Discover, Installed, and Updates share the browser and loaded data. Switching sections does not download the catalog or query installed apps again. The search is preserved, and the selected category is kept when it is available in the destination section; otherwise the category resets to All Apps. Changing the selected simulator or its state, reactivating SimStore, and using Refresh Catalog or Check for Simulators still refresh the installed-app inventory.

Requests bypass Foundation's local HTTP cache and use a 30-second request timeout. SimStore does not implement ETag or Last-Modified conditional requests. A successful HTTP response must also pass catalog decoding and validation before replacing the current catalog and atomically overwriting the disk file. No catalog timestamp comparison is performed.

A network, HTTP, or validation failure preserves the last valid catalog and displays a saved-catalog notice. If no valid catalog is available, the page offers an error and retry action. An unreadable or invalid disk copy is ignored and can be replaced by a successful download. A disk write failure is logged without discarding a valid downloaded catalog. Concurrent refreshes share one request; an active caller retries if the task owning its shared refresh was canceled.

## Simulator discovery

The last successful simulator inventory is retained in memory for the current application session. If a later scan fails, the sidebar and browser keep their devices and selection while a warning offers a retry. A successful scan replaces the inventory, including clearing devices when it returns an empty list. Before any successful scan, discovery failures still show the setup or error screen. Cancellation preserves the current inventory without adding a warning.

Concurrent refreshes share an in-flight scan and its outcome. If the task owning that scan is canceled, active waiting callers retry discovery and share the retry while it is in flight. Canceled callers do not retry, and a scan failure, including a cancellation error without owner-task cancellation, does not trigger automatic retries.

Starting or shutting down a simulator requires a successful scan after its control command before SimStore reports the operation as confirmed. Retained power states cannot substitute for that scan. The retained inventory can still be used to retry a shutdown recovery request when discovery is temporarily unavailable. The recovery alert closes when the shutdown request is accepted for execution; this acknowledges acceptance, rather than confirmation that the simulator has shut down. Command failures are reported separately, and the displayed power state is confirmed by a successful scan.

## Local command execution

The built-in `Command.run` runner is synchronous and checks its current task for cancellation immediately before launching a child process. Production callers run these commands in background tasks. Once launched, the runner drains output and waits for the process to exit, then returns the actual output or exit error even if its task was canceled in the meantime. There is no process timeout or automatic termination. A stuck command can therefore keep its background worker occupied indefinitely; the network timeouts documented here do not apply to local commands.

Simulator discovery, installed-app queries, boot, shutdown, install, launch, and uninstall use detached command workers. Canceling their calling task does not cancel those workers or terminate an already running command. Boot, shutdown, and installed-app queries check the caller's cancellation again after the worker finishes; `SimulatorStore` checks cancellation before publishing a discovery result. Install, launch, and uninstall preserve the completed command's outcome, so a late cancellation does not imply the simulator operation was undone. Terminating a `simctl` client would not establish whether CoreSimulator completed or rolled back a request it had already accepted.

Installation and self-update preparation forward cancellation to their detached preparation workers. An active archive command still finishes before cancellation is observed and temporary files are removed. A canceled preparation must not launch another command or proceed to simulator installation or self-update handoff.

For app operations and installed-app queries on a booted simulator, the 30-second operation monitor offers a separate shutdown recovery request. It does not impose a command deadline or terminate the stalled process. Accepting shutdown starts an independent control command; it does not confirm shutdown or guarantee that the original command will finish. A stalled boot or discovery command has no operation-monitor prompt.

## App icons

`IconCache` is shared by app cards and detail sheets. The key is the SHA-256 digest of the original release-asset URL, a newline, and the latest version's `recipeRevision`. The original URL is used even when GitHub redirects to a temporary asset URL. This digest identifies the cache entry; the catalog's archive SHA-256 is not an icon checksum.

A new app version or recipe revision changes the key. Description, translation, and category changes do not. Selecting a historical build in the detail sheet still uses the app's latest icon. Display size is not part of the key, so the 52 pt card and 80 pt detail icon share the same decoded image.

The lookup order is decoded memory cache, disk, then network. ImageIO decodes images off the main thread with a maximum edge of 256 pixels; smaller images retain their original dimensions. The `NSCache` cost is `bytesPerRow * height`, with a target of 32 MiB. This is an eviction hint, not a strict process-memory limit or a preallocated buffer. View and GPU allocations are outside that cost.

The original downloaded image bytes are saved atomically in `icons/<key>.png` after a successful HTTP response and image decoding. The disk budget is 64 MiB of file contents, rather than allocated filesystem blocks. An entry larger than the entire budget is displayed and cached in memory but is not written to disk. A persistence failure is logged and does not hide a valid image.

Disk cleanup runs on the first disk access and after a successful write. Modification times record use, including memory hits. When over budget, the least recently used files are removed first. Only regular PNG files with generated 64-character lowercase hexadecimal names participate in cleanup. Old build entries remain until evicted; valid images have no time-based expiry. Neither budget is preallocated.

Downloads use a dedicated ephemeral `URLSession` with its HTTP cache disabled and a 30-second request timeout. At most four downloads run concurrently. Requests for the same key share one task; canceling one view does not cancel that shared task. Canceled callers discard its result, while the completed download remains available to other views and future cache lookups.

Corrupt disk images are removed and fetched again. Failed requests and invalid response bodies are not persisted or retained as successful entries. There is no automatic retry loop; a later view request can retry. While no image is available, the existing placeholder remains visible. Refreshing the catalog does not clear icon caches; only a changed key, eviction, or missing/corrupt data requires another download.

## Installation downloads

App archives are streamed to a separate, randomly named directory under `URL.temporaryDirectory` for each installation. The download session has its HTTP cache disabled, a 60-second inactivity timeout, and a one-hour resource timeout. Archives are not retained or shared as a persistent download cache; retrying an installation starts a new download.

The archive's size and SHA-256 must match the selected catalog version before extraction. The temporary archive and extracted app are removed when the operation succeeds, fails, or finishes canceling. Cancellation during preparation waits for any running archive command to finish before cleanup; once `simctl install` starts, it is allowed to finish. A process exit can leave temporary files for the operating system to reclaim.

Update All snapshots all compatible pending updates for the selected simulator, independently of search and category filters, and runs them one at a time through the same installation pipeline. Apps already running another operation are omitted. Queued apps have no downloaded files, reserve their per-app/device operation slots, and retain their selected version, size, and checksum even if the catalog refreshes. Each simulator has its own queue and results, which remain in memory when navigating or switching devices. A failure records its diagnostic and the next app proceeds; another Update All action retries only apps that still need updates. Canceling a queued item releases it immediately. Cancel All cancels pending downloads/preparation and removes the remaining queue, while an installation already handed to `simctl` finishes normally. Completed updates retain their usual Open actions until navigation, catalog refresh, or opening removes them from the update list.

## SimStore updates

The client's own `version.json` feed is fetched on each explicit update check with the local HTTP cache bypassed and `Cache-Control: no-cache`. It has no disk cache, ETag storage, expiry timer, or offline fallback. The most recent result and selected release are kept in memory for the current application session. Before downloading a nightly, SimStore checks the current feed again and asks for another update check if the offered build has changed.

Self-update archives use the same uncached download session as Simulator app installations. They are streamed to a private, randomly named `.simstore-update-*` directory beside the installed SimStore app, rather than a persistent download cache, so an atomic replacement can stay on one filesystem. The verified archive is deleted after preparation. The extracted bundle, copied assistant, and previous version remain only until the update succeeds or finishes failing/canceling. An interrupted process can leave a staging directory for manual cleanup.

If the update assistant encounters an error, it writes a translated message to `update-error.json` in the client's cache directory. The running or relaunched client consumes and removes that message when reporting the failure. This file is a one-time failure report, not a version or package cache; losing it does not affect the installed application.

## Uninstalling SimStore

SimStore → Uninstall SimStore… shows a confirmation with the running application's path. Uninstall removes that bundle, its catalog and icon caches, application support data, preferences including host-specific preferences, saved window state, HTTP storage, WebKit data, logs, and installation temporary directories belonging to its bundle identifier. It also removes abandoned uninstall staging directories and self-update staging directories beside the app; a staging request pointing to another application is preserved.

The existing native assistant runs from a private temporary directory and verifies the target process and bundle. It pauses the app before synchronizing and clearing its preference domains and deleting files, removes its own staging directory, then sends SIGKILL to the target PID. This prevents the app from recreating caches or saving window state during normal termination. Cleanup failure resumes the app and returns an error. Uninstall is unavailable while a SimStore update is in progress.
