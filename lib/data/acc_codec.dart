import 'dart:io';
import 'dart:typed_data';

/// Accelerometer chunks are stored as zlib-compressed little-endian int16
/// triples (x, y, z in mG). ±16 g = ±16000 mG fits int16.
Uint8List encodeAccChunk(Int32List xyz, int start, int count) {
  final bytes = ByteData(count * 6);
  var o = 0;
  for (var i = start * 3; i < (start + count) * 3; i++) {
    bytes.setInt16(o, xyz[i].clamp(-32768, 32767), Endian.little);
    o += 2;
  }
  return Uint8List.fromList(
    ZLibCodec(level: 6).encode(bytes.buffer.asUint8List()),
  );
}

/// Inverse of [encodeAccChunk]: interleaved x, y, z.
Int32List decodeAccChunk(Uint8List blob) {
  final raw = Uint8List.fromList(ZLibCodec().decode(blob));
  final bytes = ByteData.sublistView(raw);
  final out = Int32List(raw.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = bytes.getInt16(i * 2, Endian.little);
  }
  return out;
}
