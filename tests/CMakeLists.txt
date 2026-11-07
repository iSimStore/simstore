add_executable(SimStoreSmokeTest AppSmokeTest.swift)
add_dependencies(SimStoreSmokeTest SimStore)
# Parse the single-file @main entry point as a library.
target_compile_options(SimStoreSmokeTest PRIVATE -parse-as-library)
add_test(NAME app-window COMMAND SimStoreSmokeTest "$<TARGET_BUNDLE_DIR:SimStore>")
set_tests_properties(app-window PROPERTIES TIMEOUT 20 RUN_SERIAL TRUE)

add_executable(SimStoreLifecycleTest AppLifecycleTest.swift "${PROJECT_SOURCE_DIR}/src/AppDelegate.swift")
add_test(NAME app-window-close COMMAND SimStoreLifecycleTest)
set_tests_properties(app-window-close PROPERTIES TIMEOUT 10 RUN_SERIAL TRUE)

add_executable(SimStoreCommandTest CommandTests.swift "${PROJECT_SOURCE_DIR}/src/Command.swift")
target_compile_options(SimStoreCommandTest PRIVATE -parse-as-library)
add_test(NAME command COMMAND SimStoreCommandTest)
set_tests_properties(command PROPERTIES TIMEOUT 10)

add_executable(SimStoreCatalogTest AppCatalogTests.swift
    "${PROJECT_SOURCE_DIR}/src/AppCatalog.swift"
)
target_compile_options(SimStoreCatalogTest PRIVATE -parse-as-library)
add_test(NAME catalog COMMAND SimStoreCatalogTest)
set_tests_properties(catalog PROPERTIES TIMEOUT 10)

add_executable(SimStoreCatalogGridTest CatalogAppGridTests.swift
    "${PROJECT_SOURCE_DIR}/src/CatalogAppGrid.swift"
    "${PROJECT_SOURCE_DIR}/src/AppCatalog.swift"
)
target_compile_options(SimStoreCatalogGridTest PRIVATE -parse-as-library)
add_test(NAME catalog-grid COMMAND SimStoreCatalogGridTest)
set_tests_properties(catalog-grid PROPERTIES TIMEOUT 20 RUN_SERIAL TRUE)

# Exercise the actual navigation owner so view identity regressions rerun its loading tasks.
get_target_property(NAVIGATION_SOURCES SimStore SOURCES)
list(FILTER NAVIGATION_SOURCES INCLUDE REGEX "\\.swift$")
list(FILTER NAVIGATION_SOURCES EXCLUDE REGEX "(^|/)SimStoreApp\\.swift$")
list(TRANSFORM NAVIGATION_SOURCES PREPEND "${PROJECT_SOURCE_DIR}/src/")
add_executable(SimStoreNavigationTest CatalogNavigationTests.swift ${NAVIGATION_SOURCES})
target_compile_options(SimStoreNavigationTest PRIVATE -parse-as-library)
add_test(NAME catalog-navigation COMMAND SimStoreNavigationTest)
set_tests_properties(catalog-navigation PROPERTIES TIMEOUT 25 RUN_SERIAL TRUE)

add_executable(SimStoreCatalogCategoriesCheck EXCLUDE_FROM_ALL CatalogCategoriesCheck.swift
    "${PROJECT_SOURCE_DIR}/src/AppCatalog.swift"
    "${PROJECT_SOURCE_DIR}/src/AppConfiguration.swift"
    "${PROJECT_SOURCE_DIR}/src/CatalogCategory.swift"
)
target_compile_options(SimStoreCatalogCategoriesCheck PRIVATE -parse-as-library)
add_custom_target(CheckCatalogCategories
    COMMAND "$<TARGET_FILE:SimStoreCatalogCategoriesCheck>"
    DEPENDS SimStoreCatalogCategoriesCheck
    COMMENT "Checking category coverage in the latest app catalog"
    VERBATIM
)

