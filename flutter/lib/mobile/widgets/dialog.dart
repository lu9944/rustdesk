import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/setting_widgets.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

void _showSuccess() {
  showToast(translate("Successful"));
}

void setTemporaryPasswordLengthDialog(
    OverlayDialogManager dialogManager) async {
  List<String> lengths = ['6', '8', '10'];
  String length = await bind.mainGetOption(key: "temporary-password-length");
  var index = lengths.indexOf(length);
  if (index < 0) index = 0;
  length = lengths[index];
  dialogManager.show((setState, close, context) {
    setLength(newValue) {
      final oldValue = length;
      if (oldValue == newValue) return;
      setState(() {
        length = newValue;
      });
      bind.mainSetOption(key: "temporary-password-length", value: newValue);
      bind.mainUpdateTemporaryPassword();
      Future.delayed(Duration(milliseconds: 200), () {
        close();
        _showSuccess();
      });
    }

    return CustomAlertDialog(
      title: Text(translate("Set one-time password length")),
      content: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: lengths
              .map(
                (value) => Row(
                  children: [
                    Text(value),
                    Radio(
                        value: value, groupValue: length, onChanged: setLength),
                  ],
                ),
              )
              .toList()),
    );
  }, backDismiss: true, clickMaskDismiss: true);
}

void showServerSettings(OverlayDialogManager dialogManager,
    void Function(VoidCallback) setState) async {
  Map<String, dynamic> options = {};
  try {
    options = jsonDecode(await bind.mainGetOptions());
  } catch (e) {
    print("Invalid server config: $e");
  }
  showServerSettingsWithValue(
      ServerConfig.fromOptions(options), dialogManager, setState);
}

/// Confirmation dialog used by the server-config presets UI. Returns `true`
/// only when the user explicitly presses OK.
Future<bool> showPresetConfirmDialog(
  OverlayDialogManager dialogManager,
  String title,
  String body,
) async {
  final result = await dialogManager.show<bool>((setState, close, context) {
    return CustomAlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        dialogButton('Cancel', onPressed: () => close(false), isOutline: true),
        dialogButton('OK', onPressed: () => close(true)),
      ],
    );
  }, backDismiss: true, clickMaskDismiss: true);
  return result ?? false;
}

