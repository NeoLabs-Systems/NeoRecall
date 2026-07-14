import '../api_client.dart';
import 'chunk_store.dart';
import 'upload_pump.dart';

class SyncCoordinator {
  SyncCoordinator({required this.store, required this.api, this.onChanged})
    : pump = UploadPump(store: store, api: api, onChanged: onChanged);
  final ChunkStore store;
  final NeoRecallApiClient api;
  final void Function()? onChanged;
  final UploadPump pump;
  Future<void> initialize() async {
    await store.initialize();
    pump.start();
  }

  Future<void> close() async {
    pump.stop();
    await store.close();
  }
}
