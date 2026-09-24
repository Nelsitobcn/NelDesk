// NelDesk: horizontal key bar pinned at the top of the remote screen.
//
// The iPad Magic Keyboard has no Esc key and iPadOS keeps shortcuts like
// Cmd+Tab and Cmd+Space for itself, so they are offered here as buttons.
// Modifiers are one-shot: tap "Cmd" then "Tab" sends Cmd+Tab and Cmd turns off.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

const String kNelKeyBarHiddenOption = 'nel-key-bar-hidden';

class NelKeyBar {
  static const double height = 44;
  static final RxBool visible =
      (bind.mainGetLocalOption(key: kNelKeyBarHiddenOption) != 'Y').obs;

  static Future<void> setVisible(bool v) async {
    visible.value = v;
    await bind.mainSetLocalOption(
        key: kNelKeyBarHiddenOption, value: v ? '' : 'Y');
  }

  /// Keeps the canvas below the bar. Call when visibility or layout changes.
  static void applyCanvasInset() {
    final inset = visible.value ? height : 0.0;
    if (CanvasModel.nelTopInset != inset) {
      CanvasModel.nelTopInset = inset;
      gFFI.canvasModel.updateViewStyle();
    }
  }
}

/// Continuous dictation (native side: NelDictation in ios/Runner/AppDelegate.swift).
/// Tap to start listening; each phrase is typed on the remote computer after a
/// short pause. Tap again to stop.
class NelDictation {
  static const _channel = MethodChannel('neldesk/dictation');
  static final RxBool listening = false.obs;
  static final RxString partial = ''.obs;
  static var _handlerSet = false;

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'partial') {
        partial.value = call.arguments as String? ?? '';
      } else if (call.method == 'phrase') {
        partial.value = '';
        final t = (call.arguments as String? ?? '').trim();
        if (t.isNotEmpty) {
          bind.sessionInputString(sessionId: gFFI.sessionId, value: '$t ');
        }
      }
    });
  }

  static Future<void> toggle() async {
    _ensureHandler();
    if (listening.value) {
      await _channel.invokeMethod('stop');
      listening.value = false;
      partial.value = '';
      return;
    }
    try {
      partial.value = '';
      await _channel.invokeMethod('start');
      listening.value = true;
    } on PlatformException catch (e) {
      showToast(e.message ?? 'No se pudo empezar a dictar');
    }
  }
}

class NelKeyBarWidget extends StatefulWidget {
  const NelKeyBarWidget({Key? key}) : super(key: key);

  @override
  State<NelKeyBarWidget> createState() => _NelKeyBarWidgetState();
}

class _NelKeyBarWidgetState extends State<NelKeyBarWidget> {
  var _fn = false;

  InputModel get inputModel => gFFI.inputModel;

  void _key(String name) {
    inputModel.inputKey(name);
    // One-shot modifiers.
    setState(() => inputModel.resetModifiers());
  }

  void _combo(String name, {bool command = false, bool shift = false}) {
    inputModel.command = command;
    inputModel.shift = shift;
    inputModel.inputKey(name);
    setState(() => inputModel.resetModifiers());
  }

  Widget _btn(String text, VoidCallback onPressed,
      {bool active = false, IconData? icon, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 34),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          backgroundColor:
              active ? MyTheme.accent : (color ?? const Color(0x33FFFFFF)),
        ),
        onPressed: onPressed,
        child: icon != null
            ? Icon(icon, size: 18, color: Colors.white)
            : Text(text,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
      ),
    );
  }

  Widget _sep() => const SizedBox(width: 10);

  @override
  Widget build(BuildContext context) {
    final isMac = gFFI.ffiModel.pi.platform == kPeerPlatformMacOS;
    final cmdLabel = isMac ? '⌘ Cmd' : 'Win';
    final children = <Widget>[
      Obx(() {
        final on = NelDictation.listening.value;
        final p = NelDictation.partial.value;
        final label = !on
            ? '🎤 Dictar'
            : (p.isEmpty
                ? '● Escuchando… (toca para parar)'
                : '● ${p.length > 28 ? '…${p.substring(p.length - 28)}' : p}');
        return _btn(label, NelDictation.toggle,
            color: on ? const Color(0xCCD32F2F) : const Color(0x6600A86B));
      }),
      _sep(),
      _btn('Esc', () => _key('VK_ESCAPE')),
      _btn('Tab', () => _key('VK_TAB')),
      _sep(),
      _btn('⌃ Ctrl', () => setState(() => inputModel.ctrl = !inputModel.ctrl),
          active: inputModel.ctrl),
      _btn(isMac ? '⌥ Alt' : 'Alt',
          () => setState(() => inputModel.alt = !inputModel.alt),
          active: inputModel.alt),
      _btn(cmdLabel,
          () => setState(() => inputModel.command = !inputModel.command),
          active: inputModel.command),
      _btn('⇧ Shift',
          () => setState(() => inputModel.shift = !inputModel.shift),
          active: inputModel.shift),
      _sep(),
      _btn('', () => _key('VK_LEFT'), icon: Icons.keyboard_arrow_left),
      _btn('', () => _key('VK_UP'), icon: Icons.keyboard_arrow_up),
      _btn('', () => _key('VK_DOWN'), icon: Icons.keyboard_arrow_down),
      _btn('', () => _key('VK_RIGHT'), icon: Icons.keyboard_arrow_right),
      _sep(),
      _btn('Supr', () => _key('VK_DELETE')),
      _btn('Inicio', () => _key('VK_HOME')),
      _btn('Fin', () => _key('VK_END')),
      _btn('RePág', () => _key('VK_PRIOR')),
      _btn('AvPág', () => _key('VK_NEXT')),
      _sep(),
      _btn('F1-F12', () => setState(() => _fn = !_fn), active: _fn),
      if (_fn)
        for (var i = 1; i <= 12; ++i) _btn('F$i', () => _key('VK_F$i')),
      _sep(),
      if (isMac) ...[
        _btn('⌘Tab', () => _combo('VK_TAB', command: true)),
        _btn('Spotlight', () => _combo('VK_SPACE', command: true)),
        _btn('⌘Z', () => _combo('VK_Z', command: true)),
        _sep(),
      ],
      _sep(),
      _btn('Soltar teclas', () {
        inputModel.releaseAllPressedKeys();
        setState(() {});
        showToast('Teclas soltadas');
      }, color: const Color(0x66FF6B00)),
    ];
    return Container(
      height: NelKeyBar.height,
      color: const Color(0xEE1E1E1E),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(children: children),
            ),
          ),
          _btn('', () => NelKeyBar.setVisible(false),
              icon: Icons.keyboard_arrow_up),
        ],
      ),
    );
  }
}

/// Small tab shown when the bar is hidden, to bring it back.
class NelKeyBarShowTab extends StatelessWidget {
  const NelKeyBarShowTab({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xAA1E1E1E),
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
      child: InkWell(
        onTap: () => NelKeyBar.setVisible(true),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Icon(Icons.keyboard, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}
