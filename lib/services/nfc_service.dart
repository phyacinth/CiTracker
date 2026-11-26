import 'dart:convert';

import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

class NfcReadResult {
  const NfcReadResult({
    required this.tagId,
    required this.contents,
    required this.supportsNdef,
  });

  final String tagId;
  final String contents;
  final bool supportsNdef;
}

class NfcService {
  Future<bool> isEnabled() async {
    final availability =
    await NfcManager.instance.checkAvailability();

    return availability == NfcAvailability.enabled;
  }

  Future<void> startReading({
    required void Function(NfcReadResult result) onRead,
    required void Function(String message) onError,
  }) async {
    var processing = false;

    await NfcManager.instance.startSession(
      pollingOptions: {
        NfcPollingOption.iso14443,
        NfcPollingOption.iso15693,
        NfcPollingOption.iso18092,
      },
      onDiscovered: (tag) async {
        // Prevent repeated callbacks from processing the same scan.
        if (processing) return;
        processing = true;

        try {
          final result = await _readTag(tag);
          onRead(result);
        } catch (_) {
          onError(
            'Unable to read the tag. Hold it steady and try again.',
          );
        } finally {
          await stopReading();
        }
      },
    );
  }

  Future<void> stopReading() async {
    await NfcManager.instance.stopSession();
  }

  Future<NfcReadResult> _readTag(NfcTag tag) async {
    final androidTag = NfcTagAndroid.from(tag);

    if (androidTag == null) {
      throw StateError('An Android NFC tag was not available.');
    }

    final tagId = _toHex(androidTag.id);
    final ndef = NdefAndroid.from(tag);

    if (ndef == null) {
      return NfcReadResult(
        tagId: tagId.isEmpty ? 'Not available' : tagId,
        contents:
        'Tag detected. Standard NDEF contents are not available '
            'on this tag. Its data may require a different reader '
            'or authorized access.',
        supportsNdef: false,
      );
    }

    // Read from the tag rather than relying on cached contents.
    final message = await ndef.getNdefMessage();
    final entries = <String>[];

    if (message != null) {
      for (var index = 0; index < message.records.length; index++) {
        final record = message.records[index];
        final payload = record.payload;

        final isTextRecord =
            record.typeNameFormat.index == 1 &&
                record.type.length == 1 &&
                record.type.first == 0x54;

        String value;

        if (isTextRecord && payload.isNotEmpty) {
          final status = payload.first;
          final languageLength = status & 0x3F;
          final textStart = 1 + languageLength;
          final usesUtf16 = (status & 0x80) != 0;

          if (textStart > payload.length) {
            value = 'Invalid text record';
          } else if (usesUtf16) {
            value = 'UTF-16 text payload (hex): ${_toHex(payload)}';
          } else {
            value = utf8.decode(
              payload.sublist(textStart),
              allowMalformed: true,
            );
          }
        } else {
          value = payload.isEmpty
              ? 'Empty record'
              : 'Payload (hex): ${_toHex(payload)}';
        }

        entries.add('Record ${index + 1}: $value');
      }
    }

    return NfcReadResult(
      tagId: tagId.isEmpty ? 'Not available' : tagId,
      contents: entries.isEmpty
          ? 'The tag was read successfully but contains no NDEF records.'
          : entries.join('\n\n'),
      supportsNdef: true,
    );
  }

  String _toHex(List<int> bytes) {
    return bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(' ')
        .toUpperCase();
  }
}