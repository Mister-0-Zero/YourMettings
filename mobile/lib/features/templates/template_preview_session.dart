import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../models/api_models.dart';
import '../../models/generation_source.dart';
import '../../models/summary_template.dart';

/// A single recoverable template test, separate from the meeting history.
class TemplatePreviewSession extends ChangeNotifier
    with WidgetsBindingObserver {
  TemplatePreviewSession(this.api) {
    final saved = api.operations?[slot];
    if (saved != null) {
      detail = saved['detail'] as String;
      text.text = saved['custom_text'] as String? ?? '';
      exampleId = saved['example_id'] as String?;
      exampleTitle = saved['example_title'] as String?;
      if (exampleId == null) {
        text.text = saved['text'] as String;
      } else {
        exampleText = saved['text'] as String;
      }
      _inputSignature = saved['signature'] as String?;
      _request = saved['request'] as Json?;
      final id = saved['preview_id'] as String?;
      if (id != null) {
        _request = null;
        preview = TemplatePreview(id: id, status: 'queued');
        unawaited(_poll());
      }
    }
    WidgetsBinding.instance.addObserver(this);
    text.addListener(_notify);
  }
  static const slot = 'template-preview';
  final ApiClient api;
  final text = TextEditingController();
  String detail = 'normal';
  String? exampleId, exampleTitle, exampleText;
  String get source => exampleId == null ? text.text : exampleText ?? '';
  TemplatePreview? preview;
  String? error;
  bool sending = false;
  bool _checking = false, _paused = false, _disposed = false;
  Timer? _timer;
  int _failures = 0;
  bool _pollAllowed = true;
  Duration _pollDelay = const Duration(seconds: 2);
  String? _inputSignature;
  Json? _request;
  bool get active => preview != null && !preview!.finished;
  bool get uncertain => _request != null && preview == null;
  bool get locked => sending || active || uncertain;
  bool uses(TemplateInput input) => _inputSignature == _signature(input);
  String _signature(TemplateInput input) => jsonEncode({
    'template': input.toJson(),
    'text': source,
    'detail_level': detail,
  });
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void changeDetail(String value) {
    if (locked) return;
    detail = value;
    _notify();
  }

  void chooseExample({String? id, String? title, String? content}) {
    if (locked) return;
    exampleId = id;
    exampleTitle = title;
    exampleText = content;
    _notify();
  }

  Future<void> _save(TemplateInput input) async {
    await api.operations?.put(slot, {
      'text': source,
      'custom_text': text.text,
      'detail': detail,
      'example_id': exampleId,
      'example_title': exampleTitle,
      'signature': _inputSignature,
      'input': input.toJson(),
      'request': _request,
      'preview_id': preview?.id,
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    if (_paused) {
      _timer?.cancel();
    } else if (active) {
      unawaited(_poll());
    }
  }

  Future<void> start(TemplateInput input) async {
    if (sending || active || _disposed) return;
    final validation = validateGenerationSource(source);
    if (!uncertain && validation != null) {
      error = validation;
      _notify();
      return;
    }
    sending = true;
    _pollAllowed = true;
    error = null;
    _failures = 0;
    _notify();
    try {
      if (_request == null) {
        _inputSignature = _signature(input);
        preview = null;
        _request = {
          'key': newSectionId(),
          'input': input.toJson(),
          'text': source,
          'custom_text': text.text,
          'detail': detail,
        };
      }
      // Before HTTP, freeze the exact replay body and its key on disk.
      await _save(input);
      final result = await api.startTemplatePreview(
        TemplateInput.fromJson(_request!['input'] as Json),
        _request!['text'] as String,
        _request!['detail'] as String,
        idempotencyKey: _request!['key'] as String,
      );
      if (_disposed) return;
      preview = result;
      await _save(input);
      _request = null;
      await _save(input);
      _schedule();
    } catch (e) {
      error =
          e is ApiException &&
              ['generation_busy', 'preview_busy'].contains(e.code)
          ? 'Сейчас выполняются другие тесты. Попробуйте немного позже.'
          : e.toString();
      if (e is ApiException &&
          e.statusCode != null &&
          [404, 409, 410, 413, 422].contains(e.statusCode)) {
        _request = null;
        await _save(input);
      }
    } finally {
      sending = false;
      _notify();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!_disposed && !_paused && _pollAllowed && active) {
      _timer = Timer(
        _failures == 0 ? const Duration(seconds: 2) : _pollDelay,
        _poll,
      );
    }
  }

  Future<void> _poll() async {
    if (_checking || !active || _disposed) return;
    _checking = true;
    try {
      final result = await api.templatePreview(preview!.id);
      if (_disposed) return;
      preview = result;
      error = null;
      _failures = 0;
    } catch (e) {
      if (_disposed) return;
      _pollDelay = retryDelay(
        ++_failures,
        minimum: e is ApiException ? e.retryAfter : null,
      );
      _pollAllowed = e is ApiException && e.retryable;
      if (e is ApiException && [404, 410].contains(e.statusCode)) {
        preview = null;
        _request = null;
        final saved = api.operations?[slot];
        if (saved != null) {
          await api.operations!.put(slot, {
            ...saved,
            'preview_id': null,
            'request': null,
          });
        }
        error = 'Тест больше недоступен. Ваш текст сохранён на этом экране; запустите тест ещё раз.';
      } else {
        error = e is ApiException && e.isAccess
            ? e.message
            : 'Не удалось получить результат. Проверим соединение ещё раз.';
      }
    } finally {
      _checking = false;
      _notify();
      _schedule();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    text.removeListener(_notify);
    text.dispose();
    super.dispose();
  }
}
