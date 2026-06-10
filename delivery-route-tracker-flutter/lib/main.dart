import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart' as permissions;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const DeliveryTrackerApp());
}

class DeliveryTrackerApp extends StatefulWidget {
  const DeliveryTrackerApp({super.key});

  @override
  State<DeliveryTrackerApp> createState() => _DeliveryTrackerAppState();
}

class _DeliveryTrackerAppState extends State<DeliveryTrackerApp> {
  bool _darkMode = false;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _darkMode = prefs.getBool('dark_mode') ?? false);
  }

  Future<void> _setDarkMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', value);
    if (!mounted) return;
    setState(() => _darkMode = value);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Delivery Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff0f766e),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff7f8fa),
        cardTheme: const CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2dd4bf),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xff0b0f14),
        cardTheme: const CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      themeMode: _darkMode ? ThemeMode.dark : ThemeMode.light,
      home: TrackerPage(darkMode: _darkMode, onDarkModeChanged: _setDarkMode),
    );
  }
}

class TrackerPage extends StatefulWidget {
  const TrackerPage({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
  });

  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  @override
  State<TrackerPage> createState() => _TrackerPageState();
}

class _TrackerPageState extends State<TrackerPage> {
  static const _stopRadiusMeters = 300.0;
  static const _stopAfter = Duration(seconds: 60);
  static const _trackingNotificationId = 1001;
  static const _stopNotificationId = 1002;
  static const _batterySafeModeKey = 'battery_safe_mode';
  static const _activeShiftKey = 'active_shift_id';
  static const _shiftRecoveryGraceMinutesKey = 'shift_recovery_grace_minutes';
  static const _maxAcceptedAccuracyMeters = 55.0;
  static const _maxAcceptedSpeedMetersPerSecond = 45.0;

  final _store = ShiftStore();
  final _notifications = FlutterLocalNotificationsPlugin();
  final List<Shift> _savedShifts = [];
  StreamSubscription<Position>? _positionSub;
  Timer? _clock;
  Shift? _activeShift;
  StopDraft? _stopDraft;
  TrackPoint? _lastKnownPoint;
  DateTime? _lastAutoSaveAt;
  DateTime _now = DateTime.now();
  DateTime _selectedDay = DateTime.now();
  PerformancePeriod _performancePeriod = PerformancePeriod.day;
  String _status = 'Ready to track';
  PermissionSnapshot _permissions = const PermissionSnapshot();
  bool _notificationsReady = false;
  bool _batterySafeMode = true;
  bool _locationStreamStoppedMode = false;
  bool _isStoppingShift = false;
  String _lastGpsError = 'No GPS errors logged';
  int _shiftRecoveryGraceMinutes = 120;
  final List<DiagnosticEntry> _diagnostics = [];
  int _tabIndex = 0;