add_executable(SimStoreCatalogLoadingTest CatalogLoadingTests.swift
    "${PROJECT_SOURCE_DIR}/src/AppCatalog.swift"
    "${PROJECT_SOURCE_DIR}/src/CatalogClient.swift"
    "${PROJECT_SOURCE_DIR}/src/CatalogStore.swift"
    "${PROJECT_SOURCE_DIR}/src/AppConfiguration.swift"
)
target_compile_options(SimStoreCatalogLoadingTest PRIVATE -parse-as-library)
add_test(NAME catalog-loading COMMAND SimStoreCatalogLoadingTest)
set_tests_properties(catalog-loading PROPERTIES TIMEOUT 15)

add_executable(SimStoreIconCacheTest IconCacheTests.swift
    "${PROJECT_SOURCE_DIR}/src/IconCache.swift"
    "${PROJECT_SOURCE_DIR}/src/AppConfiguration.swift"
)
target_compile_options(SimStoreIconCacheTest PRIVATE -parse-as-library)
add_test(NAME icon-cache COMMAND SimStoreIconCacheTest)
set_tests_properties(icon-cache PROPERTIES TIMEOUT 20)

add_executable(SimStoreInstallationTest AppInstallationTests.swift AppInstallButtonTests.swift AppDownloadTests.swift AppPackageTests.swift AppUpdateBatchTests.swift InstallationFixtures.swift
    "${PROJECT_SOURCE_DIR}/src/AppCatalog.swift"
    "${PROJECT_SOURCE_DIR}/src/AppConfiguration.swift"
    "${PROJECT_SOURCE_DIR}/src/AppDownload.swift"
    "${PROJECT_SOURCE_DIR}/src/AppPackage.swift"
    "${PROJECT_SOURCE_DIR}/src/MachOValidation.swift"
    "${PROJECT_SOURCE_DIR}/src/AppInstaller.swift"
    "${PROJECT_SOURCE_DIR}/src/AppInstallationPhase.swift"
    "${PROJECT_SOURCE_DIR}/src/AppInstallationStore.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorOperationMonitor.swift"
    "${PROJECT_SOURCE_DIR}/src/AppUpdateBatch.swift"
    "${PROJECT_SOURCE_DIR}/src/AppInstallationAction.swift"
    "${PROJECT_SOURCE_DIR}/src/AppInstallButton.swift"
    "${PROJECT_SOURCE_DIR}/src/CatalogPresentation.swift"
    "${PROJECT_SOURCE_DIR}/src/CatalogCategory.swift"
    "${PROJECT_SOURCE_DIR}/src/IconCache.swift"
    "${PROJECT_SOURCE_DIR}/src/DownloadProgressView.swift"
    "${PROJECT_SOURCE_DIR}/src/StableSizeView.swift"
    "${PROJECT_SOURCE_DIR}/src/InstalledAppsStore.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorApplications.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorDiscovery.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorState.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorStore.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorControl.swift"
    "${PROJECT_SOURCE_DIR}/src/Command.swift"
)
target_compile_options(SimStoreInstallationTest PRIVATE -parse-as-library)
add_test(NAME installation COMMAND SimStoreInstallationTest)
set_tests_properties(installation PROPERTIES TIMEOUT 30 RUN_SERIAL TRUE)

add_executable(SimStoreDiscoveryTest SimulatorDiscoveryTests.swift
    "${PROJECT_SOURCE_DIR}/src/SimulatorDiscovery.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorState.swift"
    "${PROJECT_SOURCE_DIR}/src/Command.swift"
)
add_test(NAME simulator-discovery COMMAND SimStoreDiscoveryTest)
set_tests_properties(simulator-discovery PROPERTIES TIMEOUT 15)

add_executable(SimStoreControlTest SimulatorControlTests.swift
    "${PROJECT_SOURCE_DIR}/src/Command.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorControl.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorPresenter.swift"
)
target_compile_options(SimStoreControlTest PRIVATE -parse-as-library)
add_test(NAME simulator-control COMMAND SimStoreControlTest)
set_tests_properties(simulator-control PROPERTIES TIMEOUT 15)

