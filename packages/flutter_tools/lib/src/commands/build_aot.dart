// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/process.dart';
import '../base/process_manager.dart';
import '../base/utils.dart';
import '../build_info.dart';
import '../dart/package_map.dart';
import '../globals.dart';
import '../resident_runner.dart';
import 'build.dart';

// Files generated by the ahead-of-time snapshot builder.
const List<String> kAotSnapshotFiles = const <String>[
  'vm_snapshot_data', 'vm_snapshot_instr', 'isolate_snapshot_data', 'isolate_snapshot_instr',
];

class BuildAotCommand extends BuildSubCommand {
  BuildAotCommand() {
    usesTargetOption();
    addBuildModeFlags();
    usesPubOption();
    argParser
      ..addOption('output-dir', defaultsTo: getAotBuildDirectory())
      ..addOption('target-platform',
        defaultsTo: 'android-arm',
        allowed: <String>['android-arm', 'ios']
      )
      ..addFlag('interpreter');
  }

  @override
  final String name = 'aot';

  @override
  final String description = "Build an ahead-of-time compiled snapshot of your app's Dart code.";

  @override
  Future<Null> runCommand() async {
    await super.runCommand();
    String targetPlatform = argResults['target-platform'];
    TargetPlatform platform = getTargetPlatformForName(targetPlatform);
    if (platform == null)
      throwToolExit('Unknown platform: $targetPlatform');

    String typeName = artifacts.getEngineType(platform, getBuildMode());
    Status status = logger.startProgress('Building AOT snapshot in ${getModeName(getBuildMode())} mode ($typeName)...',
        expectSlowOperation: true);
    String outputPath = await buildAotSnapshot(
      findMainDartFile(targetFile),
      platform,
      getBuildMode(),
      outputPath: argResults['output-dir'],
      interpreter: argResults['interpreter']
    );
    status.stop();

    if (outputPath == null)
      throwToolExit(null);

    printStatus('Built to $outputPath${fs.path.separator}.');
  }
}

String _getSdkExtensionPath(PackageMap packageMap, String package) {
  return fs.path.dirname(packageMap.map[package].toFilePath());
}

/// Build an AOT snapshot. Return `null` (and log to `printError`) if the method
/// fails.
Future<String> buildAotSnapshot(
  String mainPath,
  TargetPlatform platform,
  BuildMode buildMode, {
  String outputPath,
  bool interpreter: false
}) async {
  outputPath ??= getAotBuildDirectory();
  try {
    return _buildAotSnapshot(
      mainPath,
      platform,
      buildMode,
      outputPath: outputPath,
      interpreter: interpreter
    );
  } on String catch (error) {
    // Catch the String exceptions thrown from the `runCheckedSync` methods below.
    printError(error);
    return null;
  }
}

