import 'package:awesome_notifications/awesome_notifications.dart'
    hide NotificationModel;
import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:noorequran/models/appuser.dart';
import 'package:noorequran/models/current_app_user.dart';
import 'package:noorequran/models/notification_model.dart';
import 'package:noorequran/services/app_reminder_service.dart';
import 'dart:convert';
import 'package:noorequran/isolate_service.dart';
import 'package:noorequran/controllers/location_controller.dart';
import 'package:noorequran/app/modules/namaz_view_screen/namaz_controller.dart';
import 'package:geolocator/geolocator.dart';

class NotificationController extends GetxController {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final GetStorage _storage = GetStorage();
  FirebaseMessaging firebaseMessaging = FirebaseMessaging.instance;

  final RxBool isInitialized = false.obs;

  // To prevent redundant scheduling that kills active sounds

  @override
  void onInit() {
    super.onInit();
    debugPrint("Instance created: NotificationController");

    // AwesomeNotifications is initialized in main.dart
    _heavyInitInBackground();
  }

  /// Use this method to detect when a new notification or a schedule is created
  @pragma("vm:entry-point")
  static Future<void> onNotificationCreatedMethod(
    ReceivedNotification receivedNotification,
  ) async {
    debugPrint(
      'Global Listener: Notification created: ${receivedNotification.id}',
    );
  }

  /// Use this method to detect every time that a new notification is displayed
  @pragma("vm:entry-point")
  static Future<void> onNotificationDisplayedMethod(
    ReceivedNotification receivedNotification,
  ) async {
    debugPrint(
      'Global Listener: Notification displayed: ${receivedNotification.id}',
    );
  }

  /// Use this method to detect if the user dismissed a notification
  @pragma("vm:entry-point")
  static Future<void> onDismissActionReceivedMethod(
    ReceivedAction receivedAction,
  ) async {
    debugPrint('Global Listener: Notification dismissed: ${receivedAction.id}');
  }

  /// Use this method to detect when the user taps on a notification or action button
  @pragma("vm:entry-point")
  static Future<void> onActionReceivedMethod(
    ReceivedAction receivedAction,
  ) async {
    debugPrint(
      'Global Listener: Action received: ${receivedAction.id} button key: ${receivedAction.buttonKeyPressed}',
    );

    // Handle "Stop Azan" action
    if (receivedAction.buttonKeyPressed == 'stop_azan') {
      debugPrint(
        'Stopping Azan Sound (Cancelling Notification ID: ${receivedAction.id})',
      );
      if (receivedAction.id != null) {
        AwesomeNotifications().cancel(receivedAction.id!);
      }
      return;
    }

    // Handle Payload Navigation
    final payload = receivedAction.payload;
    if (payload == null || payload.isEmpty) return;

    debugPrint('📱 Notification tapped with payload: $payload');

    try {
      // 1. Handle Quran notifications -> Al-Fatiha
      if (payload['type'] == 'quran') {
        debugPrint('📱 Navigating to Al-Fatiha screen');
        Get.toNamed('/home/al-fatiha');
        return;
      }

      // 2. Handle Goal Dhikr notifications -> Bottom Bar First Tab
      if (payload['type'] == 'goal_adhkar') {
        debugPrint('📱 Navigating to Bottom Bar (Adhkar Goal)');
        Get.offAllNamed('/bottom-bar');
        return;
      }

      // 3. Handle original Adhkar notifications (Morning/Evening/Night Slot) -> Adhkar Screen
      if (payload['type'] == 'adhkar') {
        final segment = int.tryParse(payload['segment'] ?? '');
        if (segment != null) {
          debugPrint('📱 Navigating to Adhkar screen with segment: $segment');
          Get.toNamed('/home/adkhar', arguments: segment);
        }
      }
      // 4. Handle Namaz notifications
      if (payload['type'] == 'namaz') {
        debugPrint('📱 Navigating to Namaz screen (or home)');
        // Add navigation logic here if needed, e.g., Get.toNamed(Routes.NAMAZ);
      }
    } catch (e) {
      debugPrint('❌ Error handling notification tap: $e');
    }
  }

