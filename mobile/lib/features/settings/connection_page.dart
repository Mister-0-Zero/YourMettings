import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/demo_connection.dart';
import '../../services/connection_settings.dart';

class ConnectionScope extends InheritedNotifier<ConnectionSettings> {
  const ConnectionScope({
    super.key,
    required ConnectionSettings controller,
    required super.child,
  }) : super(notifier: controller);
  static ConnectionSettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConnectionScope>()?.notifier;
}

void openConnectionSettings(
  BuildContext context,
  ConnectionSettings controller,
) {
  Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => ConnectionPage(controller: controller)),
  );
}

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({
    super.key,
    required this.controller,
    this.initial = false,
  });
  final ConnectionSettings controller;
  final bool initial;
  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  late ServerProfile _profile = widget.controller.profile;
  late final _address = TextEditingController(
    text: widget.controller.address(_profile),
  );
  final _key = TextEditingController();
  bool _hide = true, _busy = false, _loadingKey = false, _success = false;
  String? _message;
  String? _origin;
  int _generation = 0;
  Timer? _loadTimer;
  @override
  void initState() {
    super.initState();
    _loadKey();
  }

  Future<void> _loadKey() async {
    _hide = true;
    final generation = ++_generation;
    String? origin;
    try {
      origin = normalizeBackend(_address.text, _profile).origin;
    } catch (_) {}
    _origin = origin;
    _key.clear();
    if (origin == null) {
      if (mounted) setState(() => _loadingKey = false);
      return;
    }
    _loadingKey = true;
    try {
      final saved = await widget.controller.vault.read(origin);
      if (mounted && generation == _generation) _key.text = saved ?? '';
    } catch (_) {
      if (mounted) _message = 'Не удалось открыть защищённое хранилище ключа.';
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingKey = false);
      }
    }
  }

  void _addressChanged(String value) {
    String? origin;
    try {
      origin = normalizeBackend(value, _profile).origin;
    } catch (_) {}
    setState(() {
      _message = null;
      _success = false;
      if (origin != _origin) {
        // Never carry a visible/hidden key to another origin while typing.
        _generation++;
        _origin = origin;
        _key.clear();
        _hide = true;
        _loadingKey = origin != null;
        _loadTimer?.cancel();
        _loadTimer = Timer(const Duration(milliseconds: 350), _loadKey);
      }
    });
  }

  Future<void> _check({bool save = false}) async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _message = null;
      _success = false;
    });
    try {
      if (save) {
        await widget.controller.apply(_profile, _address.text, _key.text);
      } else {
        await widget.controller.check(_profile, _address.text, _key.text);
      }
      if (!mounted) return;
      setState(() {
        _success = true;
        _message = save ? 'Подключение сохранено и применено.' : 'Подключение проверено: сервер отвечает, демонстрационный доступ подтверждён.';
      });
      if (save && !widget.initial && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Подключение применено')));
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = e is FormatException ? e.message : e.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    _loadTimer?.cancel();
    _address.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Подключение')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (widget.controller.active != null)
            Text(
              'Текущий профиль: ${profileLabel(widget.controller.profile)}${String.fromCharCode(10)}${widget.controller.active!.base}',
            ),
          const SizedBox(height: 12),
          const Text('Демонстрационный режим — только тестовые данные'),
          const SizedBox(height: 16),
          DropdownButtonFormField<ServerProfile>(
            initialValue: _profile,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Профиль подключения'),
            items: [
              for (final p in ServerProfile.values)
                DropdownMenuItem(value: p, child: Text(profileLabel(p))),
            ],
            onChanged: _busy
                ? null
                : (p) {
                    setState(() {
                      _profile = p!;
                      _address.text = widget.controller.address(p);
                      _message = null;
                      _success = false;
                    });
                    _loadTimer?.cancel();
                    _loadKey();
                  },
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _address,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Адрес backend'),
            onChanged: _addressChanged,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _key,
            enabled: !_busy && !_loadingKey,
            obscureText: _hide,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            autofillHints: const [],
            enableIMEPersonalizedLearning: false,
            decoration: InputDecoration(
              labelText: 'Демонстрационный ключ',
              helperText: 'Хранится защищённо только для указанного адреса.',
              helperMaxLines: 2,
              suffixIcon: IconButton(
                onPressed: () => setState(() => _hide = !_hide),
                tooltip: _hide ? 'Показать ключ' : 'Скрыть ключ',
                icon: Icon(
                  _hide
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _busy || _loadingKey
                ? null
                : () async {
                    final clip = await Clipboard.getData(Clipboard.kTextPlain);
                    if (mounted) _key.text = (clip?.text ?? '').trim();
                  },
            icon: const Icon(Icons.content_paste),
            label: const Text('Вставить ключ'),
          ),
          if (_profile == ServerProfile.usb)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Подключите телефон по USB с настроенной переадресацией порта.',
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy || _loadingKey ? null : () => _check(),
            icon: const Icon(Icons.network_check),
            label: const Text('Проверить подключение'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy || _loadingKey ? null : () => _check(save: true),
            icon: const Icon(Icons.check),
            label: const Text('Сохранить и применить'),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _message!,
                  style: TextStyle(
                    color: _success
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          const Text(
            'При смене адреса ключ не переносится. Данные и незавершённые операции хранятся отдельно для каждого сервера и аккаунта.',
          ),
        ],
      ),
    ),
  );
}