  bool get _isTracking => _activeShift != null;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _loadHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrapPermissions();
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final shifts = await _store.load();
    final activeId = prefs.getString(_activeShiftKey);
    final graceMinutes = prefs.getInt(_shiftRecoveryGraceMinutesKey) ?? 120;
    var recoveredShift = activeId == null ? null : await _store.loadActive();
    if (activeId != null) {
      if (recoveredShift == null || recoveredShift.id != activeId) {
        for (final shift in shifts) {
          final recoverable =
              shift.id == activeId &&
              shift.endedAt == null &&
              DateTime.now().difference(shift.lastActivityAt) <=
                  Duration(minutes: graceMinutes);
          if (recoverable) {
            recoveredShift = shift;
            break;
          }
        }
      }
      if (recoveredShift != null &&
          (recoveredShift.endedAt != null ||
              DateTime.now().difference(recoveredShift.lastActivityAt) >
                  Duration(minutes: graceMinutes))) {
        recoveredShift = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _batterySafeMode = prefs.getBool(_batterySafeModeKey) ?? true;
      _shiftRecoveryGraceMinutes = graceMinutes;
      if (recoveredShift != null) {
        _activeShift = recoveredShift;
        _lastKnownPoint = recoveredShift.points.isEmpty
            ? null
            : recoveredShift.points.last;
        _status = 'Recovered active shift';
        _now = DateTime.now();
      }
      _savedShifts
        ..clear()
        ..addAll(shifts.where((shift) => shift.id != recoveredShift?.id));
    });
    if (recoveredShift != null) {
      _startRuntimeForRecoveredShift(recoveredShift);
    }
  }

  Future<void> _startRuntimeForRecoveredShift(Shift shift) async {
    await _showTrackingNotification();
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      _showTrackingNotification();
    });
    try {
      _positionSub =
          Geolocator.getPositionStream(
            locationSettings: _locationSettings(),
          ).listen(
            _handlePosition,
            onError: (error) => _recordGpsError(error.toString()),
          );
      _locationStreamStoppedMode = _stopDraft?.confirmed == true;
      _logDiagnostic('Shift recovery', 'Recovered shift ${shift.id}');
    } catch (error) {
      _recordGpsError('Could not resume GPS stream: $error');
    }
  }

  Future<void> _initNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    try {
      await _notifications.initialize(
        const InitializationSettings(android: android),
        onDidReceiveNotificationResponse: _handleNotificationResponse,
      );
      _notificationsReady = true;
    } catch (_) {
      _notificationsReady = false;
    }
  }

  Future<void> _bootstrapPermissions() async {
    await _refreshPermissions();
    if (!_permissions.requiredGranted) {
      await _requestAppPermissions();
    }
  }

  Future<void> _startShift() async {
    if (_isTracking) return;
    final allowed = await _ensureLocationPermission();
    if (!allowed) return;

    final shift = Shift(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      startedAt: DateTime.now(),
    );
    shift.lifecycleEvents.add(
      DeliveryLifecycleEvent(
        stage: DeliveryLifecycleStage.shiftStarted,
        timestamp: shift.startedAt,
      ),
    );
    shift.lifecycleEvents.add(
      DeliveryLifecycleEvent(
        stage: DeliveryLifecycleStage.waitingForOrder,
        timestamp: DateTime.now(),
      ),
    );
    setState(() {
      _activeShift = shift;
      _stopDraft = null;
      _status = 'Tracking active - waiting for GPS';
      _now = DateTime.now();
    });
    await _markShiftActive(shift);
    await _autosaveActiveShift(shift, force: true);
    unawaited(_primeCurrentLocation(shift));

    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      _showTrackingNotification();
    });
    await _showTrackingNotification();

    final settings = _locationSettings();
    try {
      _positionSub = Geolocator.getPositionStream(locationSettings: settings)
          .listen(
            _handlePosition,
            onError: (error) => _recordGpsError(error.toString()),
          );
      _locationStreamStoppedMode = false;
      _logDiagnostic(
        'Background service',
        'Foreground location stream started',
      );
    } catch (_) {
      _clock?.cancel();
      _clock = null;
      setState(() {
        _activeShift = null;
        _status = 'Could not start GPS tracking';
      });
    }
  }

  Future<void> _markShiftActive(Shift shift) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeShiftKey, shift.id);
    await _store.saveActive(shift);
  }

  Future<void> _clearActiveShiftMarker() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeShiftKey);
    await _store.clearActive();
  }

  Future<bool> _confirmLeaveDuringShift() async {
    if (!_isTracking || !mounted) return true;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Shift is still active'),
        content: Text(
          'Back is locked while tracking so accidental presses do not close the app. Use the phone Home button to background the app, or End shift when you are finished. Recovery is kept for $_shiftRecoveryGraceMinutes minutes.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return false;
  }

  LocationSettings _locationSettings() {
    final stopped = _stopDraft?.confirmed == true;
    final accuracy = _batterySafeMode && stopped
        ? LocationAccuracy.high
        : LocationAccuracy.bestForNavigation;
    final distanceFilter = _batterySafeMode && stopped ? 50 : 10;
    final intervalDuration = _batterySafeMode && stopped
        ? const Duration(seconds: 30)
        : const Duration(seconds: 5);
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        intervalDuration: intervalDuration,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Delivery Tracker active',
          notificationText: 'Recording your delivery route in the background',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }

    return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  }

  Future<bool> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => _status = 'Turn on phone location services');
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      setState(() => _status = 'Location permission is required');
      return false;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      final notification = await permissions.Permission.notification.request();
      if (notification.isDenied || notification.isPermanentlyDenied) {
        setState(
          () => _status =
              'Notification permission is needed for background tracking',
        );
        await _refreshPermissions();
        return false;
      }
    }
    await _refreshPermissions();
    return true;
  }

  Future<void> _requestAppPermissions() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => _status = 'Turn on phone location services');
      await Geolocator.openLocationSettings();
      return;
    }

    var location = await Geolocator.checkPermission();
    if (location == LocationPermission.denied) {
      location = await Geolocator.requestPermission();
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      await permissions.Permission.notification.request();
      await permissions.Permission.locationAlways.request();
    }
    await _refreshPermissions();
  }

  Future<void> _requestOverlayPermission() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await permissions.Permission.systemAlertWindow.request();
    await _refreshPermissions();
  }

  Future<void> _refreshPermissions() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final location = await Geolocator.checkPermission();
    var notificationGranted = true;
    var overlayGranted = true;
    if (defaultTargetPlatform == TargetPlatform.android) {
      notificationGranted = await permissions.Permission.notification.isGranted;
      overlayGranted = await permissions.Permission.systemAlertWindow.isGranted;
    }
    if (!mounted) return;
    setState(() {
      _permissions = PermissionSnapshot(
        locationServices: serviceEnabled,
        location: location,
        notificationGranted: notificationGranted,
        overlayGranted: overlayGranted,
      );
    });
  }

  Future<void> _primeCurrentLocation(Shift shift) async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 12),
        ),
      );
      final point = TrackPoint(
        latitude: position.latitude,
        longitude: position.longitude,
        timestamp: DateTime.now(),
        accuracy: position.accuracy,
        speedMetersPerSecond: max(0, position.speed),
      );
      final filtered = _qualityCheckedPoint(
        point,
        previous: shift.points.isEmpty ? null : shift.points.last,
      );
      if (filtered == null) return;
      shift.points.add(filtered);
      _lastKnownPoint = filtered;
      if (mounted && identical(_activeShift, shift)) {
        setState(() {
          _status = 'Tracking active';
        });
        await _showTrackingNotification();
      }
    } catch (error) {
      _recordGpsError('Initial GPS point failed: $error');
    }
  }

  void _handlePosition(Position position) {
    final point = TrackPoint(
      latitude: position.latitude,
      longitude: position.longitude,
      timestamp: DateTime.now(),
      accuracy: position.accuracy,
      speedMetersPerSecond: max(0, position.speed),
    );

    final shift = _activeShift;
    if (shift == null) return;
    final filtered = _qualityCheckedPoint(
      point,
      previous: shift.points.isEmpty ? null : shift.points.last,
    );
    if (filtered == null) return;

    StopEvent? newStop;
    setState(() {
      final stopCount = shift.stops.length;
      shift.points.add(filtered);
      _lastKnownPoint = filtered;
      _status = 'Tracking active';
      _updateSegmentsAndStops(shift, filtered);
      if (shift.stops.length > stopCount) {
        newStop = shift.stops.last;
        _status = 'Stop detected - choose a stop type';
      }
      _now = DateTime.now();
    });
    if (newStop != null) {
      unawaited(_showStopClassificationNotification(newStop!));
      unawaited(_promptStopClassification(newStop!));
    }
    unawaited(_syncLocationStreamMode());
    unawaited(_showTrackingNotification());
    unawaited(_autosaveActiveShift(shift));
  }

  Future<void> _autosaveActiveShift(Shift shift, {bool force = false}) async {
    final now = DateTime.now();
    _closeEligibleDeliveryTrips(shift, now);
    if (!force &&
        _lastAutoSaveAt != null &&
        now.difference(_lastAutoSaveAt!) < const Duration(seconds: 30)) {
      return;
    }
    _lastAutoSaveAt = now;
    shift.lastActivityAt = now;
    await _store.saveActive(shift);
  }

  void _closeEligibleDeliveryTrips(Shift shift, DateTime now) {
    for (final trip in shift.deliveryTrips) {
      if (trip.endedAt != null) continue;
      final eligibleAt = trip.eligibleForClosureAt;
      final waiting =
          shift.currentStage?.stage == DeliveryLifecycleStage.waitingForOrder;
      if (trip.allOrdersDelivered &&
          waiting &&
          eligibleAt != null &&
          !now.isBefore(eligibleAt)) {
        trip.endedAt = now;
      }
    }
  }

  TrackPoint? _qualityCheckedPoint(TrackPoint point, {TrackPoint? previous}) {
    if (point.accuracy > _maxAcceptedAccuracyMeters) {
      _logDiagnostic(
        'GPS filter',
        'Rejected weak point: ${point.accuracy.toStringAsFixed(0)}m accuracy',
      );
      return null;
    }
    if (point.speedMetersPerSecond > _maxAcceptedSpeedMetersPerSecond) {
      _logDiagnostic(
        'GPS filter',
        'Rejected speed spike: ${(point.speedMetersPerSecond * 3.6).toStringAsFixed(0)} km/h',
      );
      return null;
    }
    if (previous != null) {
      final seconds =
          point.timestamp.difference(previous.timestamp).inMilliseconds / 1000;
      if (seconds > 0) {
        final distance = haversineMeters(previous, point);
        final inferredSpeed = distance / seconds;
        if (inferredSpeed > _maxAcceptedSpeedMetersPerSecond &&
            distance > 120) {
          _logDiagnostic(
            'GPS filter',
            'Rejected jump: ${distance.toStringAsFixed(0)}m in ${seconds.toStringAsFixed(1)}s',
          );
          return null;
        }
      }
    }
    return point;
  }

  void _recordGpsError(String message) {
    if (!mounted) return;
    setState(() {
      _status = 'GPS signal unavailable';
      _lastGpsError = message;
    });
    _logDiagnostic('GPS error', message);
  }

  void _logDiagnostic(String title, String message) {
    if (!mounted) return;
    setState(() {
      _diagnostics.insert(
        0,
        DiagnosticEntry(
          title: title,
          message: message,
          timestamp: DateTime.now(),
        ),
      );
      if (_diagnostics.length > 20) {
        _diagnostics.removeRange(20, _diagnostics.length);
      }
    });
  }

  Future<void> _syncLocationStreamMode() async {
    if (!_batterySafeMode || _activeShift == null) return;
    final shouldUseStoppedMode = _stopDraft?.confirmed == true;
    if (_locationStreamStoppedMode == shouldUseStoppedMode) return;
    _locationStreamStoppedMode = shouldUseStoppedMode;
    await _positionSub?.cancel().timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    );
    if (_activeShift == null) return;
    _positionSub =
        Geolocator.getPositionStream(
          locationSettings: _locationSettings(),
        ).listen(
          _handlePosition,
          onError: (error) => _recordGpsError(error.toString()),
        );
  }

  Future<void> _showTrackingNotification() async {
    final shift = _activeShift;
    if (shift == null || !_notificationsReady) return;

    final stage = shift.currentStage;
    const androidDetails = AndroidNotificationDetails(
      'delivery_live_trip',
      'Live trip',
      channelDescription: 'Shows active delivery trip time and distance',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: false,
      icon: 'ic_stat_delivery',
      actions: [
        AndroidNotificationAction(
          'stage_accepted',
          'Accepted',
          cancelNotification: false,
        ),
        AndroidNotificationAction(
          'stage_atRestaurant',
          'At restaurant',
          cancelNotification: false,
        ),
        AndroidNotificationAction(
          'stage_pickedUp',
          'Picked up',
          cancelNotification: false,
        ),
        AndroidNotificationAction(
          'stage_delivered',
          'Delivered',
          cancelNotification: false,
        ),
      ],
    );
    final time = formatDuration(shift.movingDuration);
    final distance = (shift.distanceMeters / 1000).toStringAsFixed(2);
    final mode = _batterySafeMode ? 'battery-safe' : 'high accuracy';
    final activeOrders = shift.activeOrderCount;
    try {
      await _notifications.show(
        _trackingNotificationId,
        stage == null ? 'Delivery trip active' : stage.stage.label,
        '$activeOrders active orders - $time - $distance km - $mode',
        const NotificationDetails(android: androidDetails),
      );
    } catch (_) {
      // Tracking should continue even if Android refuses the companion notification.
    }
  }

  Future<void> _showStopClassificationNotification(StopEvent stop) async {
    if (!_notificationsReady) return;
    const androidDetails = AndroidNotificationDetails(
      'delivery_stop_type',
      'Stop classification',
      channelDescription: 'Lets you classify detected delivery stops',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      autoCancel: false,
      showWhen: false,
      icon: 'ic_stat_delivery',
      actions: [
        AndroidNotificationAction(
          'stop_restaurant',
          'Restaurant',
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          'stop_customer',
          'Customer',
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          'stop_breakTime',
          'Break',
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          'stop_waitingForOrder',
          'Waiting',
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          'stop_other',
          'Other',
          cancelNotification: true,
        ),
      ],
    );
    try {
      await _notifications.show(
        _stopNotificationId,
        'Stop detected',
        '${formatDuration(stop.duration)} at ${stop.placeLabel}',
        const NotificationDetails(android: androidDetails),
      );
    } catch (_) {
      // The in-app classification prompt remains available.
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final actionId = response.actionId ?? '';
    if (actionId.startsWith('stage_')) {
      final stage = DeliveryLifecycleStageX.fromName(
        actionId.substring('stage_'.length),
      );
      if (stage != null) _recordLifecycleStage(stage);
      return;
    }
    if (actionId.startsWith('stop_')) {
      final type = StopTypeX.fromName(actionId.substring('stop_'.length));
      if (type != null) _classifyLatestStop(type);
    }
  }

  Future<void> _recordLifecycleStage(DeliveryLifecycleStage stage) async {
    final shift = _activeShift;
    if (shift == null) return;
    setState(() {
      shift.lifecycleEvents.add(
        DeliveryLifecycleEvent(stage: stage, timestamp: DateTime.now()),
      );
      _applyLifecycleToTrip(shift, stage);
      _status = stage.statusText;
      _now = DateTime.now();
    });
    await _autosaveActiveShift(shift, force: true);
    await _showTrackingNotification();
  }

  void _applyLifecycleToTrip(Shift shift, DeliveryLifecycleStage stage) {
    final now = DateTime.now();
    shift.lastActivityAt = now;
    switch (stage) {
      case DeliveryLifecycleStage.shiftStarted:
      case DeliveryLifecycleStage.shiftPaused:
      case DeliveryLifecycleStage.shiftEnded:
        return;
      case DeliveryLifecycleStage.waitingForOrder:
        final trip = shift.activeDeliveryTrip;
        if (trip != null && trip.allOrdersDelivered && trip.endedAt == null) {
          trip.eligibleForClosureAt = now.add(
            Duration(minutes: shift.tripClosureGraceMinutes),
          );
        }
        return;
      case DeliveryLifecycleStage.orderAccepted:
        final trip = shift.ensureActiveDeliveryTrip(now);
        trip.eligibleForClosureAt = null;
        trip.orders.add(
          DeliveryOrder(
            id: 'order-${now.millisecondsSinceEpoch}',
            acceptedAt: now,
            status: DeliveryOrderStatus.accepted,
          ),
        );
        return;
      case DeliveryLifecycleStage.travelingToRestaurant:
      case DeliveryLifecycleStage.atRestaurant:
        shift.ensureActiveDeliveryTrip(now).eligibleForClosureAt = null;
        return;
      case DeliveryLifecycleStage.orderPickedUp:
        final trip = shift.ensureActiveDeliveryTrip(now);
        final order = trip.latestOpenOrder;
        if (order != null) {
          order.status = DeliveryOrderStatus.pickedUp;
          order.pickedUpAt = now;
        }
        return;
      case DeliveryLifecycleStage.travelingToCustomer:
        shift.ensureActiveDeliveryTrip(now).eligibleForClosureAt = null;
        return;
      case DeliveryLifecycleStage.delivered:
        final trip = shift.ensureActiveDeliveryTrip(now);
        final order = trip.latestUndeliveredOrder;
        if (order != null) {
          order.status = DeliveryOrderStatus.delivered;
          order.deliveredAt = now;
        }
        if (trip.allOrdersDelivered) {
          trip.eligibleForClosureAt = now.add(
            Duration(minutes: shift.tripClosureGraceMinutes),
          );
        }
        return;
      case DeliveryLifecycleStage.multipleOrdersActive:
      case DeliveryLifecycleStage.delayedAtRestaurant:
      case DeliveryLifecycleStage.customerUnavailable:
      case DeliveryLifecycleStage.orderCancelled:
        shift.ensureActiveDeliveryTrip(now).eligibleForClosureAt = null;
        if (stage == DeliveryLifecycleStage.orderCancelled) {
          final order = shift.activeDeliveryTrip?.latestOpenOrder;
          if (order != null) {
            order.status = DeliveryOrderStatus.cancelled;
            order.cancelledAt = now;
          }
        }
        return;
    }
  }

  Future<void> _classifyLatestStop(StopType type) async {
    final shift = _activeShift;
    if (shift == null || shift.stops.isEmpty) return;
    final stop = shift.stops.lastWhere(
      (item) => item.type == StopType.other,
      orElse: () => shift.stops.last,
    );
    setState(() {
      stop.type = type;
      _status = 'Stop marked as ${type.label}';
    });
    await _autosaveActiveShift(shift, force: true);
    await _notifications.cancel(_stopNotificationId);
  }

  Future<void> _promptStopClassification(StopEvent stop) async {
    if (!mounted || !_isTracking) return;
    final type = await showModalBottomSheet<StopType>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.pause_circle_rounded),
              title: const Text('Classify stop'),
              subtitle: Text(
                '${formatDuration(stop.duration)} at ${stop.placeLabel}',
              ),
            ),
            ...StopType.values.map(
              (item) => ListTile(
                leading: Icon(item.icon),
                title: Text(item.label),
                onTap: () => Navigator.pop(context, item),
              ),
            ),
          ],
        ),
      ),
    );
    if (type == null || !mounted) return;
    setState(() {
      stop.type = type;
      _status = 'Stop marked as ${type.label}';
    });
    final shift = _activeShift;
    if (shift != null) {
      await _autosaveActiveShift(shift, force: true);
    }
    await _notifications.cancel(_stopNotificationId);
  }

  void _updateSegmentsAndStops(Shift shift, TrackPoint point) {
    final moving = point.speedMetersPerSecond > 0.8;

    if (shift.segments.isEmpty) {
      _stopDraft ??= StopDraft(anchor: point, startedAt: point.timestamp);
      final draft = _stopDraft!;
      final distanceFromAnchor = haversineMeters(draft.anchor, point);
      if (distanceFromAnchor > _stopRadiusMeters) {
        shift.segments.add(
          RouteSegment(startedAt: point.timestamp)
            ..points.addAll([draft.anchor, point]),
        );
        _stopDraft = null;
      }
      return;
    }

    final currentSegment = shift.segments.last;
    final anchor = _stopDraft?.anchor ?? currentSegment.points.last;
    final distanceFromAnchor = haversineMeters(anchor, point);
    final insideStopRadius = distanceFromAnchor <= _stopRadiusMeters;

    if (!moving && insideStopRadius) {
      _stopDraft ??= StopDraft(anchor: anchor, startedAt: point.timestamp);
      final draft = _stopDraft!;
      if (!draft.confirmed &&
          point.timestamp.difference(draft.startedAt) >= _stopAfter) {
        draft.confirmed = true;
        currentSegment.endedAt = draft.startedAt;
        shift.stops.add(
          StopEvent(
            latitude: draft.anchor.latitude,
            longitude: draft.anchor.longitude,
            startedAt: draft.startedAt,
            endedAt: point.timestamp,
          ),
        );
      } else if (draft.confirmed && shift.stops.isNotEmpty) {
        shift.stops.last.endedAt = point.timestamp;
      }
      return;
    }

    if (_stopDraft?.confirmed == true) {
      final draft = _stopDraft!;
      final distanceFromStop = haversineMeters(draft.anchor, point);
      if (distanceFromStop > _stopRadiusMeters) {
        shift.segments.add(
          RouteSegment(startedAt: point.timestamp)
            ..points.addAll([draft.anchor, point]),
        );
        _stopDraft = null;
      }
    } else {
      currentSegment.points.add(point);
      _stopDraft = null;
    }
  }

  List<Shift> get _selectedDayShifts {
    final shifts = [..._savedShifts];
    final active = _activeShift;
    if (active != null && !shifts.any((shift) => shift.id == active.id)) {
      shifts.insert(0, active);
    }
    return shifts
        .where((shift) => isSameDay(shift.startedAt, _selectedDay))
        .toList();
  }

  List<Shift> get _allVisibleShifts {
    final shifts = [..._savedShifts];
    final active = _activeShift;
    if (active != null && !shifts.any((shift) => shift.id == active.id)) {
      shifts.insert(0, active);
    }
    return shifts;
  }

  DateTime get _performancePeriodStart =>
      performancePeriodStart(_selectedDay, _performancePeriod);

  DateTime get _performancePeriodEnd =>
      performancePeriodEnd(_selectedDay, _performancePeriod);

  List<Shift> get _selectedPerformanceShifts {
    final start = _performancePeriodStart;
    final end = _performancePeriodEnd;
    return _allVisibleShifts
        .where((shift) => shift.overlapsRange(start, end))
        .toList();
  }

  void _changePerformancePeriod(PerformancePeriod period) {
    setState(() => _performancePeriod = period);
  }

  void _changeSelectedDay(int days) {
    setState(() {
      _selectedDay = DateTime(
        _selectedDay.year,
        _selectedDay.month,
        _selectedDay.day + days,
      );
    });
  }

  Future<void> _copySelectedDayCsv() async {
    final csv = shiftsToCsv(_selectedDayShifts);
    await Clipboard.setData(ClipboardData(text: csv));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Day data copied as CSV')));
  }

  Future<void> _saveSelectedDayCsv() async {
    final shifts = _selectedDayShifts;
    if (shifts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No shifts to save for this day')),
      );
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final filename =
        'delivery_routes_${DateFormat('yyyy_MM_dd').format(_selectedDay)}.csv';
    final file = File('${dir.path}${Platform.pathSeparator}$filename');
    await file.writeAsString(shiftsToCsv(shifts));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved CSV: $filename')));
  }

  Future<void> _saveSelectedDayGpx() async {
    await _saveSelectedDayMapFile(
      extension: 'gpx',
      contents: shiftsToGpx(_selectedDayShifts),
      emptyMessage: 'No GPS points to save as GPX for this day',
    );
  }

  Future<void> _saveSelectedDayKml() async {
    await _saveSelectedDayMapFile(
      extension: 'kml',
      contents: shiftsToKml(_selectedDayShifts),
      emptyMessage: 'No GPS points to save as KML for this day',
    );
  }

  Future<void> _saveSelectedDayMapFile({
    required String extension,
    required String contents,
    required String emptyMessage,
  }) async {
    final hasPoints = _selectedDayShifts.any(
      (shift) => shift.points.isNotEmpty,
    );
    if (!hasPoints) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(emptyMessage)));
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final filename =
        'delivery_routes_${DateFormat('yyyy_MM_dd').format(_selectedDay)}.$extension';
    final file = File('${dir.path}${Platform.pathSeparator}$filename');
    await file.writeAsString(contents);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved ${extension.toUpperCase()}: $filename')),
    );
  }

  Future<void> _exportJsonBackup() async {
    final shifts = await _store.load();
    final backup = shiftsToBackupJson(shifts);
    final dir = await getApplicationDocumentsDirectory();
    final filename =
        'delivery_backup_${DateFormat('yyyy_MM_dd_HHmm').format(DateTime.now())}.json';
    final file = File('${dir.path}${Platform.pathSeparator}$filename');
    await file.writeAsString(backup);
    await Clipboard.setData(ClipboardData(text: backup));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved JSON backup and copied it: $filename')),
    );
  }

  Future<void> _restoreJsonBackupFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Clipboard does not contain a JSON backup'),
        ),
      );
      return;
    }

    List<Shift> shifts;
    try {
      shifts = shiftsFromBackupJson(text);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read backup JSON')),
      );
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text(
          'This will replace saved local shifts with ${shifts.length} restored shifts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.replaceAll(shifts);
    await _loadHistory();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Restored ${shifts.length} shifts')));
  }

  Future<void> _setBatterySafeMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_batterySafeModeKey, value);
    if (!mounted) return;
    setState(() => _batterySafeMode = value);

    final shift = _activeShift;
    if (shift != null) {
      await _positionSub?.cancel().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
      _locationStreamStoppedMode =
          _batterySafeMode && _stopDraft?.confirmed == true;
      _positionSub =
          Geolocator.getPositionStream(
            locationSettings: _locationSettings(),
          ).listen(
            _handlePosition,
            onError: (error) => _recordGpsError(error.toString()),
          );
      await _showTrackingNotification();
    }
  }

  Future<void> _setShiftRecoveryGraceMinutes(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_shiftRecoveryGraceMinutesKey, minutes);
    if (!mounted) return;
    setState(() => _shiftRecoveryGraceMinutes = minutes);
  }

  Future<void> _pickCalendarDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDay,
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 2),
    );
    if (picked == null) return;
    setState(() => _selectedDay = picked);
  }

  Future<void> _deleteShift(Shift shift) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete shift?'),
        content: Text(
          DateFormat('EEE, MMM d yyyy HH:mm').format(shift.startedAt),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xffdc2626),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.deleteShift(shift.id);
    await _loadHistory();
  }

  Future<void> _editTrip(Shift shift, RouteSegment segment) async {
    final restaurantController = TextEditingController(
      text: segment.pickupRestaurantName,
    );
    final earningsController = TextEditingController(
      text: segment.earnings == null
          ? ''
          : segment.earnings!.toStringAsFixed(2),
    );
    var platform = segment.platform;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Trip details'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: restaurantController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Pickup restaurant name',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<DeliveryPlatform>(
                initialValue: platform,
                decoration: const InputDecoration(labelText: 'Platform'),
                items: DeliveryPlatform.values
                    .map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text(item.label),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) setDialogState(() => platform = value);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: earningsController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Trip earnings'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;
    final earnings = double.tryParse(
      earningsController.text.trim().replaceAll(',', '.'),
    );
    setState(() {
      segment.pickupRestaurantName = restaurantController.text.trim();
      segment.platform = platform;
      segment.earnings = earnings;
    });
    await _store.save(shift);
    await _loadHistory();
  }

  Future<void> _editStopLabel(StopEvent stop) async {
    final restaurantController = TextEditingController(
      text: stop.restaurantName,
    );
    final placeController = TextEditingController(text: stop.placeName);
    final noteController = TextEditingController(text: stop.note);
    var type = stop.type;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Stop details'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<StopType>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Stop type'),
                items: StopType.values
                    .map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text(item.label),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) setDialogState(() => type = value);
                },
              ),
              TextField(
                controller: restaurantController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Restaurant or pickup name',
                ),
              ),
              TextField(
                controller: placeController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Place or area'),
              ),
              TextField(
                controller: noteController,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Note'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;
    setState(() {
      stop.type = type;
      stop.restaurantName = restaurantController.text.trim();
      stop.placeName = placeController.text.trim();
      stop.note = noteController.text.trim();
    });

    final active = _activeShift;
    if (active == null || !active.stops.contains(stop)) {
      for (final shift in _savedShifts) {
        if (shift.stops.contains(stop)) {
          await _store.save(shift);
          await _loadHistory();
          break;
        }
      }
    }
  }

  Future<void> _confirmTrip(Shift shift, RouteSegment segment) async {
    setState(() => segment.reviewed = true);
    await _store.save(shift);
    await _loadHistory();
  }

  Future<void> _confirmStop(Shift shift, StopEvent stop) async {
    setState(() => stop.reviewed = true);
    await _store.save(shift);
    await _loadHistory();
  }

  Future<void> _stopShift() async {
    if (_isStoppingShift) return;
    final shift = _activeShift;
    if (shift == null) return;

    final endedAt = DateTime.now();
    setState(() {
      _isStoppingShift = true;
      _stopDraft = null;
      _lastAutoSaveAt = null;
      _status = 'Saving shift...';
      _now = endedAt;
    });

    shift.endedAt = endedAt;
    shift.lastActivityAt = shift.endedAt!;
    shift.lifecycleEvents.add(
      DeliveryLifecycleEvent(
        stage: DeliveryLifecycleStage.shiftEnded,
        timestamp: shift.endedAt!,
      ),
    );
    for (final trip in shift.deliveryTrips.where(
      (trip) => trip.endedAt == null,
    )) {
      if (trip.allOrdersDelivered) {
        trip.endedAt = shift.endedAt;
      }
    }
    if (shift.segments.isNotEmpty && shift.segments.last.endedAt == null) {
      shift.segments.last.endedAt = shift.endedAt;
    }

    _clock?.cancel();
    _clock = null;
    _locationStreamStoppedMode = false;
    await _positionSub?.cancel().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    _positionSub = null;

    try {
      await _store.save(shift).timeout(const Duration(seconds: 30));
      await _clearActiveShiftMarker().timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _activeShift = shift;
        _isStoppingShift = false;
        _status = 'Could not save shift. Recovery copy kept.';
      });
      _logDiagnostic('Shift save failed', error.toString());
      _startRuntimeForRecoveredShift(shift);
      return;
    }

    if (!mounted) return;
    setState(() {
      _activeShift = null;
      _isStoppingShift = false;
      _savedShifts.removeWhere((item) => item.id == shift.id);
      _savedShifts.insert(0, shift);
      _status = shift.segments.isEmpty
          ? 'Shift saved without movement'
          : 'Shift saved';
    });
    unawaited(_cleanupStoppedShift());
  }

  Future<void> _cleanupStoppedShift() async {
    try {
      await _clearActiveShiftMarker().timeout(const Duration(seconds: 3));
      await _store.clearActive().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
      if (_notificationsReady) {
        await _notifications
            .cancel(_trackingNotificationId)
            .timeout(const Duration(seconds: 2), onTimeout: () {});
      }
      _logDiagnostic('Shift cleanup', 'Cleared stopped shift recovery state');
    } catch (error) {
      _logDiagnostic('Shift cleanup failed', error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final shift = _activeShift;
    return PopScope(
      canPop: !_isTracking,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final leave = await _confirmLeaveDuringShift();
        if (leave && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            [
              'Tracker',
              'Calendar',
              'Reports',
              'Earnings',
              'Settings',
            ][_tabIndex],
          ),
          surfaceTintColor: Colors.transparent,
        ),
        body: IndexedStack(
          index: _tabIndex,
          children: [
            _buildTrackerTab(shift),
            _buildCalendarTab(),
            _buildReportsTab(),
            _buildEarningsTab(),
            _buildSettingsTab(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tabIndex,
          onDestinationSelected: (index) => setState(() => _tabIndex = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.route_rounded),
              label: 'Tracker',
            ),
            NavigationDestination(
              icon: Icon(Icons.calendar_month_rounded),
              label: 'Calendar',
            ),
            NavigationDestination(
              icon: Icon(Icons.analytics_rounded),
              label: 'Reports',
            ),
            NavigationDestination(
              icon: Icon(Icons.payments_rounded),
              label: 'Earnings',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_rounded),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackerTab(Shift? shift) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      children: [
        _TrackerStatusHeader(
          status: _status,
          shift: shift,
          now: _now,
          isTracking: _isTracking,
          isStopping: _isStoppingShift,
          onStart: _startShift,
          onStop: _stopShift,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 260,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: RoutePreview(
              points: shift?.points ?? const [],
              lastKnownPoint: _lastKnownPoint,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _StatsGrid(shift: shift, now: _now),
        const SizedBox(height: 12),
        _LifecyclePanel(shift: shift, onStage: _recordLifecycleStage),
        const SizedBox(height: 18),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          leading: const Icon(Icons.timeline_rounded),
          title: Text(
            'Current shift timeline',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _Timeline(shift: shift, onEditStop: _editStopLabel),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCalendarTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _DayView(
          selectedDay: _selectedDay,
          shifts: _selectedDayShifts,
          lastKnownPoint: _lastKnownPoint,
          onPreviousDay: () => _changeSelectedDay(-1),
          onNextDay: () => _changeSelectedDay(1),
          onPickDate: _pickCalendarDate,
          onEditStop: _editStopLabel,
          onEditTrip: _editTrip,
          onConfirmTrip: _confirmTrip,
          onConfirmStop: _confirmStop,
          onDeleteShift: _deleteShift,
        ),
        const SizedBox(height: 22),
        Text(
          'All saved shifts',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (_savedShifts.isEmpty)
          const Text('No saved shifts yet.')
        else
          ..._savedShifts.map(
            (item) =>
                _HistoryTile(shift: item, onDelete: () => _deleteShift(item)),
          ),
      ],
    );
  }

  Widget _buildReportsTab() {
    final shifts = _selectedDayShifts;
    final points = shifts.expand((shift) => shift.points).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          children: [
            Text('Reports', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            IconButton(
              tooltip: 'Previous day',
              onPressed: () => _changeSelectedDay(-1),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            TextButton.icon(
              onPressed: _pickCalendarDate,
              icon: const Icon(Icons.event_rounded),
              label: Text(DateFormat('MMM d, yyyy').format(_selectedDay)),
            ),
            IconButton(
              tooltip: 'Next day',
              onPressed: () => _changeSelectedDay(1),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _PerformanceSummary(
          shifts: _selectedPerformanceShifts,
          period: _performancePeriod,
          periodStart: _performancePeriodStart,
          periodEnd: _performancePeriodEnd,
          onPeriodChanged: _changePerformancePeriod,
        ),
        const SizedBox(height: 12),
        _TimelinePlayback(shifts: shifts, lastKnownPoint: _lastKnownPoint),
        const SizedBox(height: 12),
        _RouteVerificationPanel(
          shifts: shifts,
          onEditTrip: _editTrip,
          onEditStop: _editStopLabel,
          onConfirmTrip: _confirmTrip,
          onConfirmStop: _confirmStop,
        ),
        const SizedBox(height: 12),
        _DayTimelineList(shifts: shifts, points: points),
        const SizedBox(height: 12),
        _ExportActionsPanel(
          hasShifts: shifts.isNotEmpty,
          onCopyCsv: _copySelectedDayCsv,
          onSaveCsv: _saveSelectedDayCsv,
          onSaveGpx: _saveSelectedDayGpx,
          onSaveKml: _saveSelectedDayKml,
          onExportJson: _exportJsonBackup,
        ),
      ],
    );
  }

  Widget _buildEarningsTab() {
    final shifts = _selectedDayShifts;
    final trips = shifts.expand((shift) => shift.segments).toList();
    final woltGross = trips
        .where((trip) => trip.platform == DeliveryPlatform.wolt)
        .fold<double>(0, (sum, trip) => sum + (trip.earnings ?? 0));
    final uberGross = trips
        .where((trip) => trip.platform == DeliveryPlatform.uberEats)
        .fold<double>(0, (sum, trip) => sum + (trip.earnings ?? 0));
    final uberNet = uberGross * (1 - DeliveryPlatform.uberEats.deductionRate);
    final totalNet = woltGross + uberNet;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          children: [
            Text(
              'Daily earnings',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Previous day',
              onPressed: () => _changeSelectedDay(-1),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            TextButton.icon(
              onPressed: _pickCalendarDate,
              icon: const Icon(Icons.event_rounded),
              label: Text(DateFormat('MMM d, yyyy').format(_selectedDay)),
            ),
            IconButton(
              tooltip: 'Next day',
              onPressed: () => _changeSelectedDay(1),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          childAspectRatio: 2.2,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            _StatCard(label: 'Total net', value: formatMoney(totalNet)),
            _StatCard(label: 'Trips', value: '${trips.length}'),
            _StatCard(label: 'Wolt total', value: formatMoney(woltGross)),
            _StatCard(label: 'Uber net', value: formatMoney(uberNet)),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('Uber Eats deduction'),
            subtitle: Text(
              'Gross ${formatMoney(uberGross)} x 74.5% = ${formatMoney(uberNet)}',
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (trips.isEmpty)
          const Text('No trips with earnings for this day yet.')
        else
          ...shifts.map(
            (shift) => _EarningsShiftCard(
              shift: shift,
              onEditTrip: (segment) => _editTrip(shift, segment),
            ),
          ),
      ],
    );
  }

  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        SwitchListTile(
          title: const Text('Dark mode'),
          subtitle: const Text(
            'Use a darker interface during delivery shifts.',
          ),
          value: widget.darkMode,
          onChanged: widget.onDarkModeChanged,
        ),
        SwitchListTile(
          title: const Text('Battery-safe tracking'),
          subtitle: const Text(
            'Uses high accuracy while moving and lower GPS frequency while stopped.',
          ),
          value: _batterySafeMode,
          onChanged: _setBatterySafeMode,
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.restore_page_rounded),
            title: const Text('Shift recovery grace period'),
            subtitle: Text(
              'Resume an accidentally closed active shift for $_shiftRecoveryGraceMinutes minutes.',
            ),
            trailing: DropdownButton<int>(
              value: _shiftRecoveryGraceMinutes,
              items: const [
                DropdownMenuItem(value: 30, child: Text('30m')),
                DropdownMenuItem(value: 60, child: Text('1h')),
                DropdownMenuItem(value: 120, child: Text('2h')),
                DropdownMenuItem(value: 240, child: Text('4h')),
              ],
              onChanged: (value) {
                if (value != null) _setShiftRecoveryGraceMinutes(value);
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        _PermissionPanel(
          permissions: _permissions,
          onRequestPermissions: _requestAppPermissions,
          onRequestOverlay: _requestOverlayPermission,
          onRefresh: _refreshPermissions,
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.health_and_safety_rounded),
            title: const Text('Run diagnosis'),
            subtitle: Text(
              _permissions.requiredGranted
                  ? 'Required permissions are ready.'
                  : 'Some required permissions need attention.',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _refreshPermissions,
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.folder_rounded),
            title: const Text('Local CSV storage'),
            subtitle: const Text(
              'CSV files are saved in the app documents folder without broad file access.',
            ),
            trailing: const Icon(Icons.save_alt_rounded),
            onTap: _saveSelectedDayCsv,
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.map_rounded),
            title: const Text('Export GPX route'),
            subtitle: const Text(
              'Saves the selected day for mapping and GIS tools.',
            ),
            trailing: const Icon(Icons.alt_route_rounded),
            onTap: _saveSelectedDayGpx,
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.public_rounded),
            title: const Text('Export KML route'),
            subtitle: const Text('Use with Google Earth and compatible maps.'),
            trailing: const Icon(Icons.travel_explore_rounded),
            onTap: _saveSelectedDayKml,
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.backup_rounded),
            title: const Text('Export JSON backup'),
            subtitle: const Text(
              'Saves full app data and copies the backup JSON to clipboard.',
            ),
            trailing: const Icon(Icons.ios_share_rounded),
            onTap: _exportJsonBackup,
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.restore_rounded),
            title: const Text('Restore JSON backup'),
            subtitle: const Text(
              'Paste or copy a backup JSON first, then restore from clipboard.',
            ),
            trailing: const Icon(Icons.content_paste_go_rounded),
            onTap: _restoreJsonBackupFromClipboard,
          ),
        ),
        const SizedBox(height: 12),
        _DiagnosticsPanel(
          lastGpsError: _lastGpsError,
          permissions: _permissions,
          notificationsReady: _notificationsReady,
          trackingActive: _isTracking,
          backgroundStoppedMode: _locationStreamStoppedMode,
          batterySafeMode: _batterySafeMode,
          diagnostics: _diagnostics,
        ),
      ],
    );
  }
}

class _PermissionPanel extends StatelessWidget {
  const _PermissionPanel({
    required this.permissions,
    required this.onRequestPermissions,
    required this.onRequestOverlay,
    required this.onRefresh,
  });

  final PermissionSnapshot permissions;
  final VoidCallback onRequestPermissions;
  final VoidCallback onRequestOverlay;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffe5e7eb)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Permissions',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Refresh permissions',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            _PermissionRow(
              label: 'Location services',
              granted: permissions.locationServices,
            ),
            _PermissionRow(
              label: 'Location permission',
              granted: permissions.locationGranted,
            ),
            _PermissionRow(
              label: 'Notification permission',
              granted: permissions.notificationGranted,
            ),
            _PermissionRow(
              label: 'Overlay permission',
              granted: permissions.overlayGranted,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onRequestPermissions,
                    icon: const Icon(Icons.security_rounded),
                    label: const Text('Enable required'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onRequestOverlay,
                    icon: const Icon(Icons.picture_in_picture_alt_rounded),
                    label: const Text('Overlay'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.label, required this.granted});

  final String label;
  final bool granted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            granted ? Icons.check_circle_rounded : Icons.error_rounded,
            color: granted ? const Color(0xff0f766e) : const Color(0xffdc2626),
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text(
            granted ? 'On' : 'Off',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
  }
}

class _DiagnosticsPanel extends StatelessWidget {
  const _DiagnosticsPanel({
    required this.lastGpsError,
    required this.permissions,
    required this.notificationsReady,
    required this.trackingActive,
    required this.backgroundStoppedMode,
    required this.batterySafeMode,
    required this.diagnostics,
  });

  final String lastGpsError;
  final PermissionSnapshot permissions;
  final bool notificationsReady;
  final bool trackingActive;
  final bool backgroundStoppedMode;
  final bool batterySafeMode;
  final List<DiagnosticEntry> diagnostics;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.bug_report_rounded),
        title: const Text('Diagnostics'),
        subtitle: Text(
          trackingActive
              ? 'Background tracking service is active'
              : 'Background tracking service is inactive',
        ),
        children: [
          _DiagnosticRow(label: 'Latest GPS error', value: lastGpsError),
          _DiagnosticRow(
            label: 'Location permission',
            value: permissions.locationGranted ? 'Granted' : 'Missing',
          ),
          _DiagnosticRow(
            label: 'Notification status',
            value: notificationsReady && permissions.notificationGranted
                ? 'Ready'
                : 'Needs attention',
          ),
          _DiagnosticRow(
            label: 'Service status',
            value: trackingActive
                ? (backgroundStoppedMode
                      ? 'Active, stopped mode'
                      : 'Active, moving mode')
                : 'Inactive',
          ),
          _DiagnosticRow(
            label: 'Battery-safe mode',
            value: batterySafeMode ? 'On' : 'Off',
          ),
          if (diagnostics.isEmpty)
            const ListTile(title: Text('No recent diagnostic events.'))
          else
            ...diagnostics.map(
              (entry) => ListTile(
                dense: true,
                leading: const Icon(Icons.notes_rounded),
                title: Text(entry.title),
                subtitle: Text(
                  '${DateFormat('HH:mm:ss').format(entry.timestamp)} - ${entry.message}',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(dense: true, title: Text(label), subtitle: Text(value));
  }
}

class _TrackerStatusHeader extends StatelessWidget {
  const _TrackerStatusHeader({
    required this.status,
    required this.shift,
    required this.now,
    required this.isTracking,
    required this.isStopping,
    required this.onStart,
    required this.onStop,
  });

  final String status;
  final Shift? shift;
  final DateTime now;
  final bool isTracking;
  final bool isStopping;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final current = shift?.currentStage?.stage.label ?? 'Not tracking';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isTracking
                      ? Icons.radio_button_checked_rounded
                      : Icons.trip_origin_rounded,
                  color: isTracking
                      ? const Color(0xff0f766e)
                      : Theme.of(context).disabledColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        status,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Text(
                  formatDuration(shift?.durationUntil(now) ?? Duration.zero),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (isStopping)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: null,
                  icon: const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  label: const Text('Saving shift...'),
                ),
              )
            else if (isTracking)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xffdc2626),
                  ),
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('End shift'),
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onStart,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Start shift'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.shift, required this.now});

  final Shift? shift;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      childAspectRatio: 2.2,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        _StatCard(
          label: 'Distance',
          value:
              '${((shift?.distanceMeters ?? 0) / 1000).toStringAsFixed(2)} km',
        ),
        _StatCard(
          label: 'Moving time',
          value: formatDuration(
            shift?.movingDurationUntil(now) ?? Duration.zero,
          ),
        ),
        _StatCard(
          label: 'Wait time',
          value: formatDuration(shift?.waitDuration ?? Duration.zero),
        ),
        _StatCard(label: 'Stops', value: '${shift?.stops.length ?? 0}'),
      ],
    );
  }
}

