import 'package:flutter/foundation.dart';

import 'recorder.dart';
import 'recorder_desktop.dart' as desktop;
import 'recorder_mobile.dart';
import 'recorder_stub.dart' as stub;

RecallRecorder createRecorder() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return desktop.createRecorder();
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return MobileRecallRecorder();
    default:
      return stub.createRecorder();
  }
}
