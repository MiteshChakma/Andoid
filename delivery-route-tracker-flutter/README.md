# Delivery Route Tracker

Android-first Flutter app for food delivery drivers who want to track shifts, routes, order activity, waiting time, distance, earnings, and exportable local history.

This project was built with help from an AI coding agent in Codex. The app idea, workflow, and requirements came from a real delivery tracking use case; Codex helped implement, debug, document, and package the Flutter Android project.

## Current Status

The app is a functional prototype, not a Play Store-ready product. It has been tested on a real Android phone during development, but privacy hardening, native Android service resilience, app signing/release management, and route logic test coverage still need improvement before public release.

The latest source may be newer than the APK in `releases/` when unreleased changes are being reviewed.

## APK

Latest tracked APK:

[Download latest APK](releases/delivery-route-tracker-latest.apk)

Build output path after a release build:

```text
build/app/outputs/flutter-apk/app-release.apk
```

Install with ADB:

```powershell
C:\Android\Sdk\platform-tools\adb.exe install -r releases\delivery-route-tracker-latest.apk
```

## Screenshots

Tracker home:

![Tracker home](docs/images/delivery_tracker_home.png)

Live map preview:

![Live map preview](docs/images/delivery_tracker_map.png)

## Main Features

- Start and stop delivery shifts.
- Record GPS points and show route previews on OpenStreetMap.
- Continue location tracking through Android foreground location notifications while the app is backgrounded, subject to Android/vendor battery rules.
- Autosave active shifts and recover interrupted active shifts within a configurable recovery grace period.
- Detect route segments and stops with a 300 m stop/wait zone and 60 second stop delay.
- Filter weak GPS accuracy, unrealistic jumps, and speed spikes.
- Track delivery lifecycle states: waiting for order, accepted, at restaurant, picked up, traveling to customer, delivered, cancelled, and exception states.
- Support stacked/multiple active orders inside a shift.
- Store editable pickup restaurant name, platform, and manual trip earnings.
- Calculate Wolt earnings directly and Uber Eats net earnings after 25.5% deduction.
- Show daily, weekly, and monthly performance analytics.
- Split time and distance into active delivery vs no-order waiting/repositioning.
- Review route timeline and replay tracked points.
- Confirm or edit detected trips and stops.
- Export CSV, JSON, GPX, and KML.
- Use dark mode for delivery shifts.
- Run local diagnostics for permissions, notification state, service state, and GPS errors.

## Screen Overview

### Tracker

The Tracker tab is for live shift operation.

Primary home KPIs:

- Active delivery time
- Waiting time with no active order
- Active delivery distance
- Completed deliveries or active utilization
- Active vs waiting progress bar

The home screen intentionally avoids using total distance and stop count as primary KPIs. Those are still available in Calendar and Reports.

### Calendar

The Calendar tab focuses on selected-day route review:

- Day distance
- Day moving time
- Day stop time
- Day stops
- Route map
- Saved shift entries
- Trip/stop editing entry points

### Reports

The Reports tab contains deeper analysis and exports:

- Daily, weekly, and monthly performance selector
- Active delivery time
- Waiting time with no active order
- Active/waiting ratio
- Active delivery distance
- Waiting/repositioning distance
- Timeline playback
- Route verification
- CSV, GPX, KML, and JSON export actions

### Earnings

The Earnings tab shows selected-day income:

- Total net
- Trip count
- Wolt total
- Uber Eats net after 25.5% deduction
- Trip-level restaurant/platform/earnings editing

### Settings

The Settings tab contains app controls and device readiness:

- Dark mode
- Battery-safe tracking
- Shift recovery grace period
- Permission panel
- Run diagnosis
- Data management for JSON backup/restore
- Diagnostics log

## Delivery Workflow

Typical workflow:

1. Start shift.
2. Wait for order.
3. Mark order accepted.
4. Travel to restaurant.
5. Mark at restaurant.
6. Mark picked up.
7. Travel to customer.
8. Mark delivered.
9. Return to waiting for order.
10. Stop shift only when finished for the day/session.

The app stores a shift, delivery trips, orders, route segments, stops, lifecycle events, and GPS points locally.

## Data Model

| Concept | Meaning |
| --- | --- |
| Shift | Full work session from Start Shift to End Shift. |
| Delivery trip | A delivery work cycle inside a shift. |
| Order | One accepted delivery; multiple orders can exist in one shift/trip. |
| Route segment | GPS movement segment detected from tracking data. |
| Stop | Detected stop/wait point that can be classified. |
| Lifecycle event | User-marked delivery state such as accepted, picked up, or delivered. |