class _LifecyclePanel extends StatelessWidget {
  const _LifecyclePanel({required this.shift, required this.onStage});

  final Shift? shift;
  final ValueChanged<DeliveryLifecycleStage> onStage;

  @override
  Widget build(BuildContext context) {
    final current = shift?.currentStage?.stage;
    final trip = shift?.activeDeliveryTrip;
    final nextStages = _nextStages(current);
    final exceptionStages = [
      DeliveryLifecycleStage.multipleOrdersActive,
      DeliveryLifecycleStage.delayedAtRestaurant,
      DeliveryLifecycleStage.customerUnavailable,
      DeliveryLifecycleStage.orderCancelled,
      DeliveryLifecycleStage.shiftPaused,
    ];
    final history = (shift?.lifecycleEvents ?? const <DeliveryLifecycleEvent>[])
        .reversed
        .take(6)
        .toList()
        .reversed
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.delivery_dining_rounded),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Delivery workflow',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        current?.label ?? 'Start a shift to begin',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<DeliveryLifecycleStage>(
                  tooltip: 'More statuses',
                  enabled: shift != null,
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: onStage,
                  itemBuilder: (context) => exceptionStages
                      .map(
                        (stage) => PopupMenuItem(
                          value: stage,
                          child: ListTile(
                            dense: true,
                            leading: Icon(stage.icon),
                            title: Text(stage.label),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    Expanded(
                      child: _LifecycleFact(
                        label: 'Orders',
                        value: '${shift?.activeOrderCount ?? 0}',
                      ),
                    ),
                    Expanded(
                      child: _LifecycleFact(
                        label: 'Trip',
                        value: trip?.id.split('-').last ?? '-',
                      ),
                    ),
                    Expanded(
                      child: _LifecycleFact(
                        label: 'Started',
                        value: trip == null
                            ? '-'
                            : DateFormat('HH:mm').format(trip.startedAt),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('Next actions', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: nextStages.map((stage) {
                final selected = current == stage;
                return ActionChip(
                  avatar: Icon(stage.icon, size: 18),
                  label: Text(stage.label),
                  onPressed: shift == null ? null : () => onStage(stage),
                  backgroundColor: selected
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                );
              }).toList(),
            ),
            if (history.isNotEmpty) ...[
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Recent status history'),
                children: history
                    .map(
                      (event) => ListTile(
                        dense: true,
                        leading: Icon(event.stage.icon),
                        title: Text(event.stage.label),
                        trailing: Text(
                          DateFormat('HH:mm').format(event.timestamp),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<DeliveryLifecycleStage> _nextStages(DeliveryLifecycleStage? current) {
    return switch (current) {
      null => [
        DeliveryLifecycleStage.waitingForOrder,
        DeliveryLifecycleStage.orderAccepted,
      ],
      DeliveryLifecycleStage.shiftStarted ||
      DeliveryLifecycleStage.waitingForOrder => [
        DeliveryLifecycleStage.orderAccepted,
        DeliveryLifecycleStage.travelingToRestaurant,
      ],
      DeliveryLifecycleStage.orderAccepted => [
        DeliveryLifecycleStage.travelingToRestaurant,
        DeliveryLifecycleStage.atRestaurant,
      ],
      DeliveryLifecycleStage.travelingToRestaurant => [
        DeliveryLifecycleStage.atRestaurant,
        DeliveryLifecycleStage.orderPickedUp,
      ],
      DeliveryLifecycleStage.atRestaurant ||
      DeliveryLifecycleStage.delayedAtRestaurant => [
        DeliveryLifecycleStage.orderPickedUp,
        DeliveryLifecycleStage.travelingToCustomer,
      ],
      DeliveryLifecycleStage.orderPickedUp ||
      DeliveryLifecycleStage.multipleOrdersActive => [
        DeliveryLifecycleStage.travelingToCustomer,
        DeliveryLifecycleStage.orderAccepted,
      ],
      DeliveryLifecycleStage.travelingToCustomer ||
      DeliveryLifecycleStage.customerUnavailable => [
        DeliveryLifecycleStage.delivered,
        DeliveryLifecycleStage.orderAccepted,
      ],
      DeliveryLifecycleStage.delivered => [
        DeliveryLifecycleStage.waitingForOrder,
        DeliveryLifecycleStage.orderAccepted,
      ],
      DeliveryLifecycleStage.shiftPaused => [
        DeliveryLifecycleStage.waitingForOrder,
        DeliveryLifecycleStage.orderAccepted,
      ],
      DeliveryLifecycleStage.orderCancelled => [
        DeliveryLifecycleStage.waitingForOrder,
        DeliveryLifecycleStage.orderAccepted,
      ],
      DeliveryLifecycleStage.shiftEnded => [
        DeliveryLifecycleStage.shiftStarted,
      ],
    };
  }
}

class _LifecycleFact extends StatelessWidget {
  const _LifecycleFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(
          value,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffe5e7eb)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: const Color(0xff6b7280)),
            ),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _PerformanceSummary extends StatelessWidget {
  const _PerformanceSummary({
    required this.shifts,
    required this.period,
    required this.periodStart,
    required this.periodEnd,
    required this.onPeriodChanged,
  });

  final List<Shift> shifts;
  final PerformancePeriod period;
  final DateTime periodStart;
  final DateTime periodEnd;
  final ValueChanged<PerformancePeriod> onPeriodChanged;

  @override
  Widget build(BuildContext context) {
    final trips = shifts.expand((shift) => shift.segments).toList();
    final activity = ActivityMetrics.fromShifts(
      shifts,
      periodStart: periodStart,
      periodEnd: periodEnd,
    );
    final totalNet = shifts.fold<double>(
      0,
      (sum, shift) => sum + shift.netEarnings,
    );
    final hours = activity.totalShiftTime.inSeconds / 3600;
    final km = activity.totalDistanceMeters / 1000;
    final woltNet = trips
        .where((trip) => trip.platform == DeliveryPlatform.wolt)
        .fold<double>(0, (sum, trip) => sum + trip.netEarnings);
    final uberNet = trips
        .where((trip) => trip.platform == DeliveryPlatform.uberEats)
        .fold<double>(0, (sum, trip) => sum + trip.netEarnings);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.analytics_rounded),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Performance',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<PerformancePeriod>(
              segments: PerformancePeriod.values
                  .map(
                    (item) => ButtonSegment<PerformancePeriod>(
                      value: item,
                      label: Text(item.label),
                      icon: Icon(item.icon),
                    ),
                  )
                  .toList(),
              selected: {period},
              showSelectedIcon: false,
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) onPeriodChanged(selection.first);
              },
            ),
            const SizedBox(height: 8),
            Text(
              performancePeriodLabel(period, periodStart, periodEnd),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MiniMetric(
                  label: 'Shift time',
                  value: formatDuration(activity.totalShiftTime),
                ),
                _MiniMetric(
                  label: 'Active orders',
                  value: formatDuration(activity.activeDeliveryTime),
                ),
                _MiniMetric(
                  label: 'Waiting no order',
                  value: formatDuration(activity.waitingNoOrderTime),
                ),
                _MiniMetric(
                  label: 'Wait ratio',
                  value: '${activity.waitingPercentage.toStringAsFixed(0)}%',
                ),
                _MiniMetric(
                  label: 'Waiting km',
                  value:
                      '${(activity.waitingDistanceMeters / 1000).toStringAsFixed(2)} km',
                ),
                _MiniMetric(
                  label: 'Active km',
                  value:
                      '${(activity.activeDistanceMeters / 1000).toStringAsFixed(2)} km',
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 8,
                value: activity.activePercentage / 100,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${activity.activePercentage.toStringAsFixed(0)}% active / '
              '${activity.waitingPercentage.toStringAsFixed(0)}% waiting',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MiniMetric(
                  label: 'Distance',
                  value:
                      '${(activity.totalDistanceMeters / 1000).toStringAsFixed(2)} km',
                ),
                _MiniMetric(label: 'Net', value: formatMoney(totalNet)),
                _MiniMetric(
                  label: 'Per hour',
                  value: hours <= 0 ? '0.00' : formatMoney(totalNet / hours),
                ),
                _MiniMetric(
                  label: 'Per km',
                  value: km <= 0 ? '0.00' : formatMoney(totalNet / km),
                ),
                _MiniMetric(label: 'Wolt net', value: formatMoney(woltNet)),
                _MiniMetric(label: 'Uber net', value: formatMoney(uberNet)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 104,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RouteVerificationPanel extends StatelessWidget {
  const _RouteVerificationPanel({
    required this.shifts,
    required this.onEditTrip,
    required this.onEditStop,
    required this.onConfirmTrip,
    required this.onConfirmStop,
  });

  final List<Shift> shifts;
  final void Function(Shift shift, RouteSegment segment) onEditTrip;
  final ValueChanged<StopEvent> onEditStop;
  final void Function(Shift shift, RouteSegment segment) onConfirmTrip;
  final void Function(Shift shift, StopEvent stop) onConfirmStop;

  @override
  Widget build(BuildContext context) {
    final tripItems = <({Shift shift, RouteSegment segment, int index})>[];
    final stopItems = <({Shift shift, StopEvent stop, int index})>[];
    for (final shift in shifts) {
      for (var i = 0; i < shift.segments.length; i++) {
        if (!shift.segments[i].reviewed) {
          tripItems.add((
            shift: shift,
            segment: shift.segments[i],
            index: i + 1,
          ));
        }
      }
      for (var i = 0; i < shift.stops.length; i++) {
        if (!shift.stops[i].reviewed) {
          stopItems.add((shift: shift, stop: shift.stops[i], index: i + 1));
        }
      }
    }
    final total = tripItems.length + stopItems.length;
    return Card(
      child: ExpansionTile(
        leading: Icon(
          total == 0 ? Icons.verified_rounded : Icons.fact_check_rounded,
        ),
        title: const Text('Route verification'),
        subtitle: Text(
          total == 0
              ? 'All detected trips and stops are reviewed'
              : '$total items need review',
        ),
        children: [
          if (total == 0)
            const ListTile(title: Text('Nothing to confirm for this day.'))
          else ...[
            ...tripItems.map(
              (item) => ListTile(
                leading: const Icon(Icons.route_rounded),
                title: Text('Trip ${item.index}'),
                subtitle: Text(item.segment.tripSummary),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    IconButton(
                      tooltip: 'Edit trip',
                      icon: const Icon(Icons.edit_note_rounded),
                      onPressed: () => onEditTrip(item.shift, item.segment),
                    ),
                    IconButton(
                      tooltip: 'Confirm trip',
                      icon: const Icon(Icons.check_circle_outline_rounded),
                      onPressed: () => onConfirmTrip(item.shift, item.segment),
                    ),
                  ],
                ),
              ),
            ),
            ...stopItems.map(
              (item) => ListTile(
                leading: Icon(item.stop.type.icon),
                title: Text('Stop ${item.index}: ${item.stop.displayName}'),
                subtitle: Text(
                  '${item.stop.type.label} - ${formatDuration(item.stop.duration)}',
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    IconButton(
                      tooltip: 'Edit stop',
                      icon: const Icon(Icons.edit_location_alt_rounded),
                      onPressed: () => onEditStop(item.stop),
                    ),
                    IconButton(
                      tooltip: 'Confirm stop',
                      icon: const Icon(Icons.check_circle_outline_rounded),
                      onPressed: () => onConfirmStop(item.shift, item.stop),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExportActionsPanel extends StatelessWidget {
  const _ExportActionsPanel({
    required this.hasShifts,
    required this.onCopyCsv,
    required this.onSaveCsv,
    required this.onSaveGpx,
    required this.onSaveKml,
    required this.onExportJson,
  });

  final bool hasShifts;
  final VoidCallback onCopyCsv;
  final VoidCallback onSaveCsv;
  final VoidCallback onSaveGpx;
  final VoidCallback onSaveKml;
  final VoidCallback onExportJson;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.ios_share_rounded),
        title: const Text('Export selected data'),
        subtitle: const Text('CSV, GPX, KML, and full JSON backup'),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: hasShifts ? onCopyCsv : null,
                icon: const Icon(Icons.copy_all_rounded),
                label: const Text('Copy CSV'),
              ),
              OutlinedButton.icon(
                onPressed: hasShifts ? onSaveCsv : null,
                icon: const Icon(Icons.save_alt_rounded),
                label: const Text('Save CSV'),
              ),
              OutlinedButton.icon(
                onPressed: hasShifts ? onSaveGpx : null,
                icon: const Icon(Icons.alt_route_rounded),
                label: const Text('GPX'),
              ),
              OutlinedButton.icon(
                onPressed: hasShifts ? onSaveKml : null,
                icon: const Icon(Icons.travel_explore_rounded),
                label: const Text('KML'),
              ),
              OutlinedButton.icon(
                onPressed: onExportJson,
                icon: const Icon(Icons.backup_rounded),
                label: const Text('JSON backup'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TimelinePlayback extends StatefulWidget {
  const _TimelinePlayback({required this.shifts, required this.lastKnownPoint});

  final List<Shift> shifts;
  final TrackPoint? lastKnownPoint;

  @override
  State<_TimelinePlayback> createState() => _TimelinePlaybackState();
}

class _TimelinePlaybackState extends State<_TimelinePlayback> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final points = widget.shifts.expand((shift) => shift.points).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (points.isEmpty) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.play_circle_outline_rounded),
          title: Text('Timeline playback'),
          subtitle: Text('No tracked points to replay for this day.'),
        ),
      );
    }
    _index = _index.clamp(0, points.length - 1);
    final selected = points[_index];
    final visible = points
        .take(_index + 1)
        .map((point) => LatLng(point.latitude, point.longitude))
        .toList();
    final status = pointStatus(selected, widget.shifts);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.play_circle_outline_rounded),
                const SizedBox(width: 8),
                Text(
                  'Timeline playback',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                Text(
                  '${_index + 1}/${points.length}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 220,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: FlutterMap(
                  key: ValueKey(
                    'playback-${selected.timestamp.toIso8601String()}',
                  ),
                  options: MapOptions(
                    initialCenter: LatLng(
                      selected.latitude,
                      selected.longitude,
                    ),
                    initialZoom: visible.length > 1 ? 14 : 13,
                    interactionOptions: const InteractionOptions(
                      flags:
                          InteractiveFlag.drag |
                          InteractiveFlag.pinchZoom |
                          InteractiveFlag.doubleTapZoom,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.mitesh.delivery_route_tracker',
                    ),
                    if (visible.length > 1)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: visible,
                            color: const Color(0xff0f766e),
                            strokeWidth: 4,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: LatLng(selected.latitude, selected.longitude),
                          width: 44,
                          height: 44,
                          child: GestureDetector(
                            onTap: () =>
                                _showPointDetails(context, selected, status),
                            child: const Icon(
                              Icons.location_on_rounded,
                              color: Color(0xffdc2626),
                              size: 38,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Slider(
              min: 0,
              max: (points.length - 1).toDouble(),
              divisions: points.length > 1 ? points.length - 1 : null,
              value: _index.toDouble(),
              onChanged: (value) => setState(() => _index = value.round()),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.pin_drop_rounded),
              title: Text(DateFormat('HH:mm:ss').format(selected.timestamp)),
              subtitle: Text(
                '$status - ${(selected.speedMetersPerSecond * 3.6).toStringAsFixed(1)} km/h - ${selected.accuracy.toStringAsFixed(0)}m accuracy',
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPointDetails(
    BuildContext context,
    TrackPoint point,
    String status,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.pin_drop_rounded),
          title: Text(DateFormat('MMM d, HH:mm:ss').format(point.timestamp)),
          subtitle: Text(
            '$status\n${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}\nSpeed ${(point.speedMetersPerSecond * 3.6).toStringAsFixed(1)} km/h - accuracy ${point.accuracy.toStringAsFixed(0)}m',
          ),
          isThreeLine: true,
        ),
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.shift, required this.onEditStop});

  final Shift? shift;
  final ValueChanged<StopEvent> onEditStop;

  @override
  Widget build(BuildContext context) {
    if (shift == null) {
      return const Text('Start a shift to see segments and stops.');
    }
    final entries = shift!.timelineEntries;
    if (entries.isEmpty) return const Text('Waiting for GPS points...');

    return Column(
      children: entries.map((entry) {
        return Card(
          color: Theme.of(context).colorScheme.surface,
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Icon(
              entry.isStop ? Icons.pause_circle : Icons.route,
              color: entry.isStop ? Colors.amber[800] : const Color(0xff0f766e),
            ),
            title: Text(entry.title),
            subtitle: Text(entry.subtitle),
            trailing: entry.stop == null
                ? null
                : IconButton(
                    tooltip: 'Edit stop',
                    icon: const Icon(Icons.edit_location_alt_rounded),
                    onPressed: () => onEditStop(entry.stop!),
                  ),
          ),
        );
      }).toList(),
    );
  }
}

class _DayView extends StatelessWidget {
  const _DayView({
    required this.selectedDay,
    required this.shifts,
    required this.lastKnownPoint,
    required this.onPreviousDay,
    required this.onNextDay,
    required this.onPickDate,
    required this.onEditStop,
    required this.onEditTrip,
    required this.onConfirmTrip,
    required this.onConfirmStop,
    required this.onDeleteShift,
  });

  final DateTime selectedDay;
  final List<Shift> shifts;
  final TrackPoint? lastKnownPoint;
  final VoidCallback onPreviousDay;
  final VoidCallback onNextDay;
  final VoidCallback onPickDate;
  final ValueChanged<StopEvent> onEditStop;
  final void Function(Shift shift, RouteSegment segment) onEditTrip;
  final void Function(Shift shift, RouteSegment segment) onConfirmTrip;
  final void Function(Shift shift, StopEvent stop) onConfirmStop;
  final ValueChanged<Shift> onDeleteShift;

  @override
  Widget build(BuildContext context) {
    final totalDistance = shifts.fold<double>(
      0,
      (sum, shift) => sum + shift.distanceMeters,
    );
    final totalWait = shifts.fold<Duration>(
      Duration.zero,
      (sum, shift) => sum + shift.waitDuration,
    );
    final totalDuration = shifts.fold<Duration>(
      Duration.zero,
      (sum, shift) => sum + shift.movingDuration,
    );
    final totalStops = shifts.fold<int>(
      0,
      (sum, shift) => sum + shift.stops.length,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Day routes', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            IconButton(
              tooltip: 'Previous day',
              onPressed: onPreviousDay,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            TextButton.icon(
              onPressed: onPickDate,
              icon: const Icon(Icons.event_rounded),
              label: Text(DateFormat('MMM d, yyyy').format(selectedDay)),
            ),
            IconButton(
              tooltip: 'Next day',
              onPressed: onNextDay,
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          childAspectRatio: 2.2,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            _StatCard(
              label: 'Day distance',
              value: '${(totalDistance / 1000).toStringAsFixed(2)} km',
            ),
            _StatCard(
              label: 'Day moving',
              value: formatDuration(totalDuration),
            ),
            _StatCard(label: 'Day wait', value: formatDuration(totalWait)),
            _StatCard(label: 'Day stops', value: '$totalStops'),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 320,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: DayTimelineMap(
              shifts: shifts,
              lastKnownPoint: lastKnownPoint,
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (shifts.isEmpty)
          const Text('No routes saved for this day.')
        else
          ...shifts.map(
            (shift) => _DayShiftCard(
              shift: shift,
              onEditStop: onEditStop,
              onEditTrip: (segment) => onEditTrip(shift, segment),
              onConfirmTrip: (segment) => onConfirmTrip(shift, segment),
              onConfirmStop: (stop) => onConfirmStop(shift, stop),
              onDelete: () => onDeleteShift(shift),
            ),
          ),
      ],
    );
  }
}

class _DayShiftCard extends StatelessWidget {
  const _DayShiftCard({
    required this.shift,
    required this.onEditStop,
    required this.onEditTrip,
    required this.onConfirmTrip,
    required this.onConfirmStop,
    required this.onDelete,
  });

  final Shift shift;
  final ValueChanged<StopEvent> onEditStop;
  final ValueChanged<RouteSegment> onEditTrip;
  final ValueChanged<RouteSegment> onConfirmTrip;
  final ValueChanged<StopEvent> onConfirmStop;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: const Icon(Icons.route_rounded, color: Color(0xff0f766e)),
        title: Text(DateFormat('HH:mm').format(shift.startedAt)),
        subtitle: Text(
          '${(shift.distanceMeters / 1000).toStringAsFixed(2)} km - ${formatDuration(shift.movingDuration)} moving - ${shift.stops.length} stops',
        ),
        trailing: IconButton(
          tooltip: 'Delete shift',
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: onDelete,
        ),
        children: [
          ...shift.segments.indexed.map((entry) {
            final index = entry.$1 + 1;
            final segment = entry.$2;
            return ListTile(
              leading: const Icon(Icons.local_shipping_rounded),
              title: Text('Trip $index'),
              subtitle: Text(
                '${segment.reviewed ? 'Reviewed' : 'Needs review'} - ${segment.tripSummary}',
              ),
              trailing: Wrap(
                spacing: 4,
                children: [
                  IconButton(
                    tooltip: 'Confirm trip',
                    icon: Icon(
                      segment.reviewed
                          ? Icons.verified_rounded
                          : Icons.check_circle_outline_rounded,
                    ),
                    onPressed: segment.reviewed
                        ? null
                        : () => onConfirmTrip(segment),
                  ),
                  IconButton(
                    tooltip: 'Edit trip',
                    icon: const Icon(Icons.edit_note_rounded),
                    onPressed: () => onEditTrip(segment),
                  ),
                ],
              ),
            );
          }),
          if (shift.stops.isEmpty)
            const ListTile(title: Text('No stop details yet.'))
          else
            ...shift.stops.map(
              (stop) => ListTile(
                leading: const Icon(Icons.storefront_rounded),
                title: Text(stop.displayName),
                subtitle: Text(
                  '${stop.reviewed ? 'Reviewed' : 'Needs review'} - ${formatDuration(stop.duration)} wait - ${stop.placeLabel}',
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    IconButton(
                      tooltip: 'Confirm stop',
                      icon: Icon(
                        stop.reviewed
                            ? Icons.verified_rounded
                            : Icons.check_circle_outline_rounded,
                      ),
                      onPressed: stop.reviewed
                          ? null
                          : () => onConfirmStop(stop),
                    ),
                    IconButton(
                      tooltip: 'Edit stop',
                      icon: const Icon(Icons.edit_location_alt_rounded),
                      onPressed: () => onEditStop(stop),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.shift, required this.onDelete});

  final Shift shift;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('MMM d, HH:mm').format(shift.startedAt);
    return Card(
      color: Theme.of(context).colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.history_rounded),
        title: Text(date),
        subtitle: Text(
          '${(shift.distanceMeters / 1000).toStringAsFixed(2)} km - ${formatDuration(shift.movingDuration)} moving - ${shift.stops.length} stops',
        ),
        trailing: IconButton(
          tooltip: 'Delete shift',
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: onDelete,
        ),
      ),
    );
  }
}

class _EarningsShiftCard extends StatelessWidget {
  const _EarningsShiftCard({required this.shift, required this.onEditTrip});

  final Shift shift;
  final ValueChanged<RouteSegment> onEditTrip;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: const Icon(Icons.receipt_long_rounded),
        title: Text(DateFormat('HH:mm').format(shift.startedAt)),
        subtitle: Text(
          '${formatMoney(shift.netEarnings)} net - ${shift.segments.length} trips',
        ),
        children: [
          ...shift.segments.indexed.map((entry) {
            final index = entry.$1 + 1;
            final segment = entry.$2;
            return ListTile(
              leading: Icon(segment.platform.icon),
              title: Text(
                segment.pickupRestaurantName.isEmpty
                    ? 'Trip $index'
                    : segment.pickupRestaurantName,
              ),
              subtitle: Text(
                '${segment.platform.label} - gross ${formatMoney(segment.earnings ?? 0)} - net ${formatMoney(segment.netEarnings)}',
              ),
              trailing: IconButton(
                tooltip: 'Edit trip earnings',
                icon: const Icon(Icons.edit_note_rounded),
                onPressed: () => onEditTrip(segment),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class RoutePreview extends StatefulWidget {
  const RoutePreview({
    super.key,
    required this.points,
    required this.lastKnownPoint,
  });

  final List<TrackPoint> points;
  final TrackPoint? lastKnownPoint;

  @override
  State<RoutePreview> createState() => _RoutePreviewState();
}

class _RoutePreviewState extends State<RoutePreview> {
  final MapController _controller = MapController();
  double _zoom = 15;

  @override
  Widget build(BuildContext context) {
    final centerPoint = widget.points.isNotEmpty
        ? widget.points.last
        : widget.lastKnownPoint;
    final center = centerPoint == null
        ? const LatLng(61.4978, 23.7610)
        : LatLng(centerPoint.latitude, centerPoint.longitude);
    final route = widget.points
        .map((point) => LatLng(point.latitude, point.longitude))
        .toList();
    _zoom = route.length > 1 ? _zoom : 13;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          FlutterMap(
            mapController: _controller,
            key: ValueKey(
              '${center.latitude},${center.longitude},${widget.points.length}',
            ),
            options: MapOptions(
              initialCenter: center,
              initialZoom: route.length > 1 ? 15 : 13,
              interactionOptions: const InteractionOptions(
                flags:
                    InteractiveFlag.drag |
                    InteractiveFlag.pinchZoom |
                    InteractiveFlag.doubleTapZoom,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.mitesh.delivery_route_tracker',
              ),
              if (route.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: route,
                      color: const Color(0xff0f766e),
                      strokeWidth: 5,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (route.isNotEmpty)
                    Marker(
                      point: route.first,
                      width: 32,
                      height: 32,
                      child: const Icon(
                        Icons.trip_origin_rounded,
                        color: Color(0xff16a34a),
                        size: 28,
                      ),
                    ),
                  if (centerPoint != null)
                    Marker(
                      point: center,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.my_location_rounded,
                        color: Color(0xffdc2626),
                        size: 32,
                      ),
                    ),
                ],
              ),
              if (centerPoint == null)
                const Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.all(10),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(
                          'Start a shift to center the map on your location',
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Column(
              children: [
                _MapButton(
                  icon: Icons.add_rounded,
                  tooltip: 'Zoom in',
                  onPressed: () {
                    _zoom += 1;
                    _controller.move(center, _zoom);
                  },
                ),
                _MapButton(
                  icon: Icons.remove_rounded,
                  tooltip: 'Zoom out',
                  onPressed: () {
                    _zoom -= 1;
                    _controller.move(center, _zoom);
                  },
                ),
                _MapButton(
                  icon: Icons.my_location_rounded,
                  tooltip: 'Recenter',
                  onPressed: () => _controller.move(center, _zoom),
                ),
                _MapButton(
                  icon: Icons.fullscreen_rounded,
                  tooltip: 'Fullscreen',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => _FullscreenRouteMap(
                        points: widget.points,
                        lastKnownPoint: widget.lastKnownPoint,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: IconButton(
          tooltip: tooltip,
          icon: Icon(icon),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

class _FullscreenRouteMap extends StatelessWidget {
  const _FullscreenRouteMap({
    required this.points,
    required this.lastKnownPoint,
  });

  final List<TrackPoint> points;
  final TrackPoint? lastKnownPoint;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trip map')),
      body: RoutePreview(points: points, lastKnownPoint: lastKnownPoint),
    );
  }
}

class DayTimelineMap extends StatelessWidget {
  const DayTimelineMap({
    super.key,
    required this.shifts,
    required this.lastKnownPoint,
  });

  final List<Shift> shifts;
  final TrackPoint? lastKnownPoint;

  @override
  Widget build(BuildContext context) {
    final points = shifts.expand((shift) => shift.points).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final stops = shifts.expand((shift) => shift.stops).toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final centerPoint = points.isNotEmpty ? points.last : lastKnownPoint;
    final center = centerPoint == null
        ? const LatLng(61.4978, 23.7610)
        : LatLng(centerPoint.latitude, centerPoint.longitude);
    final route = points
        .map((point) => LatLng(point.latitude, point.longitude))
        .toList();

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: FlutterMap(
        key: ValueKey(
          'day-${points.length}-${center.latitude}-${center.longitude}',
        ),
        options: MapOptions(
          initialCenter: center,
          initialZoom: route.length > 1 ? 13 : 12,
          interactionOptions: const InteractionOptions(
            flags:
                InteractiveFlag.drag |
                InteractiveFlag.pinchZoom |
                InteractiveFlag.doubleTapZoom,
          ),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.mitesh.delivery_route_tracker',
          ),
          if (route.length > 1)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: route,
                  color: const Color(0xff0f766e),
                  strokeWidth: 5,
                ),
              ],
            ),
          MarkerLayer(
            markers: [
              if (route.isNotEmpty)
                Marker(
                  point: route.first,
                  width: 34,
                  height: 34,
                  child: const Icon(
                    Icons.flag_circle_rounded,
                    color: Color(0xff16a34a),
                    size: 30,
                  ),
                ),
              ...stops.map(
                (stop) => Marker(
                  point: LatLng(stop.latitude, stop.longitude),
                  width: 34,
                  height: 34,
                  child: Icon(
                    stop.type.mapIcon,
                    color: stop.type.mapColor,
                    size: 30,
                  ),
                ),
              ),
              if (route.isNotEmpty)
                Marker(
                  point: route.last,
                  width: 38,
                  height: 38,
                  child: const Icon(
                    Icons.location_on_rounded,
                    color: Color(0xffdc2626),
                    size: 34,
                  ),
                ),
            ],
          ),
          if (route.isEmpty)
            const Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.all(10),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text('No tracked points for this day yet'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DayTimelineList extends StatelessWidget {
  const _DayTimelineList({required this.shifts, required this.points});

  final List<Shift> shifts;
  final List<TrackPoint> points;

  @override
  Widget build(BuildContext context) {
    final entries = <DayTimelineEntry>[];
    for (final shift in shifts) {
      for (var i = 0; i < shift.segments.length; i++) {
        final trip = shift.segments[i];
        entries.add(
          DayTimelineEntry(
            at: trip.startedAt,
            icon: Icons.route_rounded,
            title: 'Trip ${i + 1}',
            subtitle:
                '${(trip.distanceMeters / 1000).toStringAsFixed(2)} km - ${formatDuration(trip.duration)}',
          ),
        );
      }
      for (final stop in shift.stops) {
        entries.add(
          DayTimelineEntry(
            at: stop.startedAt,
            icon: stop.type.icon,
            title: '${stop.type.label}: ${stop.displayName}',
            subtitle:
                '${formatDuration(stop.duration)} wait - ${stop.placeLabel}',
          ),
        );
      }
    }
    entries.sort((a, b) => a.at.compareTo(b.at));

    return Card(
      color: Theme.of(context).colorScheme.surface,
      child: ExpansionTile(
        leading: const Icon(Icons.timeline_rounded),
        title: const Text('Timeline'),
        subtitle: Text('${points.length} tracked GPS points'),
        children: [
          if (entries.isEmpty)
            const ListTile(title: Text('No trips or stops detected yet.'))
          else
            ...entries.map(
              (entry) => ListTile(
                leading: Icon(entry.icon),
                title: Text(entry.title),
                subtitle: Text(
                  '${DateFormat('HH:mm').format(entry.at)} - ${entry.subtitle}',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class Shift {
  Shift({
    required this.id,
    required this.startedAt,
    this.endedAt,
    List<TrackPoint>? points,
    List<RouteSegment>? segments,
    List<StopEvent>? stops,
    List<DeliveryLifecycleEvent>? lifecycleEvents,
    List<DeliveryTrip>? deliveryTrips,
    DateTime? lastActivityAt,
    this.tripClosureGraceMinutes = 10,
  }) : points = points ?? [],
       segments = segments ?? [],
       stops = stops ?? [],
       lifecycleEvents = lifecycleEvents ?? [],
       deliveryTrips = deliveryTrips ?? [],
       lastActivityAt = lastActivityAt ?? endedAt ?? startedAt;

  final String id;
  final DateTime startedAt;
  DateTime? endedAt;
  final List<TrackPoint> points;
  final List<RouteSegment> segments;
  final List<StopEvent> stops;
  final List<DeliveryLifecycleEvent> lifecycleEvents;
  final List<DeliveryTrip> deliveryTrips;
  DateTime lastActivityAt;
  int tripClosureGraceMinutes;

  double get distanceMeters =>
      segments.fold(0, (total, segment) => total + segment.distanceMeters);
  double get grossEarnings =>
      segments.fold(0, (total, segment) => total + (segment.earnings ?? 0));
  double get netEarnings =>
      segments.fold(0, (total, segment) => total + segment.netEarnings);
  Duration get duration => durationUntil(endedAt ?? DateTime.now());
  Duration get movingDuration => movingDurationUntil(endedAt ?? DateTime.now());
  Duration get waitDuration =>
      stops.fold(Duration.zero, (total, stop) => total + stop.duration);
  DeliveryLifecycleEvent? get currentStage =>
      lifecycleEvents.isEmpty ? null : lifecycleEvents.last;
  DeliveryTrip? get activeDeliveryTrip {
    for (final trip in deliveryTrips.reversed) {
      if (trip.endedAt == null) return trip;
    }
    return null;
  }

  int get activeOrderCount => activeDeliveryTrip?.activeOrderCount ?? 0;

  DeliveryTrip ensureActiveDeliveryTrip(DateTime now) {
    final existing = activeDeliveryTrip;
    if (existing != null) return existing;
    final trip = DeliveryTrip(
      id: 'trip-${now.millisecondsSinceEpoch}',
      startedAt: now,
    );
    deliveryTrips.add(trip);
    return trip;
  }

  Duration durationUntil(DateTime time) => time.difference(startedAt);

  Duration movingDurationUntil(DateTime time) {
    return segments.fold(Duration.zero, (total, segment) {
      final end = segment.endedAt ?? time;
      if (end.isBefore(segment.startedAt)) return total;
      return total + end.difference(segment.startedAt);
    });
  }

  List<TimelineEntry> get timelineEntries {
    final entries = <TimelineEntry>[];
    var segmentIndex = 1;
    var stopIndex = 1;
    for (final segment in segments) {
      entries.add(
        TimelineEntry(
          isStop: false,
          title: 'Route $segmentIndex',
          subtitle:
              '${(segment.distanceMeters / 1000).toStringAsFixed(2)} km - ${formatDuration(segment.duration)} moving',
          at: segment.startedAt,
        ),
      );
      segmentIndex++;
    }
    for (final stop in stops) {
      entries.add(
        TimelineEntry(
          isStop: true,
          title: stop.displayName == 'Unlabeled stop'
              ? 'Stop $stopIndex'
              : stop.displayName,
          subtitle:
              '${formatDuration(stop.duration)} wait - ${stop.placeLabel}',
          at: stop.startedAt,
          stop: stop,
        ),
      );
      stopIndex++;
    }
    for (final event in lifecycleEvents) {
      entries.add(
        TimelineEntry(
          isStop: false,
          title: event.stage.label,
          subtitle: 'Delivery status updated',
          at: event.timestamp,
        ),
      );
    }
    entries.sort((a, b) => a.at.compareTo(b.at));
    return entries;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
    'points': points.map((p) => p.toJson()).toList(),
    'segments': segments.map((s) => s.toJson()).toList(),
    'stops': stops.map((s) => s.toJson()).toList(),
    'lifecycleEvents': lifecycleEvents.map((e) => e.toJson()).toList(),
    'deliveryTrips': deliveryTrips.map((t) => t.toJson()).toList(),
    'lastActivityAt': lastActivityAt.toIso8601String(),
    'tripClosureGraceMinutes': tripClosureGraceMinutes,
  };

  static Shift fromJson(Map<String, dynamic> json) => Shift(
    id: json['id'] as String,
    startedAt: DateTime.parse(json['startedAt'] as String),
    endedAt: json['endedAt'] == null
        ? null
        : DateTime.parse(json['endedAt'] as String),
    points: (json['points'] as List? ?? [])
        .map((p) => TrackPoint.fromJson(p as Map<String, dynamic>))
        .toList(),
    segments: (json['segments'] as List? ?? [])
        .map((s) => RouteSegment.fromJson(s as Map<String, dynamic>))
        .toList(),
    stops: (json['stops'] as List? ?? [])
        .map((s) => StopEvent.fromJson(s as Map<String, dynamic>))
        .toList(),
    lifecycleEvents: (json['lifecycleEvents'] as List? ?? [])
        .map((e) => DeliveryLifecycleEvent.fromJson(e as Map<String, dynamic>))
        .toList(),
    deliveryTrips: (json['deliveryTrips'] as List? ?? [])
        .map((t) => DeliveryTrip.fromJson(t as Map<String, dynamic>))
        .toList(),
    lastActivityAt: json['lastActivityAt'] == null
        ? null
        : DateTime.parse(json['lastActivityAt'] as String),
    tripClosureGraceMinutes:
        (json['tripClosureGraceMinutes'] as num?)?.toInt() ?? 10,
  );
}

extension ShiftRangeX on Shift {
  bool overlapsRange(DateTime start, DateTime end) {
    final shiftEnd = endedAt ?? DateTime.now();
    return startedAt.isBefore(end) && shiftEnd.isAfter(start);
  }
}

class DeliveryTrip {
  DeliveryTrip({
    required this.id,
    required this.startedAt,
    this.endedAt,
    this.eligibleForClosureAt,
    List<DeliveryOrder>? orders,
  }) : orders = orders ?? [];

  final String id;
  final DateTime startedAt;
  DateTime? endedAt;
  DateTime? eligibleForClosureAt;
  final List<DeliveryOrder> orders;

  int get activeOrderCount => orders
      .where(
        (order) =>
            order.pickedUpAt != null &&
            order.deliveredAt == null &&
            order.cancelledAt == null,
      )
      .length;
  bool get allOrdersDelivered =>
      orders.isNotEmpty &&
      orders.every(
        (order) =>
            order.status == DeliveryOrderStatus.delivered ||
            order.status == DeliveryOrderStatus.cancelled,
      );
  DeliveryOrder? get latestOpenOrder {
    for (final order in orders.reversed) {
      if (order.status != DeliveryOrderStatus.delivered &&
          order.status != DeliveryOrderStatus.cancelled) {
        return order;
      }
    }
    return null;
  }

  DeliveryOrder? get latestUndeliveredOrder {
    for (final order in orders.reversed) {
      if (order.status == DeliveryOrderStatus.pickedUp ||
          order.status == DeliveryOrderStatus.accepted) {
        return order;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
    'eligibleForClosureAt': eligibleForClosureAt?.toIso8601String(),
    'orders': orders.map((order) => order.toJson()).toList(),
  };

  static DeliveryTrip fromJson(Map<String, dynamic> json) => DeliveryTrip(
    id: json['id'] as String,
    startedAt: DateTime.parse(json['startedAt'] as String),
    endedAt: json['endedAt'] == null
        ? null
        : DateTime.parse(json['endedAt'] as String),
    eligibleForClosureAt: json['eligibleForClosureAt'] == null
        ? null
        : DateTime.parse(json['eligibleForClosureAt'] as String),
    orders: (json['orders'] as List? ?? [])
        .map((o) => DeliveryOrder.fromJson(o as Map<String, dynamic>))
        .toList(),
  );
}

class DeliveryOrder {
  DeliveryOrder({
    required this.id,
    required this.acceptedAt,
    this.status = DeliveryOrderStatus.accepted,
    this.pickedUpAt,
    this.deliveredAt,
    this.cancelledAt,
  });

  final String id;
  final DateTime acceptedAt;
  DeliveryOrderStatus status;
  DateTime? pickedUpAt;
  DateTime? deliveredAt;
  DateTime? cancelledAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'acceptedAt': acceptedAt.toIso8601String(),
    'status': status.name,
    'pickedUpAt': pickedUpAt?.toIso8601String(),
    'deliveredAt': deliveredAt?.toIso8601String(),
    'cancelledAt': cancelledAt?.toIso8601String(),
  };

  static DeliveryOrder fromJson(Map<String, dynamic> json) => DeliveryOrder(
    id: json['id'] as String,
    acceptedAt: DateTime.parse(json['acceptedAt'] as String),
    status:
        DeliveryOrderStatusX.fromName(json['status'] as String?) ??
        DeliveryOrderStatus.accepted,
    pickedUpAt: json['pickedUpAt'] == null
        ? null
        : DateTime.parse(json['pickedUpAt'] as String),
    deliveredAt: json['deliveredAt'] == null
        ? null
        : DateTime.parse(json['deliveredAt'] as String),
    cancelledAt: json['cancelledAt'] == null
        ? null
        : DateTime.parse(json['cancelledAt'] as String),
  );
}

enum DeliveryOrderStatus { accepted, pickedUp, delivered, cancelled }

extension DeliveryOrderStatusX on DeliveryOrderStatus {
  String get label => switch (this) {
    DeliveryOrderStatus.accepted => 'Accepted',
    DeliveryOrderStatus.pickedUp => 'Picked up',
    DeliveryOrderStatus.delivered => 'Delivered',
    DeliveryOrderStatus.cancelled => 'Cancelled',
  };

  static DeliveryOrderStatus? fromName(String? name) {
    if (name == null) return null;
    for (final status in DeliveryOrderStatus.values) {
      if (status.name == name) return status;
    }
    return null;
  }
}

class DeliveryLifecycleEvent {
  DeliveryLifecycleEvent({required this.stage, required this.timestamp});

  final DeliveryLifecycleStage stage;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => {
    'stage': stage.name,
    'timestamp': timestamp.toIso8601String(),
  };

  static DeliveryLifecycleEvent fromJson(Map<String, dynamic> json) =>
      DeliveryLifecycleEvent(
        stage:
            DeliveryLifecycleStageX.fromName(json['stage'] as String?) ??
            DeliveryLifecycleStage.waitingForOrder,
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}

enum DeliveryLifecycleStage {
  shiftStarted,
  shiftPaused,
  shiftEnded,
  waitingForOrder,
  orderAccepted,
  travelingToRestaurant,
  atRestaurant,
  orderPickedUp,
  travelingToCustomer,
  delivered,
  multipleOrdersActive,
  delayedAtRestaurant,
  customerUnavailable,
  orderCancelled,
}

extension DeliveryLifecycleStageX on DeliveryLifecycleStage {
  bool get startsActiveOrderWindow => switch (this) {
    DeliveryLifecycleStage.orderAccepted ||
    DeliveryLifecycleStage.travelingToRestaurant ||
    DeliveryLifecycleStage.atRestaurant ||
    DeliveryLifecycleStage.orderPickedUp ||
    DeliveryLifecycleStage.travelingToCustomer ||
    DeliveryLifecycleStage.multipleOrdersActive ||
    DeliveryLifecycleStage.delayedAtRestaurant ||
    DeliveryLifecycleStage.customerUnavailable => true,
    DeliveryLifecycleStage.shiftStarted ||
    DeliveryLifecycleStage.shiftPaused ||
    DeliveryLifecycleStage.shiftEnded ||
    DeliveryLifecycleStage.waitingForOrder ||
    DeliveryLifecycleStage.delivered ||
    DeliveryLifecycleStage.orderCancelled => false,
  };

  bool get endsActiveOrderWindow => switch (this) {
    DeliveryLifecycleStage.delivered ||
    DeliveryLifecycleStage.orderCancelled ||
    DeliveryLifecycleStage.waitingForOrder ||
    DeliveryLifecycleStage.shiftPaused ||
    DeliveryLifecycleStage.shiftEnded => true,
    DeliveryLifecycleStage.shiftStarted ||
    DeliveryLifecycleStage.orderAccepted ||
    DeliveryLifecycleStage.travelingToRestaurant ||
    DeliveryLifecycleStage.atRestaurant ||
    DeliveryLifecycleStage.orderPickedUp ||
    DeliveryLifecycleStage.travelingToCustomer ||
    DeliveryLifecycleStage.multipleOrdersActive ||
    DeliveryLifecycleStage.delayedAtRestaurant ||
    DeliveryLifecycleStage.customerUnavailable => false,
  };

  String get label => switch (this) {
    DeliveryLifecycleStage.shiftStarted => 'Shift started',
    DeliveryLifecycleStage.shiftPaused => 'Shift paused',
    DeliveryLifecycleStage.shiftEnded => 'Shift ended',
    DeliveryLifecycleStage.waitingForOrder => 'Waiting for order',
    DeliveryLifecycleStage.orderAccepted => 'Order accepted',
    DeliveryLifecycleStage.travelingToRestaurant => 'Traveling to restaurant',
    DeliveryLifecycleStage.atRestaurant => 'At restaurant',
    DeliveryLifecycleStage.orderPickedUp => 'Order picked up',
    DeliveryLifecycleStage.travelingToCustomer => 'Traveling to customer',
    DeliveryLifecycleStage.delivered => 'Delivered',
    DeliveryLifecycleStage.multipleOrdersActive => 'Multiple orders',
    DeliveryLifecycleStage.delayedAtRestaurant => 'Delayed at restaurant',
    DeliveryLifecycleStage.customerUnavailable => 'Customer unavailable',
    DeliveryLifecycleStage.orderCancelled => 'Order cancelled',
  };

  String get statusText => switch (this) {
    DeliveryLifecycleStage.shiftStarted => 'Shift started',
    DeliveryLifecycleStage.shiftPaused => 'Shift paused',
    DeliveryLifecycleStage.shiftEnded => 'Shift ended',
    DeliveryLifecycleStage.waitingForOrder => 'Waiting for order',
    DeliveryLifecycleStage.orderAccepted => 'Order accepted',
    DeliveryLifecycleStage.travelingToRestaurant => 'Traveling to restaurant',
    DeliveryLifecycleStage.atRestaurant => 'At restaurant - waiting for pickup',
    DeliveryLifecycleStage.orderPickedUp => 'Picked up - heading to customer',
    DeliveryLifecycleStage.travelingToCustomer => 'Traveling to customer',
    DeliveryLifecycleStage.delivered => 'Delivered',
    DeliveryLifecycleStage.multipleOrdersActive => 'Multiple orders active',
    DeliveryLifecycleStage.delayedAtRestaurant => 'Delayed at restaurant',
    DeliveryLifecycleStage.customerUnavailable => 'Customer unavailable',
    DeliveryLifecycleStage.orderCancelled => 'Order cancelled',
  };

  IconData get icon => switch (this) {
    DeliveryLifecycleStage.shiftStarted => Icons.play_arrow_rounded,
    DeliveryLifecycleStage.shiftPaused => Icons.pause_rounded,
    DeliveryLifecycleStage.shiftEnded => Icons.stop_rounded,
    DeliveryLifecycleStage.waitingForOrder => Icons.hourglass_bottom_rounded,
    DeliveryLifecycleStage.orderAccepted => Icons.check_circle_outline_rounded,
    DeliveryLifecycleStage.travelingToRestaurant =>
      Icons.directions_bike_rounded,
    DeliveryLifecycleStage.atRestaurant => Icons.restaurant_rounded,
    DeliveryLifecycleStage.orderPickedUp => Icons.shopping_bag_rounded,
    DeliveryLifecycleStage.travelingToCustomer => Icons.delivery_dining_rounded,
    DeliveryLifecycleStage.delivered => Icons.task_alt_rounded,
    DeliveryLifecycleStage.multipleOrdersActive =>
      Icons.library_add_check_rounded,
    DeliveryLifecycleStage.delayedAtRestaurant => Icons.schedule_rounded,
    DeliveryLifecycleStage.customerUnavailable => Icons.person_off_rounded,
    DeliveryLifecycleStage.orderCancelled => Icons.cancel_rounded,
  };

  static DeliveryLifecycleStage? fromName(String? name) {
    if (name == null) return null;
    if (name == 'accepted') return DeliveryLifecycleStage.orderAccepted;
    if (name == 'pickedUp') return DeliveryLifecycleStage.orderPickedUp;
    for (final stage in DeliveryLifecycleStage.values) {
      if (stage.name == name) return stage;
    }
    return null;
  }
}

class RouteSegment {
  RouteSegment({
    required this.startedAt,
    this.endedAt,
    this.pickupRestaurantName = '',
    this.platform = DeliveryPlatform.wolt,
    this.earnings,
    this.reviewed = false,
    List<TrackPoint>? points,
  }) : points = points ?? [];

  final DateTime startedAt;
  DateTime? endedAt;
  String pickupRestaurantName;
  DeliveryPlatform platform;
  double? earnings;
  bool reviewed;
  final List<TrackPoint> points;

  Duration get duration => (endedAt ?? DateTime.now()).difference(startedAt);
  double get netEarnings => (earnings ?? 0) * (1 - platform.deductionRate);

  String get tripSummary {
    final restaurant = pickupRestaurantName.isEmpty
        ? 'No restaurant'
        : pickupRestaurantName;
    return '$restaurant - ${platform.label} - ${formatMoney(earnings ?? 0)} gross';
  }

  double get distanceMeters {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += haversineMeters(points[i - 1], points[i]);
    }
    return total;
  }

  Map<String, dynamic> toJson() => {
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
    'pickupRestaurantName': pickupRestaurantName,
    'platform': platform.name,
    'earnings': earnings,
    'reviewed': reviewed,
    'points': points.map((p) => p.toJson()).toList(),
  };

  static RouteSegment fromJson(Map<String, dynamic> json) => RouteSegment(
    startedAt: DateTime.parse(json['startedAt'] as String),
    endedAt: json['endedAt'] == null
        ? null
        : DateTime.parse(json['endedAt'] as String),
    pickupRestaurantName: json['pickupRestaurantName'] as String? ?? '',
    platform: DeliveryPlatformX.fromName(json['platform'] as String?),
    earnings: (json['earnings'] as num?)?.toDouble(),
    reviewed: json['reviewed'] as bool? ?? false,
    points: (json['points'] as List? ?? [])
        .map((p) => TrackPoint.fromJson(p as Map<String, dynamic>))
        .toList(),
  );
}

enum DeliveryPlatform { wolt, uberEats }

extension DeliveryPlatformX on DeliveryPlatform {
  String get label => switch (this) {
    DeliveryPlatform.wolt => 'Wolt',
    DeliveryPlatform.uberEats => 'Uber Eats',
  };

  double get deductionRate => switch (this) {
    DeliveryPlatform.wolt => 0,
    DeliveryPlatform.uberEats => 0.255,
  };

  IconData get icon => switch (this) {
    DeliveryPlatform.wolt => Icons.delivery_dining_rounded,
    DeliveryPlatform.uberEats => Icons.two_wheeler_rounded,
  };

  static DeliveryPlatform fromName(String? name) {
    return DeliveryPlatform.values.firstWhere(
      (item) => item.name == name,
      orElse: () => DeliveryPlatform.wolt,
    );
  }
}

class StopEvent {
  StopEvent({
    required this.latitude,
    required this.longitude,
    required this.startedAt,
    required this.endedAt,
    this.restaurantName = '',
    this.placeName = '',
    this.note = '',
    this.type = StopType.other,
    this.reviewed = false,
  });

  final double latitude;
  final double longitude;
  final DateTime startedAt;
  DateTime endedAt;
  String restaurantName;
  String placeName;
  String note;
  StopType type;
  bool reviewed;

  Duration get duration => endedAt.difference(startedAt);

  String get displayName {
    if (restaurantName.trim().isNotEmpty) return restaurantName.trim();
    if (placeName.trim().isNotEmpty) return placeName.trim();
    return type == StopType.other ? 'Unlabeled stop' : type.label;
  }

  String get placeLabel {
    if (placeName.trim().isNotEmpty) return placeName.trim();
    return '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
  }

  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'restaurantName': restaurantName,
    'placeName': placeName,
    'note': note,
    'type': type.name,
    'reviewed': reviewed,
  };

  static StopEvent fromJson(Map<String, dynamic> json) => StopEvent(
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
    startedAt: DateTime.parse(json['startedAt'] as String),
    endedAt: DateTime.parse(json['endedAt'] as String),
    restaurantName: json['restaurantName'] as String? ?? '',
    placeName: json['placeName'] as String? ?? '',
    note: json['note'] as String? ?? '',
    type: StopTypeX.fromName(json['type'] as String?) ?? StopType.other,
    reviewed: json['reviewed'] as bool? ?? false,
  );
}

enum StopType { restaurant, customer, breakTime, waitingForOrder, other }

extension StopTypeX on StopType {
  String get label => switch (this) {
    StopType.restaurant => 'Restaurant',
    StopType.customer => 'Customer',
    StopType.breakTime => 'Break',
    StopType.waitingForOrder => 'Waiting for order',
    StopType.other => 'Other',
  };

  IconData get icon => switch (this) {
    StopType.restaurant => Icons.restaurant_rounded,
    StopType.customer => Icons.person_pin_circle_rounded,
    StopType.breakTime => Icons.free_breakfast_rounded,
    StopType.waitingForOrder => Icons.hourglass_bottom_rounded,
    StopType.other => Icons.more_horiz_rounded,
  };

  IconData get mapIcon => switch (this) {
    StopType.restaurant => Icons.restaurant_rounded,
    StopType.customer => Icons.location_on_rounded,
    StopType.breakTime => Icons.pause_circle_filled_rounded,
    StopType.waitingForOrder => Icons.hourglass_bottom_rounded,
    StopType.other => Icons.pause_circle_filled_rounded,
  };

  Color get mapColor => switch (this) {
    StopType.restaurant => const Color(0xff2563eb),
    StopType.customer => const Color(0xff7c3aed),
    StopType.breakTime => const Color(0xfff59e0b),
    StopType.waitingForOrder => const Color(0xffeab308),
    StopType.other => const Color(0xff6366f1),
  };

  static StopType? fromName(String? name) {
    if (name == null) return null;
    for (final type in StopType.values) {
      if (type.name == name) return type;
    }
    return null;
  }
}

class TrackPoint {
  TrackPoint({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.accuracy,
    required this.speedMetersPerSecond,
  });

  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double accuracy;
  final double speedMetersPerSecond;

  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'timestamp': timestamp.toIso8601String(),
    'accuracy': accuracy,
    'speedMetersPerSecond': speedMetersPerSecond,
  };

  static TrackPoint fromJson(Map<String, dynamic> json) => TrackPoint(
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
    timestamp: DateTime.parse(json['timestamp'] as String),
    accuracy: (json['accuracy'] as num).toDouble(),
    speedMetersPerSecond: (json['speedMetersPerSecond'] as num).toDouble(),
  );
}

class StopDraft {
  StopDraft({required this.anchor, required this.startedAt});

  final TrackPoint anchor;
  final DateTime startedAt;
  bool confirmed = false;
}

class TimelineEntry {
  TimelineEntry({
    required this.isStop,
    required this.title,
    required this.subtitle,
    required this.at,
    this.stop,
  });

  final bool isStop;
  final String title;
  final String subtitle;
  final DateTime at;
  final StopEvent? stop;
}

class DayTimelineEntry {
  DayTimelineEntry({
    required this.at,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final DateTime at;
  final IconData icon;
  final String title;
  final String subtitle;
}

enum PerformancePeriod { day, week, month }

extension PerformancePeriodX on PerformancePeriod {
  String get label => switch (this) {
    PerformancePeriod.day => 'Day',
    PerformancePeriod.week => 'Week',
    PerformancePeriod.month => 'Month',
  };

  IconData get icon => switch (this) {
    PerformancePeriod.day => Icons.today_rounded,
    PerformancePeriod.week => Icons.view_week_rounded,
    PerformancePeriod.month => Icons.calendar_month_rounded,
  };
}

class TimeWindow {
  const TimeWindow({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  bool get isValid => end.isAfter(start);

  bool contains(DateTime time) => !time.isBefore(start) && time.isBefore(end);

  bool overlaps(TimeWindow other) =>
      start.isBefore(other.end) && end.isAfter(other.start);

  Duration overlapDuration(TimeWindow other) {
    final overlapStart = start.isAfter(other.start) ? start : other.start;
    final overlapEnd = end.isBefore(other.end) ? end : other.end;
    if (!overlapEnd.isAfter(overlapStart)) return Duration.zero;
    return overlapEnd.difference(overlapStart);
  }

  TimeWindow? clippedTo(TimeWindow other) {
    final clippedStart = start.isAfter(other.start) ? start : other.start;
    final clippedEnd = end.isBefore(other.end) ? end : other.end;
    if (!clippedEnd.isAfter(clippedStart)) return null;
    return TimeWindow(start: clippedStart, end: clippedEnd);
  }
}

class ActivityMetrics {
  const ActivityMetrics({
    required this.totalShiftTime,
    required this.activeDeliveryTime,
    required this.waitingNoOrderTime,
    required this.activeDistanceMeters,
    required this.waitingDistanceMeters,
  });

  final Duration totalShiftTime;
  final Duration activeDeliveryTime;
  final Duration waitingNoOrderTime;
  final double activeDistanceMeters;
  final double waitingDistanceMeters;

  double get totalDistanceMeters =>
      activeDistanceMeters + waitingDistanceMeters;

  double get activePercentage {
    if (totalShiftTime.inSeconds <= 0) return 0;
    return activeDeliveryTime.inSeconds / totalShiftTime.inSeconds * 100;
  }

  double get waitingPercentage {
    if (totalShiftTime.inSeconds <= 0) return 0;
    return waitingNoOrderTime.inSeconds / totalShiftTime.inSeconds * 100;
  }

  static ActivityMetrics fromShifts(
    List<Shift> shifts, {
    required DateTime periodStart,
    required DateTime periodEnd,
  }) {
    final period = TimeWindow(start: periodStart, end: periodEnd);
    var totalShiftTime = Duration.zero;
    var activeDeliveryTime = Duration.zero;
    var activeDistanceMeters = 0.0;
    var waitingDistanceMeters = 0.0;

    for (final shift in shifts) {
      final shiftEnd = shift.endedAt ?? DateTime.now();
      final shiftWindow = TimeWindow(start: shift.startedAt, end: shiftEnd);
      final clippedShift = shiftWindow.clippedTo(period);
      if (clippedShift == null) continue;

      totalShiftTime += clippedShift.end.difference(clippedShift.start);
      final activeWindows = activeOrderWindowsForShift(
        shift,
        shiftEnd,
      ).map((window) => window.clippedTo(clippedShift)).nonNulls.toList();
      final mergedActiveWindows = mergeTimeWindows(activeWindows);
      for (final window in mergedActiveWindows) {
        activeDeliveryTime += window.end.difference(window.start);
      }

      final points =
          shift.points
              .where(
                (point) =>
                    !point.timestamp.isBefore(period.start) &&
                    !point.timestamp.isAfter(period.end),
              )
              .toList()
            ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      for (var i = 1; i < points.length; i++) {
        final previous = points[i - 1];
        final current = points[i];
        final segmentDistance = haversineMeters(previous, current);
        if (segmentDistance <= 0) continue;
        final midpointMillis =
            (previous.timestamp.millisecondsSinceEpoch +
                current.timestamp.millisecondsSinceEpoch) ~/
            2;
        final midpoint = DateTime.fromMillisecondsSinceEpoch(midpointMillis);
        final isActive = mergedActiveWindows.any(
          (window) => window.contains(midpoint),
        );
        if (isActive) {
          activeDistanceMeters += segmentDistance;
        } else {
          waitingDistanceMeters += segmentDistance;
        }
      }
    }

    final waitingNoOrderTime = totalShiftTime - activeDeliveryTime;
    return ActivityMetrics(
      totalShiftTime: totalShiftTime,
      activeDeliveryTime: activeDeliveryTime,
      waitingNoOrderTime: waitingNoOrderTime.isNegative
          ? Duration.zero
          : waitingNoOrderTime,
      activeDistanceMeters: activeDistanceMeters,
      waitingDistanceMeters: waitingDistanceMeters,
    );
  }
}

List<TimeWindow> activeOrderWindowsForShift(Shift shift, DateTime fallbackEnd) {
  final orderWindows = <TimeWindow>[];
  for (final trip in shift.deliveryTrips) {
    final tripEnd = trip.endedAt ?? shift.endedAt ?? fallbackEnd;
    for (final order in trip.orders) {
      final end = order.deliveredAt ?? order.cancelledAt ?? tripEnd;
      final window = TimeWindow(start: order.acceptedAt, end: end);
      if (window.isValid) orderWindows.add(window);
    }
  }
  if (orderWindows.isNotEmpty) return mergeTimeWindows(orderWindows);

  final lifecycleWindows = <TimeWindow>[];
  DateTime? activeStartedAt;
  final events = [...shift.lifecycleEvents]
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  for (final event in events) {
    if (event.stage.startsActiveOrderWindow) {
      activeStartedAt ??= event.timestamp;
    }
    if (event.stage.endsActiveOrderWindow && activeStartedAt != null) {
      final window = TimeWindow(start: activeStartedAt, end: event.timestamp);
      if (window.isValid) lifecycleWindows.add(window);
      activeStartedAt = null;
    }
  }
  if (activeStartedAt != null) {
    final window = TimeWindow(start: activeStartedAt, end: fallbackEnd);
    if (window.isValid) lifecycleWindows.add(window);
  }
  return mergeTimeWindows(lifecycleWindows);
}

List<TimeWindow> mergeTimeWindows(List<TimeWindow> windows) {
  if (windows.isEmpty) return const [];
  final sorted = [...windows]..sort((a, b) => a.start.compareTo(b.start));
  final merged = <TimeWindow>[sorted.first];
  for (final window in sorted.skip(1)) {
    final previous = merged.last;
    if (!window.start.isAfter(previous.end)) {
      merged[merged.length - 1] = TimeWindow(
        start: previous.start,
        end: window.end.isAfter(previous.end) ? window.end : previous.end,
      );
    } else {
      merged.add(window);
    }
  }
  return merged;
}

class DiagnosticEntry {
  DiagnosticEntry({
    required this.title,
    required this.message,
    required this.timestamp,
  });

  final String title;
  final String message;
  final DateTime timestamp;
}

class PermissionSnapshot {
  const PermissionSnapshot({
    this.locationServices = false,
    this.location = LocationPermission.unableToDetermine,
    this.notificationGranted = false,
    this.overlayGranted = false,
  });

  final bool locationServices;
  final LocationPermission location;
  final bool notificationGranted;
  final bool overlayGranted;

  bool get locationGranted {
    return location == LocationPermission.always ||
        location == LocationPermission.whileInUse;
  }

  bool get requiredGranted =>
      locationServices && locationGranted && notificationGranted;
}

class ShiftStore {
  static const _key = 'saved_shifts';
  static const _historyFilename = 'delivery_shifts.json';
  static const _activeFilename = 'active_shift.json';

  Future<File> get _historyFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_historyFilename');
  }

  Future<File> get _activeFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_activeFilename');
  }

  Future<List<Shift>> load() async {
    final file = await _historyFile;
    var raw = '';
    if (await file.exists()) {
      raw = await file.readAsString();
    } else {
      final prefs = await SharedPreferences.getInstance();
      raw = prefs.getString(_key) ?? '';
    }
    if (raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      final shifts = decoded
          .map((item) => Shift.fromJson(item as Map<String, dynamic>))
          .toList();
      shifts.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      return shifts;
    } catch (_) {
      return [];
    }
  }

  Future<void> save(Shift shift) async {
    final shifts = await load();
    shifts.removeWhere((item) => item.id == shift.id);
    shifts.insert(0, shift);
    await _writeHistory(shifts);
  }

  Future<void> deleteShift(String id) async {
    final shifts = await load();
    shifts.removeWhere((item) => item.id == id);
    await _writeHistory(shifts);
  }

  Future<void> replaceAll(List<Shift> shifts) async {
    shifts.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    await _writeHistory(shifts);
  }

  Future<void> saveActive(Shift shift) async {
    final file = await _activeFile;
    await file.writeAsString(jsonEncode(shift.toJson()));
  }

  Future<Shift?> loadActive() async {
    try {
      final file = await _activeFile;
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      return Shift.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearActive() async {
    final file = await _activeFile;
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _writeHistory(List<Shift> shifts) async {
    final file = await _historyFile;
    await file.writeAsString(
      jsonEncode(shifts.map((item) => item.toJson()).toList()),
    );
  }
}

double haversineMeters(TrackPoint a, TrackPoint b) {
  const earthRadius = 6371000.0;
  final lat1 = a.latitude * pi / 180;
  final lat2 = b.latitude * pi / 180;
  final dLat = (b.latitude - a.latitude) * pi / 180;
  final dLng = (b.longitude - a.longitude) * pi / 180;
  final h =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
  return earthRadius * 2 * atan2(sqrt(h), sqrt(1 - h));
}

String formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
}

String formatMoney(double value) {
  return value.toStringAsFixed(2);
}

bool isSameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

DateTime performancePeriodStart(
  DateTime selectedDay,
  PerformancePeriod period,
) {
  final dayStart = DateTime(
    selectedDay.year,
    selectedDay.month,
    selectedDay.day,
  );
  return switch (period) {
    PerformancePeriod.day => dayStart,
    PerformancePeriod.week => dayStart.subtract(
      Duration(days: dayStart.weekday - DateTime.monday),
    ),
    PerformancePeriod.month => DateTime(selectedDay.year, selectedDay.month),
  };
}

DateTime performancePeriodEnd(DateTime selectedDay, PerformancePeriod period) {
  final start = performancePeriodStart(selectedDay, period);
  return switch (period) {
    PerformancePeriod.day => start.add(const Duration(days: 1)),
    PerformancePeriod.week => start.add(const Duration(days: 7)),
    PerformancePeriod.month => DateTime(start.year, start.month + 1),
  };
}

String performancePeriodLabel(
  PerformancePeriod period,
  DateTime start,
  DateTime end,
) {
  return switch (period) {
    PerformancePeriod.day => DateFormat('MMM d, yyyy').format(start),
    PerformancePeriod.week =>
      '${DateFormat('MMM d').format(start)} - ${DateFormat('MMM d, yyyy').format(end.subtract(const Duration(days: 1)))}',
    PerformancePeriod.month => DateFormat('MMMM yyyy').format(start),
  };
}

String pointStatus(TrackPoint point, List<Shift> shifts) {
  for (final shift in shifts) {
    for (var i = 0; i < shift.stops.length; i++) {
      final stop = shift.stops[i];
      if (!point.timestamp.isBefore(stop.startedAt) &&
          !point.timestamp.isAfter(stop.endedAt)) {
        return '${stop.type.label} stop ${i + 1}';
      }
    }
    for (var i = 0; i < shift.segments.length; i++) {
      final segment = shift.segments[i];
      final endedAt = segment.endedAt ?? shift.endedAt ?? DateTime.now();
      if (!point.timestamp.isBefore(segment.startedAt) &&
          !point.timestamp.isAfter(endedAt)) {
        return 'Trip ${i + 1} - ${segment.platform.label}';
      }
    }
  }
  return 'Tracked point';
}

String shiftsToCsv(List<Shift> shifts) {
  final rows = <List<String>>[
    [
      'shift_id',
      'event_type',
      'started_at',
      'ended_at',
      'duration_seconds',
      'distance_meters',
      'latitude',
      'longitude',
      'restaurant_name',
      'platform',
      'gross_earnings',
      'net_earnings',
      'place_name',
      'note',
      'stop_type',
      'lifecycle_stage',
      'reviewed',
    ],
  ];

  for (final shift in shifts) {
    for (var i = 0; i < shift.points.length; i++) {
      final point = shift.points[i];
      rows.add([
        shift.id,
        'gps_point_${i + 1}',
        point.timestamp.toIso8601String(),
        '',
        '',
        '',
        point.latitude.toStringAsFixed(6),
        point.longitude.toStringAsFixed(6),
        '',
        '',
        '',
        '',
        '',
        'accuracy=${point.accuracy.toStringAsFixed(1)} speed=${point.speedMetersPerSecond.toStringAsFixed(2)}',
        '',
        '',
        '',
      ]);
    }

    for (var i = 0; i < shift.segments.length; i++) {
      final segment = shift.segments[i];
      rows.add([
        shift.id,
        'route_${i + 1}',
        segment.startedAt.toIso8601String(),
        segment.endedAt?.toIso8601String() ?? '',
        segment.duration.inSeconds.toString(),
        segment.distanceMeters.toStringAsFixed(1),
        '',
        '',
        segment.pickupRestaurantName,
        segment.platform.label,
        (segment.earnings ?? 0).toStringAsFixed(2),
        segment.netEarnings.toStringAsFixed(3),
        '',
        '',
        '',
        '',
        segment.reviewed ? 'true' : 'false',
      ]);
    }

    for (var i = 0; i < shift.stops.length; i++) {
      final stop = shift.stops[i];
      rows.add([
        shift.id,
        'stop_${i + 1}',
        stop.startedAt.toIso8601String(),
        stop.endedAt.toIso8601String(),
        stop.duration.inSeconds.toString(),
        '',
        stop.latitude.toStringAsFixed(6),
        stop.longitude.toStringAsFixed(6),
        stop.restaurantName,
        '',
        '',
        '',
        stop.placeName,
        stop.note,
        stop.type.label,
        '',
        stop.reviewed ? 'true' : 'false',
      ]);
    }

    for (final event in shift.lifecycleEvents) {
      rows.add([
        shift.id,
        'lifecycle',
        event.timestamp.toIso8601String(),
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        event.stage.label,
        '',
      ]);
    }
  }

  return rows.map((row) => row.map(escapeCsv).join(',')).join('\n');
}

String shiftsToBackupJson(List<Shift> shifts) {
  return const JsonEncoder.withIndent('  ').convert({
    'schemaVersion': 2,
    'exportedAt': DateTime.now().toIso8601String(),
    'shifts': shifts.map((shift) => shift.toJson()).toList(),
  });
}

String shiftsToGpx(List<Shift> shifts) {
  final buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<gpx version="1.1" creator="Delivery Tracker" xmlns="http://www.topografix.com/GPX/1/1">',
    );
  for (final shift in shifts) {
    buffer
      ..writeln('  <trk>')
      ..writeln(
        '    <name>Shift ${escapeXml(DateFormat('yyyy-MM-dd HH:mm').format(shift.startedAt))}</name>',
      )
      ..writeln('    <trkseg>');
    final points = [...shift.points]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    for (final point in points) {
      buffer
        ..writeln(
          '      <trkpt lat="${point.latitude.toStringAsFixed(7)}" lon="${point.longitude.toStringAsFixed(7)}">',
        )
        ..writeln(
          '        <time>${point.timestamp.toUtc().toIso8601String()}</time>',
        )
        ..writeln(
          '        <extensions><accuracy>${point.accuracy.toStringAsFixed(1)}</accuracy><speed>${point.speedMetersPerSecond.toStringAsFixed(2)}</speed></extensions>',
        )
        ..writeln('      </trkpt>');
    }
    buffer
      ..writeln('    </trkseg>')
      ..writeln('  </trk>');
    for (final stop in shift.stops) {
      buffer
        ..writeln(
          '  <wpt lat="${stop.latitude.toStringAsFixed(7)}" lon="${stop.longitude.toStringAsFixed(7)}">',
        )
        ..writeln('    <name>${escapeXml(stop.type.label)} stop</name>')
        ..writeln(
          '    <desc>${escapeXml(stop.displayName)} - ${escapeXml(formatDuration(stop.duration))}</desc>',
        )
        ..writeln('  </wpt>');
    }
  }
  buffer.writeln('</gpx>');
  return buffer.toString();
}

String shiftsToKml(List<Shift> shifts) {
  final buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<kml xmlns="http://www.opengis.net/kml/2.2">')
    ..writeln('  <Document>')
    ..writeln('    <name>Delivery routes</name>');
  for (final shift in shifts) {
    final points = [...shift.points]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (points.isNotEmpty) {
      buffer
        ..writeln('    <Placemark>')
        ..writeln(
          '      <name>Shift ${escapeXml(DateFormat('yyyy-MM-dd HH:mm').format(shift.startedAt))}</name>',
        )
        ..writeln('      <LineString>')
        ..writeln('        <tessellate>1</tessellate>')
        ..writeln('        <coordinates>');
      for (final point in points) {
        buffer.writeln(
          '          ${point.longitude.toStringAsFixed(7)},${point.latitude.toStringAsFixed(7)},0',
        );
      }
      buffer
        ..writeln('        </coordinates>')
        ..writeln('      </LineString>')
        ..writeln('    </Placemark>');
    }
    for (final stop in shift.stops) {
      buffer
        ..writeln('    <Placemark>')
        ..writeln('      <name>${escapeXml(stop.type.label)} stop</name>')
        ..writeln(
          '      <description>${escapeXml(stop.displayName)} - ${escapeXml(formatDuration(stop.duration))}</description>',
        )
        ..writeln(
          '      <Point><coordinates>${stop.longitude.toStringAsFixed(7)},${stop.latitude.toStringAsFixed(7)},0</coordinates></Point>',
        )
        ..writeln('    </Placemark>');
    }
  }
  buffer
    ..writeln('  </Document>')
    ..writeln('</kml>');
  return buffer.toString();
}

List<Shift> shiftsFromBackupJson(String raw) {
  final decoded = jsonDecode(raw);
  final items = decoded is List
      ? decoded
      : (decoded as Map<String, dynamic>)['shifts'] as List? ?? [];
  final shifts = items
      .map((item) => Shift.fromJson(item as Map<String, dynamic>))
      .toList();
  shifts.sort((a, b) => b.startedAt.compareTo(a.startedAt));
  return shifts;
}

String escapeCsv(String value) {
  final needsQuotes =
      value.contains(',') || value.contains('"') || value.contains('\n');
  final escaped = value.replaceAll('"', '""');
  return needsQuotes ? '"$escaped"' : escaped;
}

String escapeXml(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