add_executable(SimStoreApplicationsTest SimulatorApplicationsTests.swift
    "${PROJECT_SOURCE_DIR}/src/SimulatorApplications.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorDiscovery.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorState.swift"
    "${PROJECT_SOURCE_DIR}/src/Command.swift"
)
target_compile_options(SimStoreApplicationsTest PRIVATE -parse-as-library)
add_test(NAME simulator-applications COMMAND SimStoreApplicationsTest)
set_tests_properties(simulator-applications PROPERTIES TIMEOUT 15)

add_executable(SimStoreInstalledAppsTest InstalledAppsStoreTests.swift
    "${PROJECT_SOURCE_DIR}/src/SimulatorOperationMonitor.swift"
    "${PROJECT_SOURCE_DIR}/src/InstalledAppsStore.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorApplications.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorDiscovery.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorState.swift"
    "${PROJECT_SOURCE_DIR}/src/Command.swift"
    "${PROJECT_SOURCE_DIR}/src/AppCatalog.swift"
)
target_compile_options(SimStoreInstalledAppsTest PRIVATE -parse-as-library)
add_test(NAME installed-apps COMMAND SimStoreInstalledAppsTest)
set_tests_properties(installed-apps PROPERTIES TIMEOUT 15)

add_executable(SimStoreOperationMonitorTest SimulatorOperationMonitorTests.swift
    "${PROJECT_SOURCE_DIR}/src/SimulatorOperationMonitor.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorRecoveryAlert.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorDiscovery.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorState.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorStore.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorControl.swift"
    "${PROJECT_SOURCE_DIR}/src/Command.swift"
)
target_compile_options(SimStoreOperationMonitorTest PRIVATE -parse-as-library)
add_test(NAME simulator-operation-monitor COMMAND SimStoreOperationMonitorTest)
set_tests_properties(simulator-operation-monitor PROPERTIES TIMEOUT 20 RUN_SERIAL TRUE)

add_executable(SimStoreStoreTest SimulatorStoreTests.swift SimulatorShutdownTests.swift
    "${PROJECT_SOURCE_DIR}/src/SimulatorDiscovery.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorState.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorStore.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorControl.swift"
    "${PROJECT_SOURCE_DIR}/src/Command.swift"
)
target_compile_options(SimStoreStoreTest PRIVATE -parse-as-library)
add_test(NAME simulator-store COMMAND SimStoreStoreTest)
set_tests_properties(simulator-store PROPERTIES TIMEOUT 15)

add_executable(SimStoreLocalizationTest LocalizationTests.swift)
add_dependencies(SimStoreLocalizationTest SimStore)
target_compile_options(SimStoreLocalizationTest PRIVATE -parse-as-library)
add_test(NAME localization COMMAND SimStoreLocalizationTest "$<TARGET_BUNDLE_DIR:SimStore>")
set_tests_properties(localization PROPERTIES TIMEOUT 10)

add_executable(SimStoreStableSizeTest StableSizeViewTests.swift "${PROJECT_SOURCE_DIR}/src/StableSizeView.swift")
add_dependencies(SimStoreStableSizeTest SimStore)
target_compile_options(SimStoreStableSizeTest PRIVATE -parse-as-library)
add_test(NAME stable-button-size COMMAND SimStoreStableSizeTest "$<TARGET_BUNDLE_DIR:SimStore>")
set_tests_properties(stable-button-size PROPERTIES TIMEOUT 15 RUN_SERIAL TRUE)