void showServerSettingsWithValue(
  ServerConfig serverConfig,
  OverlayDialogManager dialogManager,
  void Function(VoidCallback)? upSetState) async {
  var isInProgress = false;
  final idCtrl = TextEditingController(text: serverConfig.idServer);
  final relayCtrl = TextEditingController(text: serverConfig.relayServer);
  final apiCtrl = TextEditingController(text: serverConfig.apiServer);
  final keyCtrl = TextEditingController(text: serverConfig.key);

  RxString idServerMsg = ''.obs;
  RxString relayServerMsg = ''.obs;
  RxString apiServerMsg = ''.obs;

  final controllers = [idCtrl, relayCtrl, apiCtrl, keyCtrl];
  final errMsgs = [
    idServerMsg,
    relayServerMsg,
    apiServerMsg,
  ];

  // Multi-server preset state (kept in Rx so the dialog rebuilds on change).
  // Read synchronously so the dialog opens without an async hop that would
  // make the UI feel frozen between the button tap and the dialog appearing.
  final RxList<ServerConfigPreset> presets =
      getServerConfigPresets().obs;
  final RxString activePreset = getActiveServerConfigPreset().obs;

  // Inline-editing state. We edit names *inline* (not in a stacked popup)
  // because the server-settings dialog uses CustomAlertDialog, whose
  // `build()` recreates a FocusScopeNode on every rebuild
  // (`common.dart:1104-1107`). Any stacked child dialog inherits that
  // focus-thrash, which on macOS triggers "select all on programmatic
  // focus" and makes every keystroke overwrite the whole field. Keeping
  // the TextField in the *same* dialog avoids this entirely.
  final RxBool isAddingPreset = false.obs;
  final TextEditingController newPresetNameCtrl = TextEditingController();
  final RxString renamingPreset = ''.obs;
  final TextEditingController renameCtrl = TextEditingController();

  dialogManager.show((setState, close, context) {
    Future<bool> submit() async {
      setState(() {
        isInProgress = true;
      });
      bool ret = await setServerConfig(
          null,
          errMsgs,
          ServerConfig(
              idServer: idCtrl.text.trim(),
              relayServer: relayCtrl.text.trim(),
              apiServer: apiCtrl.text.trim(),
              key: keyCtrl.text.trim()));
      setState(() {
        isInProgress = false;
      });
      return ret;
    }

    Widget buildField(
        String label, TextEditingController controller, String errorMsg,
        {String? Function(String?)? validator, bool autofocus = false}) {
      if (isDesktop || isWeb) {
        return Row(
          children: [
            SizedBox(
              width: 120,
              child: Text(label),
            ),
            SizedBox(width: 8),
            Expanded(
              child: serverSettingsTextFormField(
                label: label,
                controller: controller,
                errorMsg: errorMsg,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                showLabelText: false,
                validator: validator,
                autofocus: autofocus,
              ).workaroundFreezeLinuxMint(),
            ),
          ],
        );
      }

      return serverSettingsTextFormField(
        label: label,
        controller: controller,
        errorMsg: errorMsg,
        validator: validator,
      ).workaroundFreezeLinuxMint();
    }

    // --- preset actions -------------------------------------------------

    ServerConfig currentAsConfig() => ServerConfig(
          idServer: idCtrl.text.trim(),
          relayServer: relayCtrl.text.trim(),
          apiServer: apiCtrl.text.trim(),
          key: keyCtrl.text.trim(),
        );

    void startAddPreset() {
      newPresetNameCtrl.clear();
      isAddingPreset.value = true;
    }

    Future<void> confirmAddPreset() async {
      final name = newPresetNameCtrl.text.trim();
      if (name.isEmpty) return;
      final existing = presets.firstWhereOrNull((p) => p.name == name);
      if (existing != null) {
        final ok = await showPresetConfirmDialog(
          dialogManager,
          translate('Overwrite'),
          '"$name" ${translate('Already exists, overwrite?')}',
        );
        if (!ok) return;
        final cfg = currentAsConfig();
        existing
          ..idServer = cfg.idServer
          ..relayServer = cfg.relayServer
          ..apiServer = cfg.apiServer
          ..key = cfg.key;
      } else {
        presets.add(
            ServerConfigPreset.fromServerConfig(name, currentAsConfig()));
      }
      await setServerConfigPresets(presets.toList());
      isAddingPreset.value = false;
      showToast(translate('Successful'));
    }

    void cancelAddPreset() {
      isAddingPreset.value = false;
    }

    Future<void> applyPreset(ServerConfigPreset p) async {
      idCtrl.text = p.idServer;
      relayCtrl.text = p.relayServer;
      apiCtrl.text = p.apiServer;
      keyCtrl.text = p.key;
      // Bypass reachability validation: the user is intentionally switching
      // presets, and the target server is expected to be unreachable from
      // some networks (e.g. an intranet-only preset while currently online
      // via the public internet). The validation in setServerConfig is gated
      // on `errMsgs != null`, so passing null skips it.
      final ok = await setServerConfig(
        null,
        null,
        ServerConfig(
          idServer: p.idServer,
          relayServer: p.relayServer,
          apiServer: p.apiServer,
          key: p.key,
        ),
      );
      if (ok) {
        await setActiveServerConfigPreset(p.name);
        activePreset.value = p.name;
        showToast(translate('Successful'));
        upSetState?.call(() {});
      } else {
        showToast(translate('Failed'));
      }
    }

    void startRename(ServerConfigPreset p) {
      renameCtrl.text = p.name;
      renamingPreset.value = p.name;
    }

    Future<void> confirmRename(ServerConfigPreset p) async {
      final name = renameCtrl.text.trim();
      if (name.isEmpty || name == p.name) {
        renamingPreset.value = '';
        return;
      }
      if (presets.any((e) => e.name == name && e != p)) {
        showToast(translate('Already exists'));
        return;
      }
      final wasActive = activePreset.value == p.name;
      p.name = name;
      await setServerConfigPresets(presets.toList());
      if (wasActive) {
        await setActiveServerConfigPreset(name);
        activePreset.value = name;
      }
      renamingPreset.value = '';
    }

    void cancelRename() {
      renamingPreset.value = '';
    }

    Future<void> deletePreset(ServerConfigPreset p) async {
      final ok = await showPresetConfirmDialog(
        dialogManager,
        translate('Delete'),
        '"${p.name}" ${translate('Are you sure you want to delete this preset?')}',
      );
      if (!ok) return;
      presets.remove(p);
      await setServerConfigPresets(presets.toList());
      if (activePreset.value == p.name) {
        await setActiveServerConfigPreset('');
        activePreset.value = '';
      }
    }

    // --- preset section widget -----------------------------------------

    Widget buildPresetTile(ServerConfigPreset p) {
      final isActive = activePreset.value == p.name;
      final isRenaming = renamingPreset.value == p.name;
      final subtitle = p.idServer.isEmpty
          ? translate('Using public server')
          : p.idServer;
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          isActive ? Icons.check_circle : Icons.radio_button_unchecked,
          color: isActive ? Colors.green : Theme.of(context).disabledColor,
          size: 20,
        ),
        title: isRenaming
            ? Row(
                children: [
                  Expanded(
                    child: serverSettingsTextFormField(
                      label: translate('Preset name'),
                      controller: renameCtrl,
                      errorMsg: '',
                      showLabelText: false,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10),
                    ).workaroundFreezeLinuxMint(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.check,
                        color: Colors.green, size: 20),
                    onPressed: () => confirmRename(p),
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                    splashRadius: 16,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.red, size: 20),
                    onPressed: cancelRename,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                    splashRadius: 16,
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
        trailing: isRenaming
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  dialogButton('Apply', onPressed: () => applyPreset(p)),
                  IconButton(
                    icon: const Icon(Icons.edit, size: 18),
                    tooltip: translate('Rename'),
                    onPressed: () => startRename(p),
                    constraints: const BoxConstraints(
                        minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                    splashRadius: 16,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: Colors.red),
                    tooltip: translate('Delete'),
                    onPressed: () => deletePreset(p),
                    constraints: const BoxConstraints(
                        minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                    splashRadius: 16,
                  ),
                ],
              ),
      );
    }

    Widget buildPresetsSection() {
      // NOTE: CustomAlertDialog wraps content in AlertDialog(scrollable: true),
      // which gives the content an *unbounded* height constraint. Putting a
      // ListView (even with shrinkWrap) inside would trigger Flutter's
      // "RenderBox was not laid out: unbounded constraints" assertion and make
      // the dialog appear frozen. A plain Column is safe here and the preset
      // count is expected to be small.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 24),
          if (isAddingPreset.value)
            Row(
              children: [
                Expanded(
                  child: serverSettingsTextFormField(
                    label: translate('Preset name'),
                    controller: newPresetNameCtrl,
                    errorMsg: '',
                    showLabelText: false,
                    autofocus: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 12),
                  ).workaroundFreezeLinuxMint(),
                ),
                IconButton(
                  icon: const Icon(Icons.check, color: Colors.green),
                  onPressed: confirmAddPreset,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  padding: EdgeInsets.zero,
                  splashRadius: 16,
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.red),
                  onPressed: cancelAddPreset,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  padding: EdgeInsets.zero,
                  splashRadius: 16,
                ),
              ],
            )
          else
            Row(
              children: [
                Text(translate('Server Config Presets')),
                const Spacer(),
                Tooltip(
                  message: translate('Save current as preset'),
                  child: IconButton(
                    icon: const Icon(Icons.bookmark_add, color: Colors.grey),
                    onPressed: startAddPreset,
                  ),
                ),
              ],
            ),
          if (presets.isEmpty && !isAddingPreset.value)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                translate('No presets saved'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else
            ...presets.map((p) => buildPresetTile(p)),
        ],
      );
    }

    return CustomAlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(translate('ID/Relay Server'))),
          ...ServerConfigImportExportWidgets(controllers, errMsgs),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 500),
        child: Form(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Obx(() => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      buildField(translate('ID Server'), idCtrl,
                          idServerMsg.value,
                          autofocus: true),
                      SizedBox(height: 8),
                      if (!isIOS && !isWeb) ...[
                        buildField(translate('Relay Server'), relayCtrl,
                            relayServerMsg.value),
                        SizedBox(height: 8),
                      ],
                      buildField(
                        translate('API Server'),
                        apiCtrl,
                        apiServerMsg.value,
                        validator: (v) {
                          if (v != null && v.isNotEmpty) {
                            if (!(v.startsWith('http://') ||
                                v.startsWith("https://"))) {
                              return translate("invalid_http");
                            }
                          }
                          return null;
                        },
                      ),
                      SizedBox(height: 8),
                      buildField('Key', keyCtrl, ''),
                      if (isInProgress)
                        Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: LinearProgressIndicator(),
                        ),
                    ],
                  )),
              // Separate Obx for the presets section to avoid nested-Obx
              // rebuild cascades that were freezing the UI.
              Obx(() => buildPresetsSection()),
            ],
          ),
        ),
      ),
      actions: [
        dialogButton('Cancel', onPressed: () {
          close();
        }, isOutline: true),
        dialogButton(
          'OK',
          onPressed: () async {
            if (await submit()) {
              close();
              showToast(translate('Successful'));
              upSetState?.call(() {});
            } else {
              // Validation failed (typically: target server unreachable).
              // For the multi-server preset use case the target may
              // intentionally live on a different network, so offer to
              // save the config anyway instead of blocking the save.
              final hasValidationErr =
                  errMsgs.any((e) => e.value.isNotEmpty);
              if (!hasValidationErr) {
                showToast(translate('Failed'));
                return;
              }
              final saveAnyway = await showPresetConfirmDialog(
                dialogManager,
                translate('ID/Relay Server'),
                translate('Server may be unreachable, save anyway?'),
              );
              if (!saveAnyway) return;
              final ok = await setServerConfig(
                null,
                null,
                ServerConfig(
                  idServer: idCtrl.text.trim(),
                  relayServer: relayCtrl.text.trim(),
                  apiServer: apiCtrl.text.trim(),
                  key: keyCtrl.text.trim(),
                ),
              );
              if (ok) {
                close();
                showToast(translate('Successful'));
                upSetState?.call(() {});
              } else {
                showToast(translate('Failed'));
              }
            }
          },
        ),
      ],
    );
  });
}

