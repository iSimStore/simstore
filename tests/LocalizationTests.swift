import Foundation

@main
struct LocalizationTests {
  static func main() {
    do {
      try verifyTranslations()
      print("PASS: English and Simplified Chinese resources, simulator actions, and interpolation.")
    } catch {
      FileHandle.standardError.write(
        Data("Localization test failed: \(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  static func verifyTranslations() throws {
    guard CommandLine.arguments.count == 2,
      let app = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    else { throw failure("Expected the built App Bundle path.") }
    try require(Set(app.localizations) == ["en", "zh-Hans"], "Unexpected supported languages.")
    try require(app.developmentLocalization == "en", "English must be the fallback language.")

    for language in ["en", "zh-Hans"] {
      guard let directory = app.url(forResource: language, withExtension: "lproj"),
        let bundle = Bundle(url: directory)
      else { throw failure("Missing \(language) localization resources.") }
      for file in try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      where ["strings", "stringsdict"].contains(file.pathExtension) {
        _ = try String(contentsOf: file, encoding: .utf8)
      }
      let locale = Locale(identifier: language)
      let english = language == "en"
      let labels: [(String.LocalizationValue, String, String)] = [
        ("Discover", "Discover", "发现"), ("Installed", "Installed", "已安装"),
        ("Updates", "Updates", "更新"),
        ("Start Simulator", "Start Simulator", "启动模拟器"),
        ("Starting…", "Starting…", "正在启动…"),
        ("Shut Down", "Shut Down", "关机"),
        ("Shutting Down…", "Shutting Down…", "正在关机…"),
        ("Keep Waiting", "Keep Waiting", "继续等待"),
        (
          "Operation Is Taking Longer Than Expected", "Operation Is Taking Longer Than Expected",
          "操作耗时较长"
        ),
        ("Couldn’t Shut Down Simulator", "Couldn’t Shut Down Simulator", "无法关闭模拟器"),
        ("Booted", "Booted", "已启动"),
        ("Shutdown", "Shutdown", "已关机"),
        ("Booting", "Booting", "正在启动"),
        ("Shutting Down", "Shutting Down", "正在关机"),
        ("Unknown State", "Unknown State", "未知状态"),
        ("All Apps", "All Apps", "全部应用"),
        ("Search apps", "Search apps", "搜索应用"),
        ("Refresh Catalog", "Refresh Catalog", "刷新目录"),
        ("Cloud", "Cloud", "云服务"),
        ("Email", "Email", "电子邮件"),
        ("Music", "Music", "音乐"),
        ("Security", "Security", "安全"),
        ("Catalog Unavailable", "Catalog Unavailable", "无法获取应用目录"),
        ("License", "License", "许可证"),
        ("Showing Saved Catalog", "Showing Saved Catalog", "正在显示已缓存的目录"),
        ("Showing Previous Simulator List", "Showing Previous Simulator List", "显示上次获取的模拟器列表"),
        ("Installed Version", "Installed Version", "已安装版本"),
        ("Version Unavailable", "Version Unavailable", "版本未知"),
        ("Uninstall", "Uninstall", "卸载"),
        ("Uninstalling…", "Uninstalling…", "正在卸载…"),
        ("About SimStore", "About SimStore", "关于 SimStore"),
        ("Uninstall SimStore…", "Uninstall SimStore…", "卸载 SimStore…"),
        ("Uninstall SimStore?", "Uninstall SimStore?", "卸载 SimStore？"),
        ("Couldn’t Uninstall SimStore", "Couldn’t Uninstall SimStore", "无法卸载 SimStore"),
        (
          "SimStore, its caches, settings, and temporary files will be permanently deleted. SimStore will then quit.",
          "SimStore, its caches, settings, and temporary files will be permanently deleted. SimStore will then quit.",
          "将永久删除 SimStore 及其缓存、设置和临时文件。随后 SimStore 将退出。"
        ),
        (
          "The running SimStore app could not be verified. Nothing was uninstalled.",
          "The running SimStore app could not be verified. Nothing was uninstalled.",
          "无法验证当前运行的 SimStore，未执行卸载。"
        ),
        (
          "Move SimStore to a writable folder before uninstalling it.",
          "Move SimStore to a writable folder before uninstalling it.",
          "请先将 SimStore 移到可写入的文件夹，再卸载。"
        ),
        (
          "The uninstall assistant could not finish. Try again.",
          "The uninstall assistant could not finish. Try again.",
          "卸载助手未能完成操作，请重试。"
        ),
        ("Check for Updates…", "Check for Updates…", "检查更新…"),
        ("Update and Restart", "Update and Restart", "更新并重新启动"),
        ("Install Nightly and Restart", "Install Nightly and Restart", "安装每夜构建并重新启动"),
        ("SimStore Is Up to Date", "SimStore Is Up to Date", "SimStore 已是最新版本"),
        ("Update All", "Update All", "全部更新"),
        ("Updating…", "Updating…", "正在更新…"),
        ("Waiting…", "Waiting…", "等待中…"),
        ("Cancel All", "Cancel All", "全部取消"),
      ]
      for (key, source, translated) in labels {
        try expect(
          String(localized: key, bundle: bundle, locale: locale), english ? source : translated)
      }

      let tool = "Device Hub"
      let updated = 2
      let failed = 1
      let canceled = 3
      try expect(
        String(
          localized: "\(updated) updated, \(failed) failed, \(canceled) canceled", bundle: bundle,
          locale: locale),
        english ? "2 updated, 1 failed, 3 canceled" : "2 个已更新，1 个失败，3 个已取消")
      let appName = "LocalSend"
      let targetName = "iPhone 测试"
      try expect(
        String(localized: "Uninstall \(appName)?", bundle: bundle, locale: locale),
        english ? "Uninstall LocalSend?" : "卸载 LocalSend？")
      try expect(
        String(
          localized: "\(appName) and its data will be removed from \(targetName).", bundle: bundle,
          locale: locale),
        english
          ? "LocalSend and its data will be removed from iPhone 测试."
          : "将从 iPhone 测试 中删除 LocalSend 及其数据。")
      try expect(
        String(localized: "Open \(tool)", bundle: bundle, locale: locale),
        english ? "Open Device Hub" : "打开 Device Hub")
      let url = "https://example.com/releases/download/app%2F1.0.0/app.tar.bz2"
      try expect(
        String(localized: "Open \(url) in your web browser.", bundle: bundle, locale: locale),
        english ? "Open \(url) in your web browser." : "请在浏览器中打开 \(url)。")
      let detail = "Permission denied (13)."
      try expect(
        String(localized: "\(tool) couldn’t be opened. \(detail)", bundle: bundle, locale: locale),
        english ? "Device Hub couldn’t be opened. \(detail)" : "无法打开 Device Hub。\(detail)")
      let deviceName = "iPhone 测试"
      try expect(
        String(
          localized:
            "Couldn’t start shutting down \(deviceName). Check its current state and try again.",
          bundle: bundle, locale: locale),
        english
          ? "Couldn’t start shutting down iPhone 测试. Check its current state and try again."
          : "无法开始关闭 iPhone 测试。请检查其当前状态后重试。")
      try expect(
        String(
          localized:
            "An app operation on \(deviceName) hasn’t finished. Keep waiting, or shut down this simulator to stop pending operations. Shutting down closes all of its apps.",
          bundle: bundle, locale: locale),
        english
          ? "An app operation on iPhone 测试 hasn’t finished. Keep waiting, or shut down this simulator to stop pending operations. Shutting down closes all of its apps."
          : "iPhone 测试 上的应用操作尚未完成。你可以继续等待，或关闭此模拟器以停止待处理的操作。关机会关闭其中的所有应用。")
      try expect(
        String(
          localized: "Couldn’t start \(deviceName).\n\(detail)", bundle: bundle, locale: locale),
        english ? "Couldn’t start \(deviceName).\n\(detail)" : "无法启动 \(deviceName)。\n\(detail)")
      try expect(
        String(
          localized: "Couldn’t shut down \(deviceName).\n\(detail)", bundle: bundle, locale: locale),
        english ? "Couldn’t shut down \(deviceName).\n\(detail)" : "无法关闭 \(deviceName)。\n\(detail)")
      try expect(
        String(
          localized:
            "Create an iPhone or iPad simulator in \(tool).\nThen come back to find your next favorite app.",
          bundle: bundle, locale: locale),
        english
          ? "Create an iPhone or iPad simulator in Device Hub.\nThen come back to find your next favorite app."
          : "在 Device Hub 中创建 iPhone 或 iPad 模拟器。\n然后回来发现你喜爱的应用。")

      let runtime = "27.0"
      try expect(
        String(localized: "iOS \(runtime)", bundle: bundle, locale: locale), "iOS 27.0")
      let minimum = "27.0"
      let olderRuntime = "18.0"
      try expect(
        String(
          localized:
            "This build requires iOS \(minimum) or later. It may not work on iOS \(olderRuntime).",
          bundle: bundle, locale: locale),
        english
          ? "This build requires iOS 27.0 or later. It may not work on iOS 18.0."
          : "此构建需要 iOS 27.0 或更高版本，在 iOS 18.0 上可能无法正常运行。")
      let status = 503
      try expect(
        String(
          localized: "The app repository returned HTTP \(status).", bundle: bundle, locale: locale),
        english ? "The app repository returned HTTP 503." : "应用仓库返回了 HTTP 503。")
    }
  }

  static func expect(_ actual: String, _ expected: String) throws {
    try require(actual == expected, "Expected '\(expected)', received '\(actual)'.")
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  static func failure(_ message: String) -> NSError {
    NSError(domain: "LocalizationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
