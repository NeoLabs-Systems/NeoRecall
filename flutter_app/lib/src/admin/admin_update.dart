// Updating NeoRecall from the Admin page. The banner, the settings and the
// follow-the-restart logic are shared; this supplies the server calls and the
// wording. The server runs the same flow as `neorecall update`.

import 'package:neolabs_flutter/neolabs_flutter.dart';

import '../../l10n/gen/app_l10n.dart';
import '../api_client.dart';

NeoUpdateController adminUpdateController(NeoRecallApiClient api) {
  Future<Map<String, dynamic>> call(
    String method,
    String path, {
    Object? body,
  }) async => Map<String, dynamic>.from(
    await api.request(method, '/api/v1/admin/update$path', body: body) as Map,
  );

  return NeoUpdateController(
    NeoUpdateApi(
      status: () => call('GET', ''),
      check: () => call('POST', '/check'),
      start: () => call('POST', ''),
      setChannel: (channel) =>
          call('PUT', '/channel', body: <String, Object>{'channel': channel}),
      failureOf: (error) => error is ApiException
          ? (status: error.status, message: error.message)
          : null,
    ),
  );
}

NeoUpdateStrings adminUpdateStrings(
  AppL10n strings,
  String Function(DateTime time) date,
) => NeoUpdateStrings(
  title: strings.adminUpdatesTitle,
  description: strings.adminUpdatesHint,
  versionLabel: strings.adminStatVersion,
  channelLabel: strings.adminUpdateChannel,
  channelHint: strings.adminUpdateChannelHint,
  stable: strings.adminUpdateChannelStable,
  beta: strings.adminUpdateChannelBeta,
  checkNow: strings.adminUpdateCheckNow,
  neverChecked: strings.adminUpdateNeverChecked,
  checkedAt: (time) => strings.adminUpdateChecked(date(time)),
  upToDate: strings.adminUpdateUpToDate,
  checkFailed: strings.adminUpdateCheckFailed,
  details: strings.adminUpdateDetails,
  blocked: (reason) => reason == 'container'
      ? (
          title: strings.adminUpdateContainerTitle,
          hint: strings.adminUpdateContainerHint,
        )
      : (
          title: strings.adminUpdateNotGitTitle,
          hint: strings.adminUpdateNotGitHint,
        ),
  readyTitle: strings.adminUpdateReadyTitle,
  readySubtitle: strings.adminUpdateReadySubtitle,
  whatsNew: strings.adminUpdateWhatsNew,
  updateNow: strings.adminUpdateNow,
  confirmTitle: strings.adminUpdateConfirmTitle,
  confirmMessage: strings.adminUpdateConfirmMessage,
  cancel: strings.actionCancel,
  updatingTitle: strings.adminUpdatingTitle,
  updatingToTitle: strings.adminUpdatingToTitle,
  reconnecting: strings.adminUpdateReconnecting,
  handsOff: strings.adminUpdateHandsOff,
  doneTitle: strings.adminUpdateDoneTitle,
  doneReloading: strings.adminUpdateDoneReloading,
  reload: strings.adminUpdateReload,
  failedTitle: strings.adminUpdateFailedTitle,
  close: strings.actionClose,
  retry: strings.actionRetry,
);