  Future<void> _heavyInitInBackground() async {
    await Future.delayed(Duration.zero);

    try {
      await setupFCM();

      Future.microtask(() async {
        await scheduleAllDailyReminders();
        isInitialized.value = true;
      });
    } catch (e) {
      debugPrint('❌ Background init error: $e');
      isInitialized.value = true;
    }
  }

  // Old listeners removed

  Future<void> scheduleNamazNotifications({bool force = false}) async {
    debugPrint('DEBUG: Calling scheduleNamazNotifications(force: $force)...');
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final storage = GetStorage();
      final now = DateTime.now();

      // Prevent redundant scheduling (unless forced or 24h passed)
      final lastScheduledStr = storage.read('last_namaz_schedule_time');
      if (!force && lastScheduledStr != null) {
        final lastScheduled = DateTime.parse(lastScheduledStr);
        if (now.difference(lastScheduled).inHours < 24) {
          debugPrint(
            '⏭️ Skipping scheduleNamazNotifications (already scheduled recently)',
          );
          return;
        }
      }

      final locationController = Get.find<LocationController>();
      Position? position = await locationController.getUserLocation();

      if (position == null) {
        debugPrint('⚠️ Cannot schedule notifications: Location not available');
        return;
      }

      final prayerResults = await IsolateWorkers.calculatePrayerTimes(
        position: position,
        juristicMethod: storage.read('juristicMethod') ?? 'Hanafi',
        calculationMethod: 'Muslim World League',
      );

      if (prayerResults.error != null) {
        debugPrint('❌ Error calculating prayer times: ${prayerResults.error}');
        return;
      }

      final UI_PRAYERS = ['Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'];

      // Clear existing prayer notifications
      for (int i = 0; i < 70; i++) {
        await AwesomeNotifications().cancel(2000 + i);
      }

      for (var dayResult in prayerResults.prayerSchedule) {
        int dayIndex = dayResult['day'];
        DateTime dayDate = dayResult['date'];
        Map<String, DateTime> dayPrayers = dayResult['prayers'];

        for (int pIdx = 0; pIdx < UI_PRAYERS.length; pIdx++) {
          final pName = UI_PRAYERS[pIdx];
          final isEnabled = storage.read('notify_$pName') ?? true;
          if (!isEnabled) continue;

          // Check if this prayer has a manual override
          final bool isManual =
              prefs.getBool('prayer_${pName}_is_manual') ?? false;
          DateTime? scheduleTime;

          if (isManual) {
            final String? manualTimeStr = prefs.getString('prayer_$pName');
            scheduleTime = _parsePrayerTime(manualTimeStr, dayDate);
            if (scheduleTime != null) {
              debugPrint('⚙️ Using Manual override for $pName: $manualTimeStr');
            }
          }

          // Fallback to calculated time if not manual or parsing failed
          scheduleTime ??= dayPrayers[pName];

          if (scheduleTime != null && scheduleTime.isAfter(now)) {
            final notificationId = 2000 + (dayIndex * 10) + pIdx;

            debugPrint(
              '🔔 Scheduled $pName for day ${dayIndex + 1} at $scheduleTime (ID: $notificationId)',
            );

            await AwesomeNotifications().createNotification(
              content: NotificationContent(
                id: notificationId,
                channelKey: 'prayer_azan_channel_v4',
                title: 'Time for $pName Prayer',
                body: "It's time to pray $pName.",
                notificationLayout: NotificationLayout.Default,
                category: NotificationCategory.Alarm,
                wakeUpScreen: true,
                fullScreenIntent: true,
                autoDismissible: false,
                payload: {'type': 'namaz', 'prayerName': pName},
                customSound: 'resource://raw/azan',
              ),
              actionButtons: [
                NotificationActionButton(
                  key: 'stop_azan',
                  label: 'Stop',
                  actionType: ActionType.SilentAction,
                ),
              ],
              schedule: NotificationCalendar.fromDate(date: scheduleTime),
            );
          }
        }
      }

      await storage.write('last_namaz_schedule_time', now.toIso8601String());
      debugPrint('✅ Namaz notifications scheduled successfully for 1 week');

      // Refresh NamazController UI if it's currently active/registered
      if (Get.isRegistered<NamazController>()) {
        Get.find<NamazController>().refreshUI();
        debugPrint('🔄 Refreshed NamazController UI');
      }
    } catch (e) {
      debugPrint('❌ Error in scheduleNamazNotifications: $e');
    }
  }

  // Restore the parse helper as we now need it for manual overrides
  DateTime? _parsePrayerTime(String? timeStr, DateTime day) {
    if (timeStr == null || timeStr.isEmpty) return null;
    try {
      final cleanStr = timeStr
          .replaceAll(RegExp(r'[\u00A0\u2007\u202F]'), ' ')
          .trim();
      final parts = cleanStr.split(RegExp(r'\s+'));
      if (parts.length < 2) return null;
      final hm = parts[0].split(':');
      if (hm.length < 2) return null;
      int hour = int.parse(hm[0]);
      int minute = int.parse(hm[1]);
      bool isPM = parts[1].toUpperCase() == 'PM';
      if (isPM && hour != 12) hour += 12;
      if (!isPM && hour == 12) hour = 0;
      return DateTime(day.year, day.month, day.day, hour, minute);
    } catch (e) {
      return null;
    }
  }

  Future<void> scheduleReminder({
    required int notificationId,
    required String title,
    required String body,
    required String time,
    bool startFromTomorrow = false,
  }) async {
    try {
      debugPrint("🔔 scheduleReminder() → $title at time: [$time]");

      final cleanedTime = time
          .replaceAll(RegExp(r'[\u00A0\u2007\u202F]'), ' ')
          .trim()
          .replaceAll('\n', '')
          .replaceAll('\r', '');

      // Robust splitting handling multiple spaces
      final parts = cleanedTime.split(RegExp(r'\s+'));
      if (parts.length < 2 || !parts[0].contains(':')) {
        debugPrint('⚠️ Invalid time format after cleaning: "$cleanedTime"');
        return;
      }

      final hourMinute = parts[0].split(':');
      int hour = int.parse(hourMinute[0]);
      int minute = int.parse(hourMinute[1]);
      final period = parts[1].toUpperCase();

      if (period == 'PM' && hour != 12) hour += 12;
      if (period == 'AM' && hour == 12) hour = 0;

      final now = DateTime.now();
      DateTime scheduleTime = DateTime(
        now.year,
        now.month,
        now.day,
        hour,
        minute,
      );

      if (scheduleTime.isBefore(now)) {
        scheduleTime = scheduleTime.add(const Duration(days: 1));
      }

      if (startFromTomorrow) {
        final todaySameTime = DateTime(
          now.year,
          now.month,
          now.day,
          hour,
          minute,
        );
        if (todaySameTime.isAfter(now)) {
          scheduleTime = todaySameTime.add(const Duration(days: 1));
        }
      }

      // Special check for goal reminders: if goals are completed today,
      // ensure we don't schedule for today even if startFromTomorrow logic didn't catch it
      if (notificationId == 1003) {
        final today = now.toIso8601String().split('T').first;
        final completedKey = 'all_goals_completed_$today';
        final goalsCompletedToday =
            (_storage.read(completedKey) ?? false) == true;

        if (goalsCompletedToday) {
          // Check if the scheduled time is still today
          final scheduledDate = scheduleTime.toIso8601String().split('T').first;
          if (scheduledDate == today) {
            // Force schedule for tomorrow
            scheduleTime = scheduleTime.add(const Duration(days: 1));
            debugPrint(
              '⚠️ Goals completed today - forcing goal reminder to tomorrow',
            );
          }
        }
      }

      await AwesomeNotifications().cancel(notificationId);
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: notificationId,
          channelKey: 'daily_reminders_channel',
          title: title,
          body: body,
          category: NotificationCategory.Reminder,
          notificationLayout: NotificationLayout.Default,
        ),
        schedule: NotificationCalendar.fromDate(
          date: scheduleTime,
          allowWhileIdle: true,
          repeats: true,
        ),
      );

      debugPrint(
        "✅ Notification [$title] scheduled at $scheduleTime with ID: $notificationId",
      );
    } catch (e) {
      debugPrint("❌ scheduleReminder() error: $e");
    }
  }

  Future<void> scheduleReminderWithPayload({
    required int notificationId,
    required String title,
    required String body,
    required String time,
    required String payload,
    bool startFromTomorrow = false,
  }) async {
    try {
      debugPrint("🔔 scheduleReminderWithPayload() → $title at time: [$time]");

      final cleanedTime = time
          .replaceAll(RegExp(r'[\u00A0\u2007\u202F]'), ' ')
          .trim()
          .replaceAll('\n', '')
          .replaceAll('\r', '');

      // Robust splitting handling multiple spaces
      final parts = cleanedTime.split(RegExp(r'\s+'));
      if (parts.length < 2 || !parts[0].contains(':')) {
        debugPrint('⚠️ Invalid time format after cleaning: "$cleanedTime"');
        return;
      }

      final hourMinute = parts[0].split(':');
      int hour = int.parse(hourMinute[0]);
      int minute = int.parse(hourMinute[1]);
      final period = parts[1].toUpperCase();

      if (period == 'PM' && hour != 12) hour += 12;
      if (period == 'AM' && hour == 12) hour = 0;

      final now = DateTime.now();
      DateTime scheduleTime = DateTime(
        now.year,
        now.month,
        now.day,
        hour,
        minute,
      );

      if (scheduleTime.isBefore(now)) {
        scheduleTime = scheduleTime.add(const Duration(days: 1));
      }

      if (startFromTomorrow) {
        final todaySameTime = DateTime(
          now.year,
          now.month,
          now.day,
          hour,
          minute,
        );
        if (todaySameTime.isAfter(now)) {
          scheduleTime = todaySameTime.add(const Duration(days: 1));
        }
      }

      Map<String, String> payloadMap = {};
      try {
        final decoded = jsonDecode(payload) as Map<String, dynamic>;
        decoded.forEach((key, value) {
          payloadMap[key] = value.toString();
        });
      } catch (e) {
        debugPrint(
          "Error decoding payload string in scheduleReminderWithPayload: $e",
        );
        // fallback if payload is not json
        payloadMap = {'data': payload};
      }

      await AwesomeNotifications().cancel(notificationId);
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: notificationId,
          channelKey: 'daily_reminders_channel',
          title: title,
          body: body,
          category: NotificationCategory.Reminder,
          notificationLayout: NotificationLayout.Default,
          payload: payloadMap,
        ),
        schedule: NotificationCalendar.fromDate(
          date: scheduleTime,
          allowWhileIdle: true,
          repeats: true,
        ),
      );

      debugPrint(
        "✅ Notification [$title] scheduled at $scheduleTime with ID: $notificationId and payload: $payload",
      );
    } catch (e) {
      debugPrint("❌ scheduleReminderWithPayload() error: $e");
    }
  }

  Future<void> scheduleQuranReminder(String time) async {
    await scheduleReminderWithPayload(
      notificationId: 1000,
      title: 'Quran Reading',
      body: 'Reconnect with the words of Allah. Your daily Quran reminder.',
      time: time,
      payload: '{"type":"quran"}',
    );
  }

  Future<void> scheduleAdhkarReminder(String time) async {
    await scheduleReminderWithPayload(
      notificationId: 1001,
      title: 'Evening Dhikr Reminder',
      body: 'End your day with Allah’s remembrance and calm your heart.',
      time: time,
      payload: '{"type":"adhkar","segment":2}',
    );
  }

  Future<void> scheduleNightReminder(String time) async {
    await scheduleReminderWithPayload(
      notificationId: 1006,
      title: 'Night Adhkar',
      body: 'Close your day with the remembrance of Allah.',
      time: time,
      payload: '{"type":"adhkar","segment":3}',
    );
  }

  Future<void> scheduleGoalDhikrReminder(String time) async {
    await scheduleReminderWithPayload(
      notificationId: 1007,
      title: 'Daily Dhikr Goal',
      body: 'Don\'t forget your daily dhikr goals. Refresh your soul.',
      time: time,
      payload: '{"type":"goal_adhkar"}',
    );
  }

  Future<void> scheduleMemorizationReminder(String time) async {
    await scheduleReminder(
      notificationId: 1002,
      title: 'Time to Read Quran',
      body: 'Take a few moments to connect with the words of Allah today.',
      time: time,
    );
  }

  Future<void> scheduleGoalReminder(String time) async {
    // Completely disabled as per user request to only show Quran Reading notification
    await AwesomeNotifications().cancel(1003);
    debugPrint(
      '🚫 scheduleGoalReminder() BLOCKED - Spiritual Goal reminders are disabled',
    );
    return;

    // final today = DateTime.now().toIso8601String().split('T').first;
    // final completedKey = 'all_goals_completed_$today';
    // final goalsCompletedToday = (_storage.read(completedKey) ?? false) == true;

    // // If goals are already completed today, cancel any existing notification
    // // and only schedule for tomorrow
    // if (goalsCompletedToday) {
    //   await flutterLocalNotificationsPlugin.cancel(1003);
    //   debugPrint(
    //     '✅ Goals completed today - cancelled today\'s goal reminder notification',
    //   );
    // }

    // await scheduleReminder(
    //   notificationId: 1003,
    //   title: 'Spiritual Goals',
    //   body: 'Take a moment to complete your spiritual goals for today.',
    //   time: time,
    //   startFromTomorrow: goalsCompletedToday,
    // );
  }

  Future<void> onGoalCompletedToday() async {
    try {
      await AwesomeNotifications().cancel(1003);

      final storedPreferences = _storage.read('isPreferencesSet');
      final prefsMap = storedPreferences == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(storedPreferences);
      if (prefsMap['isGoalReminder'] != true) return;

      final goalTime = await AppReminderService.getGoalTime();
      if (goalTime == null) return;

      await scheduleReminder(
        notificationId: 1003,
        title: 'Spiritual Goals',
        body: 'Take a moment to complete your spiritual goals for today.',
        time: AppReminderService.formatTime(goalTime),
        startFromTomorrow: true,
      );
    } catch (e) {
      debugPrint('❌ onGoalCompletedToday() error: $e');
    }
  }

  Future<void> onGoalBecameIncompleteToday() async {
    try {
      final storedPreferences = _storage.read('isPreferencesSet');
      final prefsMap = storedPreferences == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(storedPreferences);
      if (prefsMap['isGoalReminder'] != true) return;

      final goalTime = await AppReminderService.getGoalTime();
      if (goalTime == null) return;

      await scheduleGoalReminder(AppReminderService.formatTime(goalTime));
    } catch (e) {
      debugPrint('❌ onGoalBecameIncompleteToday() error: $e');
    }
  }

  Future<void> scheduleMorningReminder(String time) async {
    await scheduleReminderWithPayload(
      notificationId: 1004,
      title: 'Start with Allah’s Name',
      body: 'Recite your morning adhkar for protection, peace, and barakah.',
      time: time,
      payload: '{"type":"adhkar","segment":1}',
    );
  }

  Future<void> scheduleEveningReminder(String time) async {
    await scheduleReminderWithPayload(
      notificationId: 1005,
      title: 'Protect Your Evening',
      body: 'End your day with Allah’s remembrance and calm your heart.',
      time: time,
      payload: '{"type":"adhkar","segment":3}',
    );
  }

  Future<void> showTestNotification() async {
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: 9999,
        channelKey: 'daily_reminders_channel',
        title: 'Test Notification',
        body: 'NooreQuran notifications are working correctly.',
        notificationLayout: NotificationLayout.Default,
      ),
    );
    debugPrint('✅ Test notification shown');
  }

  Future<void> showGoalCompletionNotification() async {
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: 8888,
        channelKey: 'goal_completion_channel',
        title: 'MashaAllah!',
        body: 'You have successfully completed your spiritual goal for today.',
        notificationLayout: NotificationLayout.Default,
        category: NotificationCategory.Status,
      ),
    );
  }

  Future<void> setupFCM() async {
    await firebaseMessaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    try {
      String? token = await firebaseMessaging.getToken();
      if (token != null) {
        print('FCM Token: $token');
        _storage.write('token', token);
      }
    } catch (e) {
      debugPrint('❌ FCM Token Error: $e');
    }

    FirebaseMessaging.onMessage.listen((message) async {
      if (message.notification != null) {
        // FCM notification handling via AwesomeNotifications or default
        // For now, removing the direct FLN call.
        // We can create a basic AwesomeNotification here if needed.
        await AwesomeNotifications().createNotification(
          content: NotificationContent(
            id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
            channelKey: 'daily_reminders_channel', // using an existing channel
            title: message.notification?.title,
            body: message.notification?.body,
            notificationLayout: NotificationLayout.Default,
          ),
        );
      }
    });

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      print('Notification tapped: ${message.notification?.title}');
    });
  }

  Future<void> sendNudge(UserModel friend) async {
    try {
      final nudge = NotificationModal(
        senderId: CurrentAppUser.currentUserData.id,
        receiverId: friend.id,
        title: 'Islamic Encouragement',
        desc:
            '${CurrentAppUser.currentUserData.name} is encouraging you to read the Quran and complete your Adhkar. Let us earn rewards together!',
        type: 'nudge',
        createdAt: Timestamp.now(),
        status: 0,
      );

      await _firestore
          .collection('notifications')
          .add(NotificationModal.toMap(nudge));
      debugPrint('✅ Nudge sent to ${friend.name} and saved to Firestore.');
    } catch (e) {
      debugPrint('❌ Error sending nudge: $e');
    }
  }

  Future<void> scheduleAllDailyReminders() async {
    try {
      final storage = GetStorage();
      final storedPreferences = storage.read('isPreferencesSet');
      if (storedPreferences == null) return;

      final prefsMap = Map<String, dynamic>.from(storedPreferences);

      // 1. Quran Reminder
      if (prefsMap['isDailyReminder'] == true) {
        final time = await AppReminderService.getQuranTime();
        if (time != null) {
          await scheduleQuranReminder(AppReminderService.formatTime(time));
        } else if (prefsMap['dailyReminder'] != null) {
          await scheduleQuranReminder(prefsMap['dailyReminder']);
        }
      } else {
        await AwesomeNotifications().cancel(1000);
      }

      // 2. Adhkar Reminder
      if (prefsMap['isDailyAdhkarReminder'] == true) {
        final time = await AppReminderService.getAdhkarTime();
        if (time != null) {
          await scheduleAdhkarReminder(AppReminderService.formatTime(time));
        } else if (prefsMap['dailyAdhkarReminder'] != null) {
          await scheduleAdhkarReminder(prefsMap['dailyAdhkarReminder']);
        }
      } else {
        await AwesomeNotifications().cancel(1001);
      }

      // 3. Memorization Reminder
      if (prefsMap['isDailyMemorizationReminder'] == true) {
        final time = await AppReminderService.getMemorizationTime();
        if (time != null) {
          await scheduleMemorizationReminder(
            AppReminderService.formatTime(time),
          );
        } else if (prefsMap['dailyMemorizationReminder'] != null) {
          await scheduleMemorizationReminder(
            prefsMap['dailyMemorizationReminder'],
          );
        }
      } else {
        await AwesomeNotifications().cancel(1002);
      }

      // 4. Goal Reminder (Disabled as per user request)
      await AwesomeNotifications().cancel(1003);
      // if (prefsMap['isGoalReminder'] == true) {
      //   final time = await AppReminderService.getGoalTime();
      //   if (time != null) {
      //     await scheduleGoalReminder(AppReminderService.formatTime(time));
      //   }
      // } else {
      //   await flutterLocalNotificationsPlugin.cancel(1003);
      // }

      // 5. Morning Reminder
      if (prefsMap['isMorningReminder'] == true) {
        final time = await AppReminderService.getMorningTime();
        if (time != null) {
          await scheduleMorningReminder(AppReminderService.formatTime(time));
        } else if (prefsMap['morningReminder'] != null) {
          await scheduleMorningReminder(prefsMap['morningReminder']);
        }
      } else {
        await AwesomeNotifications().cancel(1004);
      }

      // 6. Evening Reminder (Notification Setting Slot 2)
      if (prefsMap['isDailyAdhkarReminder'] == true) {
        final time = await AppReminderService.getAdhkarTime();
        if (time != null) {
          await scheduleAdhkarReminder(AppReminderService.formatTime(time));
        } else if (prefsMap['dailyAdhkarReminder'] != null) {
          await scheduleAdhkarReminder(prefsMap['dailyAdhkarReminder']);
        }
      } else {
        await AwesomeNotifications().cancel(1001);
      }

      // 7. Night Reminder (Mapped to eveningReminder/isEveningReminder as Slot 3)
      if (prefsMap['isEveningReminder'] == true) {
        final time = await AppReminderService.getEveningTime();
        if (time != null) {
          await scheduleNightReminder(AppReminderService.formatTime(time));
        } else if (prefsMap['eveningReminder'] != null) {
          await scheduleNightReminder(prefsMap['eveningReminder']);
        }
        // Ensure legacy ID 1005 is cancelled to avoid double notifications
        await AwesomeNotifications().cancel(1005);
      } else {
        await AwesomeNotifications().cancel(1005);
        await AwesomeNotifications().cancel(1006);
      }

      // 8. Goal Dhikr Reminder (Independent)
      final goalDhikrTime = await AppReminderService.getGoalDhikrTime();
      if (goalDhikrTime != null) {
        await scheduleGoalDhikrReminder(
          AppReminderService.formatTime(goalDhikrTime),
        );
      }

      // 7. Namaz Notifications (heavy operation, run last)
      await scheduleNamazNotifications();

      debugPrint('✅ All selected daily reminders have been rescheduled');
    } catch (e) {
      debugPrint('❌ Error in scheduleAllDailyReminders: $e');
    }
  }

  Future<UserModel?> getSenderDetails(String senderId) async {
    try {
      final doc = await _firestore.collection('users').doc(senderId).get();
      if (doc.exists) {
        return UserModel.fromMap(doc.data()!);
      }
    } catch (e) {
      debugPrint('❌ Error fetching sender details: $e');
    }
    return null;
  }
}

// Background message handler - MUST be top-level function
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('Received background FCM: ${message.notification?.title}');
  SharedPreferences prefs = await SharedPreferences.getInstance();
  int bc = (prefs.getInt("badgeCount") ?? 0) + 1;
  await prefs.setInt("badgeCount", bc);
  await AppBadgePlus.updateBadge(bc);
}
