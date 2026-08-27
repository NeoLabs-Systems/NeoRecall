import 'dart:convert';
import 'dart:typed_data';

/// A deliberately small CBOR reader and writer.
///
/// The appliance speaks CBOR because a Bluetooth status notification has to fit
/// in one packet, and JSON does not leave enough room once a headphone name and
/// an error sentence are in it. Only the handful of major types that contract
/// actually uses are implemented here: integers, text, byte strings, arrays,
/// maps, booleans and null.
///
/// Everything else is rejected rather than guessed at. This is a channel that
/// accepts commands from a device, so a decoder that quietly tolerates a shape
/// it was never designed for is a liability, not a convenience.
class CborFormatException implements Exception {
  const CborFormatException(this.message);

  final String message;

  @override
  String toString() => 'CborFormatException: $message';
}

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  int _byte() {
    if (offset >= bytes.length) {
      throw const CborFormatException(
        'the message ended in the middle of a value',
      );
    }
    return bytes[offset++];
  }

  int _uint(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 8) | _byte();
    }
    return value;
  }

  int _argument(int additional) {
    if (additional < 24) return additional;
    switch (additional) {
      case 24:
        return _uint(1);
      case 25:
        return _uint(2);
      case 26:
        return _uint(4);
      case 27:
        return _uint(8);
      case 31:
        throw const CborFormatException(
          'values of unknown length are not accepted',
        );
      default:
        throw CborFormatException('unsupported length marker $additional');
    }
  }

  Uint8List _take(int length) {
    if (offset + length > bytes.length) {
      throw const CborFormatException(
        'the message ended in the middle of a value',
      );
    }
    final slice = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return slice;
  }

  Object? value() {
    final initial = _byte();
    final major = initial >> 5;
    final additional = initial & 0x1f;
    switch (major) {
      case 0:
        return _argument(additional);
      case 1:
        return -1 - _argument(additional);
      case 2:
        return _take(_argument(additional));
      case 3:
        return utf8.decode(_take(_argument(additional)));
      case 4:
        final length = _argument(additional);
        return List<Object?>.generate(length, (_) => value(), growable: false);
      case 5:
        final length = _argument(additional);
        final map = <String, Object?>{};
        for (var i = 0; i < length; i++) {
          final key = value();
          if (key is! String) {
            throw const CborFormatException('map keys must be text');
          }
          map[key] = value();
        }
        return map;
      case 7:
        switch (additional) {
          case 20:
            return false;
          case 21:
            return true;
          case 22:
          case 23:
            return null;
          default:
            throw CborFormatException('unsupported simple value $additional');
        }
      default:
        throw CborFormatException('unsupported CBOR type $major');
    }
  }
}

/// Decode one CBOR value. Trailing bytes are an error, not something to ignore.
Object? cborDecode(Uint8List bytes) {
  final reader = _Reader(bytes);
  final decoded = reader.value();
  if (reader.offset != bytes.length) {
    throw const CborFormatException('the message carried more than one value');
  }
  return decoded;
}

class _Writer {
  final BytesBuilder _out = BytesBuilder(copy: false);

  Uint8List take() => _out.takeBytes();

  void _head(int major, int argument) {
    final prefix = major << 5;
    if (argument < 24) {
      _out.addByte(prefix | argument);
    } else if (argument < 0x100) {
      _out
        ..addByte(prefix | 24)
        ..addByte(argument);
    } else if (argument < 0x10000) {
      _out
        ..addByte(prefix | 25)
        ..addByte((argument >> 8) & 0xff)
        ..addByte(argument & 0xff);
    } else if (argument < 0x100000000) {
      _out.addByte(prefix | 26);
      for (var shift = 24; shift >= 0; shift -= 8) {
        _out.addByte((argument >> shift) & 0xff);
      }
    } else {
      _out.addByte(prefix | 27);
      for (var shift = 56; shift >= 0; shift -= 8) {
        _out.addByte((argument >> shift) & 0xff);
      }
    }
  }

  void write(Object? value) {
    if (value == null) {
      _out.addByte(0xf6);
    } else if (value is bool) {
      _out.addByte(value ? 0xf5 : 0xf4);
    } else if (value is int) {
      if (value < 0) {
        _head(1, -1 - value);
      } else {
        _head(0, value);
      }
    } else if (value is String) {
      final encoded = utf8.encode(value);
      _head(3, encoded.length);
      _out.add(encoded);
    } else if (value is Uint8List) {
      _head(2, value.length);
      _out.add(value);
    } else if (value is List) {
      _head(4, value.length);
      for (final item in value) {
        write(item);
      }
    } else if (value is Map) {
      _head(5, value.length);
      value.forEach((key, item) {
        if (key is! String) {
          throw const CborFormatException('map keys must be text');
        }
        write(key);
        write(item);
      });
    } else {
      throw CborFormatException('cannot encode ${value.runtimeType}');
    }
  }
}

Uint8List cborEncode(Object? value) {
  final writer = _Writer();
  writer.write(value);
  return writer.take();
}
