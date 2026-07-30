import 'dart:typed_data';

import 'package:minimp3_dart/minimp3.dart';

/// Streaming MP3 -> mono PCM16 @ [targetSampleRate] decoder.
///
/// HeyPocket delivers audio as an MP3 byte stream fragmented across BLE
/// notifications. The shared capture pipeline, like every other wearable path,
/// consumes signed 16-bit little-endian mono PCM at 16 kHz, so this decoder
/// owns three responsibilities the raw frames do not satisfy on their own:
///
/// 1. Reassembly: BLE notification boundaries do not line up with MP3 frame
///    boundaries, so bytes are buffered until whole frames can be decoded and
///    any partial trailing frame is carried into the next chunk.
/// 2. Downmix: MP3 frames may be stereo; the pipeline is mono.
/// 3. Resample: the device's MP3 sample rate is not guaranteed to be 16 kHz.
///
/// This is the only file that depends on the `minimp3_dart` package; the DSP
/// helpers below are pure and independently testable.
class Mp3StreamDecoder {
  Mp3StreamDecoder({this.targetSampleRate = 16000})
    : assert(targetSampleRate > 0),
      _decoder = Mp3Decoder() {
    _decoder.initialize();
  }

  final int targetSampleRate;

  /// Largest plausible MPEG-1 Layer III frame (320 kbps @ 32 kHz + padding).
  /// Used to decide when undecodable leading bytes are genuine stream junk that
  /// should be skipped to resync, versus a not-yet-complete trailing frame.
  static const int maxMp3FrameBytes = 1441;

  /// Upper bound on retained-but-undecoded bytes. A stream that never yields a
  /// valid frame (persistent corruption) must not grow the buffer without
  /// limit; the oldest bytes are dropped past this cap.
  static const int maxBufferBytes = 1 << 16;

  final Mp3Decoder _decoder;
  List<int> _buffer = <int>[];
  LinearResampler? _resampler;
  int _sourceRate = 0;

  /// Feeds one BLE audio payload and returns any newly decoded PCM16 bytes, or
  /// null when the payload only advanced the internal frame buffer.
  Uint8List? addChunk(List<int> mp3Bytes) {
    if (mp3Bytes.isNotEmpty) _buffer.addAll(mp3Bytes);
    if (_buffer.isEmpty) return null;

    final data = Uint8List.fromList(_buffer);
    final pcmOut = BytesBuilder(copy: false);
    var offset = 0;

    while (offset < data.length) {
      final frame = _decoder.decodeFrame(data, offset: offset);
      if (frame != null && frame.nextOffset > offset) {
        if (frame.pcm.isNotEmpty) {
          final bytes = _processFrame(frame);
          if (bytes.isNotEmpty) pcmOut.add(bytes);
        }
        offset = frame.nextOffset;
        continue;
      }
      // No frame decoded at `offset`. If more than a full frame remains, this
      // leading byte is junk (tag bytes, or noise after a reconnect); skip it
      // and resync. Otherwise keep the tail and wait for the next chunk.
      if (data.length - offset > maxMp3FrameBytes) {
        offset += 1;
        continue;
      }
      break;
    }

    _buffer = offset >= data.length ? <int>[] : data.sublist(offset).toList();
    if (_buffer.length > maxBufferBytes) {
      _buffer = _buffer.sublist(_buffer.length - maxBufferBytes);
    }
    return pcmOut.isEmpty ? null : pcmOut.toBytes();
  }

  Uint8List _processFrame(Mp3Frame frame) {
    final rate = frame.info.sampleRateHz;
    final channels = frame.info.channels;
    if (rate <= 0 || channels <= 0) return Uint8List(0);
    if (_resampler == null || _sourceRate != rate) {
      _sourceRate = rate;
      _resampler = LinearResampler(
        inputRate: rate,
        outputRate: targetSampleRate,
      );
    }
    final mono = downmixToMono(frame.pcm, channels);
    final resampled = _resampler!.process(mono);
    return int16ToBytesLE(resampled);
  }

  /// Drops buffered bytes and resampler phase without discarding the decoder.
  /// Used when a recording stops so the next one starts from a clean stream.
  void reset() {
    _buffer = <int>[];
    _resampler = null;
    _sourceRate = 0;
    _decoder.initialize();
  }

  void dispose() {
    _buffer = <int>[];
    _resampler = null;
  }
}

/// Averages interleaved [channels]-channel PCM16 down to a single channel.
/// A mono input is returned unchanged.
Int16List downmixToMono(Int16List interleaved, int channels) {
  if (channels <= 1) return interleaved;
  final frames = interleaved.length ~/ channels;
  final mono = Int16List(frames);
  for (var i = 0; i < frames; i += 1) {
    final base = i * channels;
    var sum = 0;
    for (var c = 0; c < channels; c += 1) {
      sum += interleaved[base + c];
    }
    mono[i] = sum ~/ channels;
  }
  return mono;
}

/// Packs signed 16-bit samples into little-endian bytes.
Uint8List int16ToBytesLE(Int16List samples) {
  final out = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i += 1) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return out;
}

/// Stateful linear-interpolation resampler for a continuous mono int16 stream.
///
/// State (fractional read position plus the previous buffer's last sample) is
/// carried between [process] calls so successive BLE frames resample without a
/// discontinuity at every buffer boundary. When input and output rates match it
/// is a pass-through.
class LinearResampler {
  LinearResampler({required this.inputRate, required this.outputRate})
    : assert(inputRate > 0),
      assert(outputRate > 0);

  final int inputRate;
  final int outputRate;

  double _position = 0.0;
  int? _previousTail;

  Int16List process(Int16List input) {
    if (input.isEmpty) return Int16List(0);
    if (inputRate == outputRate) {
      _previousTail = input[input.length - 1];
      return input;
    }

    final step = inputRate / outputRate;
    final n = input.length;
    int sampleAt(int index) => index < 0 ? (_previousTail ?? input[0]) : input[index];

    final out = <int>[];
    var position = _position;
    while (true) {
      final i0 = position.floor();
      final i1 = i0 + 1;
      if (i1 >= n) break; // Need the next buffer to interpolate past the tail.
      final frac = position - i0;
      final s0 = sampleAt(i0);
      final s1 = sampleAt(i1);
      var value = (s0 + (s1 - s0) * frac).round();
      if (value > 32767) {
        value = 32767;
      } else if (value < -32768) {
        value = -32768;
      }
      out.add(value);
      position += step;
    }

    _position = position - n; // Carry the fractional read position.
    _previousTail = input[n - 1];
    return Int16List.fromList(out);
  }

  void reset() {
    _position = 0.0;
    _previousTail = null;
  }
}