## Analytics Definitions

Active delivery time:

- Starts when an order is accepted.
- Ends when that order is delivered or cancelled.
- Includes movement to pickup and drop-off while an active order exists.

Waiting time:

- Time online without an active order.
- Includes waiting for orders, repositioning, moving to hotspots, and searching for work.

Active delivery distance:

- GPS distance where the point-to-point movement occurred during an active order window.

Waiting distance:

- GPS distance while no active order exists.

Utilization:

```text
active delivery time / total shift time
```

Uber Eats net formula:

```text
net = gross * (1 - 0.255)
```

## Export Options

| Format | Purpose |
| --- | --- |
| CSV | Spreadsheet analysis and filtering. |
| JSON | Full backup/restore of app data. |
| GPX | Route viewing in GPS/mapping tools. |
| KML | Google Earth and GIS-compatible route viewing. |

Exports are saved to the app documents folder on Android.

## Tech Stack

| Layer | Technology |
| --- | --- |
| App framework | Flutter |
| Language | Dart |
| Target platform | Android |
| Location | `geolocator` |
| Maps | `flutter_map`, `latlong2`, OpenStreetMap tiles |
| Notifications | `flutter_local_notifications` |
| Permissions | `permission_handler`, Android manifest permissions |
| Local files | `path_provider`, `dart:io` |
| Preferences | `shared_preferences` |
| Date/time formatting | `intl` |
| Build | Gradle wrapper, Android Gradle Plugin, Kotlin/Java toolchain |
| QA | `flutter_lints`, `flutter_test`, `dart analyze` |

## Android Permissions

Declared permissions:

- `ACCESS_FINE_LOCATION`
- `ACCESS_COARSE_LOCATION`
- `ACCESS_BACKGROUND_LOCATION`
- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_LOCATION`
- `POST_NOTIFICATIONS`
- `WAKE_LOCK`
- `INTERNET`
- `SYSTEM_ALERT_WINDOW`
- Legacy `READ_EXTERNAL_STORAGE` and `WRITE_EXTERNAL_STORAGE` with Android version limits

For best tracking reliability:

- Allow location access.
- Allow notification access.
- Allow background location if Android asks.
- Disable battery optimization for this app on strict Android vendors.

## Privacy

Location history is sensitive. The app currently stores route and shift data locally on the device and does not send route history to a cloud backend.

Recommended privacy improvements:

- Biometric/PIN app lock.
- Encrypted local storage.
- Auto-delete old route data.
- Password-protected exports.

## Known Limitations

- Android background tracking reliability still depends on manufacturer battery rules.
- There is no custom native Android foreground service yet; current background tracking relies on Flutter/geolocator foreground location behavior and notification integration.
- Notification action handling is Flutter-side; deeper native handling would be stronger if Android kills the app process.
- Restaurant/place names are manually entered or confirmed.
- JSON restore is clipboard-based, not file-picker based.
- OpenStreetMap tiles require internet access.
- Local data is not encrypted yet.
- iOS is not implemented.

## Recent Milestones

| Milestone | Summary |
| --- | --- |
| v0.10 | Idle vs active delivery analytics for day/week/month. |
| v0.11 | End Shift reliability and separate Reports tab. |
| v0.12 | End Shift UI finalization returns to Start Shift after save. |
| v0.13 | Home KPI redesign around active delivery productivity. |
| v0.14 | Dark-mode readability and Settings declutter. |
| v0.15 | Run diagnosis now performs a visible permission/service recheck. |

## Roadmap

- Native Android foreground service for stronger killed-app behavior.
- Biometric/PIN lock for sensitive location data.
- Encrypted local storage.
- File picker for JSON import/export.
- Automatic restaurant/place suggestions near detected stops.
- Offline map cache.
- Better route smoothing and GPS confidence scoring.
- Unit tests for route segmentation, lifecycle analytics, and GPS filtering.
- Status-colored routes on maps.

## Development

Install dependencies:

```powershell
flutter pub get
```

Run static analysis:

```powershell
dart analyze lib/main.dart
```

Run tests:

```powershell
flutter test
```

Build release APK:

```powershell
flutter build apk --release
```

Use a real Android phone for GPS/background testing. Emulator GPS and background behavior can differ from real delivery conditions.
