import Foundation
import Observation

@MainActor
@Observable
final class AppUpdateQueue {
  typealias Completion = @MainActor (Result<Void, Error>) -> Void
  typealias Install = @MainActor (AppUpdateBatch.Item, @escaping Completion) -> Task<Void, Never>?

  private var batches: [String: AppUpdateBatch] = [:]
  @ObservationIgnored private var jobs: [String: Task<Void, Never>] = [:]

  func batch(deviceID: String) -> AppUpdateBatch? {
    batches[deviceID]
  }

  func activeVersion(appID: String, deviceID: String) -> CatalogVersion? {
    guard let batch = batches[deviceID], batch.isRunning, batch.outcomes[appID] == nil else {
      return nil
    }
    return batch.items.first { $0.id == appID }?.version
  }

  func pendingUpdates(
    in catalog: AppCatalog, installedApps: InstalledAppsStore, on device: SimulatorDevice,
    isBusy: (String) -> Bool
  ) -> [AppUpdateBatch.Item] {
    guard installedApps.canInstall(on: device) else { return [] }
    let apps = installedApps.updatableApps(in: catalog, for: device, includingRecent: false) ?? []
    return apps.compactMap { app in
      guard !isBusy(app.id),
        let version = app.availableUpdate(
          from: installedApps.application(bundleID: app.bundleID, deviceID: device.id)?.version,
          runtime: device.runtime)
      else { return nil }
      return AppUpdateBatch.Item(app: app, version: version)
    }
    .sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
  }

  func start(
    items: [AppUpdateBatch.Item], deviceID: String,
    reserve: @MainActor (AppUpdateBatch.Item) -> Void,
    install: @escaping Install,
    release: @escaping @MainActor (AppUpdateBatch.Item) -> Void
  ) {
    guard jobs[deviceID] == nil, !items.isEmpty else { return }
    let batch = AppUpdateBatch(items: items, currentAppID: items.first?.id)
    batches[deviceID] = batch
    for item in items { reserve(item) }
    jobs[deviceID] = Task { [self] in
      defer {
        batches[deviceID]?.currentAppID = nil
        batches[deviceID]?.isRunning = false
        jobs[deviceID] = nil
      }
      for item in items {
        guard batches[deviceID]?.outcomes[item.id] == nil else { continue }
        batches[deviceID]?.currentAppID = item.id
        let job = install(item) { [weak self] result in
          guard let self, batches[deviceID]?.id == batch.id else { return }
          let outcome: AppUpdateBatch.Outcome
          switch result {
          case .success: outcome = .updated
          case .failure(let error) where error is CancellationError: outcome = .canceled
          case .failure(let error): outcome = .failed(error.localizedDescription)
          }
          batches[deviceID]?.outcomes[item.id] = outcome
        }
        if let job {
          await job.value
        } else {
          batches[deviceID]?.outcomes[item.id] = .canceled
          release(item)
        }
      }
    }
  }

  func cancelQueued(appID: String, deviceID: String) {
    guard let batch = batches[deviceID], batch.isRunning,
      batch.outcomes[appID] == nil, batch.items.contains(where: { $0.id == appID })
    else { return }
    batches[deviceID]?.outcomes[appID] = .canceled
  }

  func cancelAll(deviceID: String, cancel: @MainActor (String) -> Void) {
    guard let batch = batches[deviceID], batch.isRunning, !batch.isStopping else { return }
    batches[deviceID]?.isStopping = true
    for item in batch.items where batches[deviceID]?.outcomes[item.id] == nil { cancel(item.id) }
  }

  func dismiss(deviceID: String) {
    guard batches[deviceID]?.isRunning == false else { return }
    batches[deviceID] = nil
  }
}
