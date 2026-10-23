import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../models/summary_template.dart';

/// One temporary test session belongs to the template editor, across visits to
/// preview. Nothing here enters meeting recovery, files or the meeting API.
class TemplatePreviewSession extends ChangeNotifier
    with WidgetsBindingObserver {
  TemplatePreviewSession(this.api) {
    WidgetsBinding.instance.addObserver(this);
    text.addListener(_notify);
  }
  final ApiClient api;
  final text = TextEditingController();
  String detail = 'normal';
  TemplatePreview? preview;
  String? error;
  bool sending = false;
  bool _checking = false, _paused = false, _disposed = false;
  Timer? _timer;
  int _failures = 0;
  String? _inputSignature;
  bool get active => preview != null && !preview!.finished;
  bool uses(TemplateInput input) => _inputSignature == _signature(input);

  String _signature(TemplateInput input) => jsonEncode({
    'template': input.toJson(),
    'text': text.text.trim(),
    'detail_level': detail,
  });
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void changeDetail(String value) {
    detail = value;
    _notify();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    if (_paused) {
      _timer?.cancel();
    } else if (active) {
      _poll();
    }
  }

  Future<void> start(TemplateInput input) async {
    if (sending || active || _disposed) return;
    final source = text.text.trim();
    if (source.isEmpty || source.runes.length > 12000) {
      error = 'Добавьте текст: от 1 до 12 000 символов.';
      _notify();
      return;
    }
    sending = true;
    error = null;
    preview = null;
    _failures = 0;
    _inputSignature = _signature(input);
    _notify();
    try {
      final result = await api.startTemplatePreview(input, source, detail);
      if (_disposed) return;
      preview = result;
      _schedule();
    } catch (e) {
      error = e is ApiException && e.code == 'preview_busy'
          ? 'Сейчас выполняются другие тесты. Попробуйте немного позже.'
          : e.toString();
    } finally {
      sending = false;
      _notify();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!_disposed && !_paused && active) {
      _timer = Timer(Duration(seconds: _failures == 0 ? 2 : 5), _poll);
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
      _failures++;
      if (e is ApiException && e.statusCode == 404) {
        preview = null;
        error = 'Тест больше недоступен. Ваш текст сохранён на этом экране; запустите тест ещё раз.';
      } else {
        error = 'Не удалось получить результат. Проверим соединение ещё раз.';
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
