/// A Wear OS device this phone is paired with.
///
/// Reported by Play services rather than by NeoRecall, so a watch appears here
/// as soon as it is paired with the phone — whether or not the watch app has
/// ever been installed on it. That distinction is the whole point: it is what
/// lets the app say "paired, but NeoRecall is not on it yet" instead of
/// pretending no watch exists.
class PairedWatch {
  const PairedWatch({
    required this.id,
    required this.name,
    required this.nearby,
    required this.installed,
  });

  factory PairedWatch.fromMap(Map<Object?, Object?> map) => PairedWatch(
    id: map['id']?.toString() ?? '',
    name: (map['name']?.toString() ?? '').trim().isEmpty
        ? 'Watch'
        : map['name'].toString().trim(),
    nearby: map['nearby'] == true,
    installed: map['installed'] == true,
  );

  final String id;
  final String name;

  /// Connected over Bluetooth right now, rather than only over the cloud relay.
  final bool nearby;

  /// Advertising the NeoRecall watch capability, which only the watch APK does.
  final bool installed;
}
