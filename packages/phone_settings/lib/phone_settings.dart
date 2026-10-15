/// The phone settings that decide whether a ring on it is heard. Android only.
///
/// A plugin rather than a channel on the app's own activity because the foreground service
/// runs in an engine of its own, with no activity, and the service is what reports. Plugins
/// are registered in every engine; an activity's channels are not.
library;

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.facilityflow/phone_settings');

/// `notificationsOn`, `fullScreenOn` (null before Android 14, which always allows it),
/// `batteryExempt`, and `alarmVolume` as a percentage of the alarm stream's maximum.
Future<Map<String, Object?>> readPhoneSettings() async =>
    await _channel.invokeMapMethod<String, Object?>('read') ?? const {};