add_executable(SimStorePowerButtonTest SimulatorPowerButtonTests.swift
    "${PROJECT_SOURCE_DIR}/src/SimulatorPowerButton.swift"
    "${PROJECT_SOURCE_DIR}/src/StableSizeView.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorDiscovery.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorState.swift"
    "${PROJECT_SOURCE_DIR}/src/Command.swift"
)
target_compile_options(SimStorePowerButtonTest PRIVATE -parse-as-library)
add_test(NAME simulator-power-button COMMAND SimStorePowerButtonTest)
set_tests_properties(simulator-power-button PROPERTIES TIMEOUT 15 RUN_SERIAL TRUE)

add_executable(SimStoreSidebarSelectionTest SidebarSelectionTests.swift
    "${PROJECT_SOURCE_DIR}/src/SidebarView.swift"
    "${PROJECT_SOURCE_DIR}/src/LibrarySection.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorDiscovery.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorState.swift"
    "${PROJECT_SOURCE_DIR}/src/SimulatorDevicePresentation.swift"
    "${PROJECT_SOURCE_DIR}/src/Command.swift"
)
target_compile_options(SimStoreSidebarSelectionTest PRIVATE -parse-as-library)
add_test(NAME sidebar-selection COMMAND SimStoreSidebarSelectionTest)
set_tests_properties(sidebar-selection PROPERTIES TIMEOUT 15 RUN_SERIAL TRUE)

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    add_executable(SimStorePreviewScenarioTest PreviewScenarioTests.swift
        "${PROJECT_SOURCE_DIR}/src/PreviewScenario.swift"
        "${PROJECT_SOURCE_DIR}/src/SimulatorDiscovery.swift"
        "${PROJECT_SOURCE_DIR}/src/SimulatorState.swift"
        "${PROJECT_SOURCE_DIR}/src/Command.swift"
    )
    target_compile_definitions(SimStorePreviewScenarioTest PRIVATE DEBUG)
    target_compile_options(SimStorePreviewScenarioTest PRIVATE -parse-as-library)
    add_test(NAME preview-scenarios COMMAND SimStorePreviewScenarioTest)
    set_tests_properties(preview-scenarios PROPERTIES TIMEOUT 15)
endif()

execute_process(COMMAND xcrun --sdk "${CMAKE_OSX_SYSROOT}" --show-sdk-version
    OUTPUT_VARIABLE SDK_VERSION
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY
)
add_test(NAME bundle-metadata COMMAND "${CMAKE_COMMAND}"
    "-DEXECUTABLE=$<TARGET_FILE:SimStore>"
    "-DINFO_PLIST=$<TARGET_BUNDLE_DIR:SimStore>/Contents/Info.plist"
    "-DEXPECTED_SDK=${SDK_VERSION}"
    "-DEXPECTED_MIN_OS=${CMAKE_OSX_DEPLOYMENT_TARGET}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/BundleMetadataTest.cmake"
)

add_test(NAME bundle-version COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/scripts/version.py" check --source "${PROJECT_SOURCE_DIR}"
    --plist "$<TARGET_BUNDLE_DIR:SimStore>/Contents/Info.plist"
)
set_tests_properties(bundle-version PROPERTIES TIMEOUT 10)

add_test(NAME release-workflow COMMAND "${Python3_EXECUTABLE}" -m unittest discover
    -s "${CMAKE_CURRENT_SOURCE_DIR}" -p "test_*.py"
)
set_tests_properties(release-workflow PROPERTIES TIMEOUT 60)

