import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import '../state/settings.dart';

/// Plays alarm sounds with a volume that stays the same, rises or falls.
class AlarmPlayer {
  /// True while the sound is muted (bell button): alarms still show and vibrate.
  bool Function() isMuted = () => false;
  final AudioPlayer _alarm = AudioPlayer();
  final AudioPlayer _preview = AudioPlayer();
  Timer? _ramp;
  Timer? _delay;
  Timer? _vibe;
  int previewing = -1;
  void Function()? onPreviewEnd;

  Future<void> init() async {
    try {
      await AudioPlayer.global.setAudioContext(AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {},
        ),
        android: AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.alarm,
          audioFocus: AndroidAudioFocus.gainTransient,
        ),
      ));
    } catch (_) {
      // Keep the default audio setup if this fails.
    }
    _preview.onPlayerComplete.listen((_) {
      previewing = -1;
      onPreviewEnd?.call();
    });
  }

  static String _asset(int sound) {
    final i = sound.clamp(0, kSounds.length - 1);
    return 'sounds/${kSounds[i].file}.wav';
  }

  /// Starts the alarm. [delaySec] gives the gentle wake-up time (screen only, no sound).
  /// [volumeScale] lowers the volume (quiet hours).
  Future<void> start(SoundCfg cfg, {int delaySec = 0, double volumeScale = 1.0, bool vibrateOnly = false}) async {
    await stop();
    if (cfg.vibrate || vibrateOnly) {
      _vibe = Timer.periodic(const Duration(seconds: 2), (_) => HapticFeedback.vibrate());
    }
    if (vibrateOnly) return;
    _delay = Timer(Duration(seconds: delaySec), () {
      if (!isMuted()) _play(cfg, volumeScale);
    });
  }

  Future<void> _play(SoundCfg cfg, double scale) async {
    final from = (cfg.v1 / 100.0) * scale;
    final to = (cfg.volMode == 0 ? cfg.v1 : cfg.v2) / 100.0 * scale;
    try {
      await _alarm.setReleaseMode(ReleaseMode.loop);
      await _alarm.setVolume(from.clamp(0.0, 1.0));
      await _alarm.play(AssetSource(_asset(cfg.sound)), volume: from.clamp(0.0, 1.0));
    } catch (_) {
      // In a browser this fails until the page is clicked: retry then.
      _blocked = () => _play(cfg, scale);
      return;
    }
    _blocked = null;
    if (cfg.volMode == 0 || cfg.secs <= 0) return;
    final start = DateTime.now();
    _ramp = Timer.periodic(const Duration(milliseconds: 500), (t) {
      final f = (DateTime.now().difference(start).inMilliseconds / (cfg.secs * 1000)).clamp(0.0, 1.0);
      final v = from + (to - from) * f;
      _alarm.setVolume(v.clamp(0.0, 1.0));
      if (f >= 1.0) t.cancel();
    });
  }

  /// Stops the sound only (vibration and the alarm screen go on).
  Future<void> silence() async {
    _blocked = null;
    _ramp?.cancel();
    _delay?.cancel();
    _ramp = null;
    _delay = null;
    try {
      await _alarm.stop();
    } catch (_) {}
  }

  Future<void> stop() async {
    _blocked = null;
    _ramp?.cancel();
    _delay?.cancel();
    _vibe?.cancel();
    _ramp = null;
    _delay = null;
    _vibe = null;
    try {
      await _alarm.stop();
    } catch (_) {}
  }

  bool _unlocked = false;
  Future<void> Function()? _blocked;

  /// Browsers only let a page play sound after a click or tap on it. On the
  /// first one, both players play a silent moment so later alarms can sound.
  Future<void> unlock() async {
    if (_unlocked) return;
    _unlocked = true;
    for (final p in [_alarm, _preview]) {
      if (p.state == PlayerState.playing) continue; // an alarm is already sounding
      try {
        await p.setReleaseMode(ReleaseMode.stop);
        await p.play(AssetSource(_asset(0)), volume: 0.0);
        await p.stop();
      } catch (_) {}
    }
    final retry = _blocked;
    _blocked = null;
    if (retry != null) await retry();
  }

  /// Plays a sound once so it can be chosen in settings. Calling again stops it.
  Future<void> preview(int sound, int volumePct) async {
    if (previewing == sound) {
      await stopPreview();
      return;
    }
    previewing = sound;
    try {
      await _preview.stop();
      await _preview.setReleaseMode(ReleaseMode.stop);
      await _preview.play(AssetSource(_asset(sound)), volume: (volumePct / 100.0).clamp(0.05, 1.0));
    } catch (_) {
      previewing = -1;
    }
  }

  Future<void> stopPreview() async {
    previewing = -1;
    try {
      await _preview.stop();
    } catch (_) {}
  }
}
