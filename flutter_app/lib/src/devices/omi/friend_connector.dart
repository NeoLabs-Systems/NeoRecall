import 'base_connector.dart';
import 'device_models.dart';

class FriendPendantConnector extends WearableConnector {
  FriendPendantConnector({required super.device, required super.transport});

  static const packetFooterSize = 5;
  static const packetSize = 95;
  static const lc3DataSize = 90;
  static const lc3FrameSize = 30;

  @override
  WearableAudioCodec get codec => WearableAudioCodec.lc3;

  @override
  Future<void> startRecording() async {
    if (recording) return;
    trackRecording(
      (await transport.characteristicStream(
        WearableDeviceUuids.friendService,
        WearableDeviceUuids.friendAudio,
      )).listen((data) {
        final payload = _processAudioPacket(data);
        if (payload == null || payload.isEmpty) return;
        for (var i = 0; i + lc3FrameSize <= payload.length; i += lc3FrameSize) {
          audioBytes.add(payload.sublist(i, i + lc3FrameSize));
        }
      }),
    );
    recording = true;
  }

  List<int>? _processAudioPacket(List<int> data) {
    if (data.length < packetSize) return null;
    final packet = data.length == packetSize
        ? data
        : data.sublist(0, packetSize);
    return packet.sublist(0, lc3DataSize);
  }

  @override
  Future<void> stopRecording() async {
    await cancelRecordingSubscriptions();
    recording = false;
  }
}
