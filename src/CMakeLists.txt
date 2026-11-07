add_executable(SimStore MACOSX_BUNDLE
    AppDelegate.swift
    AppConfiguration.swift
    Command.swift
    SimStoreApp.swift
    SimulatorDiscovery.swift
    SimulatorState.swift
    SimulatorControl.swift
    SimulatorPresenter.swift
    SimulatorApplications.swift
    InstalledAppsStore.swift
    InstalledAppsStatusView.swift
    SimulatorStore.swift
    SimulatorDevicePresentation.swift
    SimulatorSelectionViews.swift
    SimulatorPowerButton.swift
    SimulatorOperationMonitor.swift
    SimulatorRecoveryAlert.swift
    ContentView.swift
    LibrarySection.swift
    AppCatalog.swift
    CatalogCategory.swift
    AppDownload.swift
    AppPackage.swift
    PackagePipeline.swift
    MachOValidation.swift
    BundleValidator.swift
    AppInstaller.swift
    AppInstallationPhase.swift
    AppInstallationStore.swift
    AppUpdateBatch.swift
    AppUpdateBatchView.swift
    AppInstallationAction.swift
    AppInstallButton.swift
    AppUninstallButton.swift
    DownloadProgressView.swift
    CatalogClient.swift
    CatalogStore.swift
    CatalogPresentation.swift
    IconCache.swift
    CatalogBrowserView.swift
    CatalogAppCard.swift
    CatalogAppGrid.swift
    CatalogAppDetailView.swift
    CopyableText.swift
    DetailsDisclosureStyle.swift
    SidebarView.swift
    NoSimulatorsView.swift
    MissingXcodeView.swift
    SimulatorStatusViews.swift
    StableSizeView.swift
    SimulatorCheckButton.swift
    PreviewScenario.swift
    SelfUpdateRelease.swift
    SelfUpdateClient.swift
    SelfUpdatePackage.swift
    SelfUpdateInstallation.swift
    SelfUpdater.swift
    SelfUpdateStore.swift
    SelfUpdateView.swift
    SelfUpdateController.swift
    SelfUninstallation.swift
    SelfUninstaller.swift
    SelfUninstallController.swift
)

add_executable(SimStoreUpdater
    SelfUpdateHelper.swift
    SelfUninstallation.swift
    SelfUpdateInstallation.swift
    SelfUpdateRelease.swift
    SelfUpdatePackage.swift
    MachOValidation.swift
    BundleValidator.swift
    AppCatalog.swift
)
set(UPDATE_HELPER "${CMAKE_CURRENT_BINARY_DIR}/updater/SimStoreUpdater")
set_target_properties(SimStoreUpdater PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/updater"
    Swift_MODULE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/updater/modules"
)
target_link_options(SimStoreUpdater PRIVATE
    "SHELL:-Xclang-linker -isysroot -Xclang-linker \"${CMAKE_OSX_SYSROOT}\""
)
set_source_files_properties("${UPDATE_HELPER}" PROPERTIES
    GENERATED TRUE MACOSX_PACKAGE_LOCATION Helpers
)
target_sources(SimStore PRIVATE "${UPDATE_HELPER}")
add_dependencies(SimStore SimStoreUpdater)

target_compile_definitions(SimStore PRIVATE "$<$<CONFIG:Debug>:DEBUG>")

include("${PROJECT_SOURCE_DIR}/cmake/Localization.cmake")

find_program(RSVG_CONVERT_EXECUTABLE rsvg-convert REQUIRED)
find_program(ICONUTIL_EXECUTABLE iconutil REQUIRED)
set(ICONSET_DIR "${CMAKE_CURRENT_BINARY_DIR}/simstore.iconset")
set(ICON_FILE "${CMAKE_CURRENT_BINARY_DIR}/simstore.icns")
set(ICON_COMMANDS)
foreach(SIZE 16 32 128 256 512)
    math(EXPR RETINA_SIZE "${SIZE} * 2")
    list(APPEND ICON_COMMANDS
        COMMAND "${RSVG_CONVERT_EXECUTABLE}" --width "${SIZE}" --height "${SIZE}"
            --output "${ICONSET_DIR}/icon_${SIZE}x${SIZE}.png" "${PROJECT_SOURCE_DIR}/assets/simstore.svg"
        COMMAND "${RSVG_CONVERT_EXECUTABLE}" --width "${RETINA_SIZE}" --height "${RETINA_SIZE}"
            --output "${ICONSET_DIR}/icon_${SIZE}x${SIZE}@2x.png" "${PROJECT_SOURCE_DIR}/assets/simstore.svg"
    )
endforeach()
add_custom_command(OUTPUT "${ICON_FILE}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${ICONSET_DIR}"
    ${ICON_COMMANDS}
    COMMAND "${ICONUTIL_EXECUTABLE}" --convert icns --output "${ICON_FILE}" "${ICONSET_DIR}"
    DEPENDS "${PROJECT_SOURCE_DIR}/assets/simstore.svg"
    VERBATIM
)
set_source_files_properties("${ICON_FILE}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
target_sources(SimStore PRIVATE "${ICON_FILE}")

# Preserve the SDK version in LC_BUILD_VERSION when invoking swiftc directly.
target_link_options(SimStore PRIVATE
    "SHELL:-Xclang-linker -isysroot -Xclang-linker \"${CMAKE_OSX_SYSROOT}\""
)
set_target_properties(SimStore PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${PROJECT_SOURCE_DIR}/cmake/Info.plist.in"
    MACOSX_BUNDLE_BUNDLE_NAME SimStore
    MACOSX_BUNDLE_GUI_IDENTIFIER io.simstore.SimStore
    MACOSX_BUNDLE_ICON_FILE simstore.icns
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    MACOSX_BUNDLE_BUNDLE_VERSION "${SIMSTORE_BUILD}"
    RUNTIME_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}"
    Swift_MODULE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/modules"
)
add_custom_target(StampVersion
    COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/scripts/version.py"
        stamp --source "${PROJECT_SOURCE_DIR}"
        --plist "$<TARGET_BUNDLE_DIR:SimStore>/Contents/Info.plist"
    COMMENT "Updating bundle version from Git"
    VERBATIM
)
add_dependencies(SimStore StampVersion)
add_custom_command(TARGET SimStore POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E rm -f "$<TARGET_BUNDLE_DIR:SimStore>/Contents/MacOS/SimStore.d"
    VERBATIM
)