Future<String> _buildAotSnapshot(
  String mainPath,
  TargetPlatform platform,
  BuildMode buildMode, {
  String outputPath,
  bool interpreter: false
}) async {
  outputPath ??= getAotBuildDirectory();
  if (!isAotBuildMode(buildMode) && !interpreter) {
    printError('${toTitleCase(getModeName(buildMode))} mode does not support AOT compilation.');
    return null;
  }

  if (platform != TargetPlatform.android_arm && platform != TargetPlatform.ios) {
    printError('${getNameForTargetPlatform(platform)} does not support AOT compilation.');
    return null;
  }

  String genSnapshot = artifacts.getArtifactPath(Artifact.genSnapshot, platform, buildMode);

  Directory outputDir = fs.directory(outputPath);
  outputDir.createSync(recursive: true);
  String vmSnapshotData = fs.path.join(outputDir.path, 'vm_snapshot_data');
  String vmSnapshotInstructions = fs.path.join(outputDir.path, 'vm_snapshot_instr');
  String isolateSnapshotData = fs.path.join(outputDir.path, 'isolate_snapshot_data');
  String isolateSnapshotInstructions = fs.path.join(outputDir.path, 'isolate_snapshot_instr');

  String vmEntryPoints = artifacts.getArtifactPath(Artifact.dartVmEntryPointsTxt, platform, buildMode);
  String ioEntryPoints = artifacts.getArtifactPath(Artifact.dartIoEntriesTxt, platform, buildMode);

  PackageMap packageMap = new PackageMap(PackageMap.globalPackagesPath);
  String packageMapError = packageMap.checkValid();
  if (packageMapError != null) {
    printError(packageMapError);
    return null;
  }

  String skyEnginePkg = _getSdkExtensionPath(packageMap, 'sky_engine');
  String uiPath = fs.path.join(skyEnginePkg, 'dart_ui', 'ui.dart');
  String jniPath = fs.path.join(skyEnginePkg, 'dart_jni', 'jni.dart');
  String vmServicePath = fs.path.join(skyEnginePkg, 'sdk_ext', 'vmservice_io.dart');

  List<String> filePaths = <String>[
    vmEntryPoints,
    ioEntryPoints,
    uiPath,
    jniPath,
    vmServicePath,
  ];

  // These paths are used only on Android.
  String vmEntryPointsAndroid;

  // These paths are used only on iOS.
  String snapshotDartIOS;
  String assembly;

  switch (platform) {
    case TargetPlatform.android_arm:
    case TargetPlatform.android_x64:
    case TargetPlatform.android_x86:
      vmEntryPointsAndroid = artifacts.getArtifactPath(Artifact.dartVmEntryPointsAndroidTxt, platform, buildMode);
      filePaths.addAll(<String>[
        vmEntryPointsAndroid,
      ]);
      break;
    case TargetPlatform.ios:
      snapshotDartIOS = artifacts.getArtifactPath(Artifact.snapshotDart, platform, buildMode);
      assembly = fs.path.join(outputDir.path, 'snapshot_assembly.S');
      filePaths.addAll(<String>[
        snapshotDartIOS,
      ]);
      break;
    case TargetPlatform.darwin_x64:
    case TargetPlatform.linux_x64:
    case TargetPlatform.windows_x64:
      assert(false);
  }

  List<String> missingFiles = filePaths.where((String p) => !fs.isFileSync(p)).toList();
  if (missingFiles.isNotEmpty) {
    printError('Missing files: $missingFiles');
    return null;
  }
  if (!processManager.canRun(genSnapshot)) {
    printError('Cannot locate the genSnapshot executable');
    return null;
  }

  List<String> genSnapshotCmd = <String>[
    genSnapshot,
    '--assert_initializer',
    '--await_is_keyword',
    '--vm_snapshot_data=$vmSnapshotData',
    '--isolate_snapshot_data=$isolateSnapshotData',
    '--packages=${packageMap.packagesPath}',
    '--url_mapping=dart:ui,$uiPath',
    '--url_mapping=dart:jni,$jniPath',
    '--url_mapping=dart:vmservice_sky,$vmServicePath',
    '--print_snapshot_sizes',
  ];

  if (!interpreter) {
    genSnapshotCmd.add('--embedder_entry_points_manifest=$vmEntryPoints');
    genSnapshotCmd.add('--embedder_entry_points_manifest=$ioEntryPoints');
  }

  switch (platform) {
    case TargetPlatform.android_arm:
    case TargetPlatform.android_x64:
    case TargetPlatform.android_x86:
      genSnapshotCmd.addAll(<String>[
        '--snapshot_kind=app-aot-blobs',
        '--vm_snapshot_instructions=$vmSnapshotInstructions',
        '--isolate_snapshot_instructions=$isolateSnapshotInstructions',
        '--embedder_entry_points_manifest=$vmEntryPointsAndroid',
        '--no-sim-use-hardfp',  // Android uses the softfloat ABI.
        '--no-use-integer-division',  // Not supported by the Pixel in 32-bit mode.
      ]);
      break;
    case TargetPlatform.ios:
      if (interpreter) {
        genSnapshotCmd.add('--snapshot_kind=core');
        genSnapshotCmd.add(snapshotDartIOS);
      } else {
        genSnapshotCmd.add('--snapshot_kind=app-aot-assembly');
        genSnapshotCmd.add('--assembly=$assembly');
      }
      break;
    case TargetPlatform.darwin_x64:
    case TargetPlatform.linux_x64:
    case TargetPlatform.windows_x64:
      assert(false);
  }

  if (buildMode != BuildMode.release) {
    genSnapshotCmd.addAll(<String>[
      '--no-checked',
      '--conditional_directives',
    ]);
  }

  genSnapshotCmd.add(mainPath);

  RunResult results = await runAsync(genSnapshotCmd);
  if (results.exitCode != 0) {
    printError('Dart snapshot generator failed with exit code ${results.exitCode}');
    printError(results.toString());
    return null;
  }

  // On iOS, we use Xcode to compile the snapshot into a dynamic library that the
  // end-developer can link into their app.
  if (platform == TargetPlatform.ios) {
    printStatus('Building app.dylib...');

    // These names are known to from the engine.
    String kVmSnapshotData = 'kDartVmSnapshotData';
    String kIsolateSnapshotData = 'kDartIsolateSnapshotData';

    String kVmSnapshotDataC = fs.path.join(outputDir.path, '$kVmSnapshotData.c');
    String kIsolateSnapshotDataC = fs.path.join(outputDir.path, '$kIsolateSnapshotData.c');
    String kVmSnapshotDataO = fs.path.join(outputDir.path, '$kVmSnapshotData.o');
    String kIsolateSnapshotDataO = fs.path.join(outputDir.path, '$kIsolateSnapshotData.o');
    String assemblyO = fs.path.join(outputDir.path, 'snapshot_assembly.o');

    List<String> commonBuildOptions = <String>['-arch', 'arm64', '-miphoneos-version-min=8.0'];

    if (interpreter) {
      runCheckedSync(<String>['mv', vmSnapshotData, fs.path.join(outputDir.path, kVmSnapshotData)]);
      runCheckedSync(<String>['mv', isolateSnapshotData, fs.path.join(outputDir.path, kIsolateSnapshotData)]);

      runCheckedSync(<String>[
        'xxd', '--include', kVmSnapshotData, fs.path.basename(kVmSnapshotDataC)
      ], workingDirectory: outputDir.path);
      runCheckedSync(<String>[
        'xxd', '--include', kIsolateSnapshotData, fs.path.basename(kIsolateSnapshotDataC)
      ], workingDirectory: outputDir.path);

      runCheckedSync(<String>['xcrun', 'cc']
        ..addAll(commonBuildOptions)
        ..addAll(<String>['-c', kVmSnapshotDataC, '-o', kVmSnapshotDataO]));
      runCheckedSync(<String>['xcrun', 'cc']
        ..addAll(commonBuildOptions)
        ..addAll(<String>['-c', kIsolateSnapshotDataC, '-o', kIsolateSnapshotDataO]));
    } else {
      runCheckedSync(<String>['xcrun', 'cc']
        ..addAll(commonBuildOptions)
        ..addAll(<String>['-c', assembly, '-o', assemblyO]));
    }

    String appSo = fs.path.join(outputDir.path, 'app.dylib');

    List<String> linkCommand = <String>['xcrun', 'clang']
      ..addAll(commonBuildOptions)
      ..addAll(<String>[
        '-dynamiclib',
        '-Xlinker', '-rpath', '-Xlinker', '@executable_path/Frameworks',
        '-Xlinker', '-rpath', '-Xlinker', '@loader_path/Frameworks',
        '-install_name', '@rpath/app.dylib',
        '-o', appSo,
    ]);
    if (interpreter) {
      linkCommand.add(kVmSnapshotDataO);
      linkCommand.add(kIsolateSnapshotDataO);
    } else {
      linkCommand.add(assemblyO);
    }
    runCheckedSync(linkCommand);
  }

  return outputPath;
}