add_executable(SimStoreSelfUpdateTest
    SelfUpdateTests.swift SelfUpdateFixtures.swift SelfUpdateModelTests.swift
    SelfUpdatePackageTests.swift SelfUpdateInstallerTests.swift SelfUpdateStoreTests.swift
    SelfUpdateViewTests.swift
    "${PROJECT_SOURCE_DIR}/src/SelfUpdateRelease.swift"
    "${PROJECT_SOURCE_DIR}/src/SelfUpdateClient.swift"
    "${PROJECT_SOURCE_DIR}/src/SelfUpdatePackage.swift"
    "${PROJECT_SOURCE_DIR}/src/SelfUpdateInstallation.swift"
    "${PROJECT_SOURCE_DIR}/src/SelfUpdater.swift"
    "${PROJECT_SOURCE_DIR}/src/SelfUpdateStore.swift"
    "${PROJECT_SOURCE_DIR}/src/SelfUpdateView.swift"
    "${PROJECT_SOURCE_DIR}/src/SelfUpdateController.swift"
    "${PROJECT_SOURCE_DIR}/src/AppCatalog.swift"
    "${PROJECT_SOURCE_DIR}/src/AppConfiguration.swift"
    "${PROJECT_SOURCE_DIR}/src/AppDownload.swift"
    "${PROJECT_SOURCE_DIR}/src/AppPackage.swift"
    "${PROJECT_SOURCE_DIR}/src/MachOValidation.swift"
    "${PROJECT_SOURCE_DIR}/src/Command.swift"
    "${PROJECT_SOURCE_DIR}/src/AppInstallationPhase.swift"
    "${PROJECT_SOURCE_DIR}/src/DownloadProgressView.swift"
    "${PROJECT_SOURCE_DIR}/src/StableSizeView.swift"
)
target_compile_options(SimStoreSelfUpdateTest PRIVATE -parse-as-library)
add_test(NAME self-update COMMAND SimStoreSelfUpdateTest)
set_tests_properties(self-update PROPERTIES TIMEOUT 60 RUN_SERIAL TRUE)

add_executable(SimStoreSelfUpdateIntegrationTest
    SelfUpdateIntegrationTest.swift SelfUpdateFixtures.swift
    "${PROJECT_SOURCE_DIR}/src/SelfUpdateRelease.swift"
    "${PROJECT_SOURCE_DIR}/src/SelfUpdatePackage.swift"
    "${PROJECT_SOURCE_DIR}/src/SelfUpdateInstallation.swift"
    "${PROJECT_SOURCE_DIR}/src/AppCatalog.swift"
    "${PROJECT_SOURCE_DIR}/src/MachOValidation.swift"
    "${PROJECT_SOURCE_DIR}/src/Command.swift"
)
add_dependencies(SimStoreSelfUpdateIntegrationTest SimStore)
target_compile_options(SimStoreSelfUpdateIntegrationTest PRIVATE -parse-as-library)
add_test(NAME self-update-integration COMMAND SimStoreSelfUpdateIntegrationTest "$<TARGET_BUNDLE_DIR:SimStore>")
set_tests_properties(self-update-integration PROPERTIES TIMEOUT 60 RUN_SERIAL TRUE)

add_test(NAME update-assistant-metadata COMMAND "${CMAKE_COMMAND}"
    "-DEXECUTABLE=$<TARGET_FILE:SimStoreUpdater>"
    "-DINFO_PLIST=$<TARGET_BUNDLE_DIR:SimStore>/Contents/Info.plist"
    "-DEXPECTED_SDK=${SDK_VERSION}"
    "-DEXPECTED_MIN_OS=${CMAKE_OSX_DEPLOYMENT_TARGET}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/BundleMetadataTest.cmake"
)

add_executable(SimStoreSelfUninstallTest SelfUninstallTests.swift
    "${PROJECT_SOURCE_DIR}/src/SelfUninstallation.swift"
    "${PROJECT_SOURCE_DIR}/src/SelfUninstaller.swift"
    "${PROJECT_SOURCE_DIR}/src/SelfUninstallController.swift"
    "${PROJECT_SOURCE_DIR}/src/AppConfiguration.swift"
)
add_dependencies(SimStoreSelfUninstallTest SimStore)
target_compile_options(SimStoreSelfUninstallTest PRIVATE -parse-as-library)
add_test(NAME self-uninstall COMMAND SimStoreSelfUninstallTest "$<TARGET_BUNDLE_DIR:SimStore>")
set_tests_properties(self-uninstall PROPERTIES TIMEOUT 60 RUN_SERIAL TRUE)