TextFormField serverSettingsTextFormField({
  required String label,
  required TextEditingController controller,
  required String errorMsg,
  String? Function(String?)? validator,
  bool autofocus = false,
  bool showLabelText = true,
  EdgeInsetsGeometry? contentPadding,
}) {
  return TextFormField(
    controller: controller,
    decoration: InputDecoration(
      labelText: showLabelText ? label : null,
      errorText: errorMsg.isEmpty ? null : errorMsg,
      contentPadding: contentPadding,
    ),
    validator: validator,
    autofocus: autofocus,
    keyboardType: TextInputType.visiblePassword,
    textCapitalization: TextCapitalization.none,
    autocorrect: false,
    enableSuggestions: false,
    smartDashesType: SmartDashesType.disabled,
    smartQuotesType: SmartQuotesType.disabled,
    enableIMEPersonalizedLearning: false,
    spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
  );
}

void setPrivacyModeDialog(
  OverlayDialogManager dialogManager,
  List<TToggleMenu> privacyModeList,
  RxString privacyModeState,
) async {
  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: Text(translate('Privacy mode')),
      content: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: privacyModeList
              .map((value) => CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    title: value.child,
                    value: value.value,
                    onChanged: value.onChanged,
                  ))
              .toList()),
    );
  }, backDismiss: true, clickMaskDismiss: true);
}
