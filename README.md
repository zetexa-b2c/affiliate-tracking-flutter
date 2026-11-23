# affiliate_tracking

Flutter SDK for the affiliate platform (`affiliate-platform-backend`). It
credits app installs, sign-ups and purchases to the affiliate who sent the
user, using the same public tracking API as the web snippet
(`/api/v1/t/click` and `/api/v1/t/conversion`).

It attributes users in three ways:

| How the user arrives | Android | iOS |
|---|---|---|
| Taps an affiliate link and the app is installed (App Link / Universal Link / custom scheme) | yes | yes |
| Taps an affiliate link and installs the app from the store | yes, via the Play Install Referrer | no; see [iOS installs](#ios-installs) |
| Types the affiliate's referral/coupon code in the app | yes | yes |

Clicks and conversions are stored on the device and retried when the
network is down, including across app restarts.

## Install

The package is not on pub.dev. Depend on it from git, pinned to a release tag:

```yaml
dependencies:
  affiliate_tracking:
    git:
      url: https://github.com/zetexa-b2c/affiliate-tracking-flutter.git
      ref: v0.2.0
```

The repository is private, so the machine running `flutter pub get` needs
GitHub access to it (an SSH key or a credential helper; with SSH use
`git@github.com:zetexa-b2c/affiliate-tracking-flutter.git`).

For local work on the SDK itself, a path dependency also works:

```yaml
dependencies:
  affiliate_tracking:
    path: ../affiliate-tracking-flutter
```

## Use

```dart
import 'package:affiliate_tracking/affiliate_tracking.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AffiliateTracker.init(const AffiliateConfig(
    apiBaseUrl: 'https://track.example.com',   // the backend's origin
    trackingKey: 'your-program-tracking-key',   // Admin → Program → tracking key
  ));
  runApp(const MyApp());
}
```

`init` only reads local state, so it is safe to await before `runApp`.

### Deep links

Pass every link that opens the app. Links without a `ref` are ignored.

```dart
// with app_links
AppLinks().uriLinkStream.listen(AffiliateTracker.instance.handleDeepLink);

// or in a go_router redirect
redirect: (context, state) {
  AffiliateTracker.instance.handleDeepLink(state.uri);
  return null;
},
```

The SDK has no dependency on a link plugin; anything that yields a `Uri`
works.

### Conversions

```dart
final result = await AffiliateTracker.instance.trackConversion(
  orderId: order.id,        // idempotency key
  amount: order.total,      // num, >= 0
  currency: 'USD',
);
```

`result.status` is one of:

| Status | Meaning |
|---|---|
| `recorded` | Accepted. It stays `pending` until approved in the dashboard. |
| `duplicate` | This `orderId` was already recorded. Retrying with the same id is always safe. |
| `queued` | Offline, the server is down, or its answer was not about this event (wrong tracking key, a redirect, a proxy error page). Stored and retried until `maxEventAge`. |
| `notAttributed` | No affiliate attribution on this device, so nothing was sent. |
| `rejected` | Refused and not retried, e.g. attribution window expired or unknown code. `result.message` has the server's reason. |

For other events pick an `eventType` and an id that is unique per event:

```dart
await tracker.trackConversion(
  orderId: 'signup:${user.id}',
  amount: 0,
  eventType: ConversionEventType.registration,
);
```

### Referral codes

For a "Who referred you?" field, or a coupon typed at checkout:

```dart
await tracker.setReferralCode('AFF-7K2QX9M'); // becomes the attribution
await tracker.trackConversion(orderId: id, amount: 20, couponCode: 'AFF-7K2QX9M'); // this order only
```

The code is the affiliate's coupon code, which the platform generates when
the affiliate is approved. The API has no endpoint to validate a code, so an
unknown one shows up as `rejected` on the next conversion.

### Which affiliate gets credit

The last touch wins: a newer link or referral code replaces the stored
attribution. A `couponCode` passed to `trackConversion` wins for that one
conversion. When a click is rejected, or a conversion comes back 404/410
(unknown click, or attribution window over), the attribution is cleared so
later conversions do not fail the same way.

The attribution window is enforced by the server, measured from when the
click was recorded.

## Platform setup

### Links

To open the app from the same links affiliates already share
(`https://shop.example.com/?ref=...`), set up verified links on that domain:

- **Android App Links:** an `intent-filter` with `android:autoVerify="true"`
  for the host, and `/.well-known/assetlinks.json` on the site.
- **iOS Universal Links:** the Associated Domains entitlement
  (`applinks:shop.example.com`) and `/.well-known/apple-app-site-association`.

When the app is not installed, the same link opens the website and the web
snippet tracks it as before. A custom scheme (`myshop://open?ref=...`) also
works but does not fall back to the web.

### Android installs

The SDK reads the Play Install Referrer on first launch. For it to carry the
affiliate, the Play Store URL needs a `referrer` parameter:

```
https://play.google.com/store/apps/details?id=com.example.shop&referrer=ref%3D<ref_code>%26click_id%3D<click_id>
```

The platform's affiliate links (`/r/<ref_code>` and `/l/<ref_code>`) build
this for you on Android: set **App deep link** and **Android package** in the
program's settings (General, Website and app). If you also set your own
Google Play URL, the affiliate is added to it; a link that is not Google Play
(a short link, another store) cannot carry it. The click id lets the app
reuse the click the link already recorded instead of counting a second one.

If you build your own "Get the app" button, add the same `referrer` value
yourself.

The referrer is read once per install. Two cases are handled so that adding
the SDK to an existing app does not inflate installs:

- **Existing users getting the SDK in an update** still have a readable
  referrer from their original install. It is ignored when the app has been
  updated since it was installed and that install is more than 7 days old.
- **"Clear storage"** makes the SDK read the referrer again, but the click id
  and the `app_install` order id are derived from the install, so the server
  dedupes both. A reinstall counts as a new install.

An attributed install is reported as an `app_install` conversion with amount
0. On a flat-commission program each approved install pays the flat amount;
set `reportInstalls: false` if installs should not be reported.

The plugin adds the `com.android.installreferrer:installreferrer` library,
whose manifest adds the `BIND_GET_INSTALL_REFERRER_SERVICE` permission.
Installs from outside Google Play are not attributed this way.

### iOS installs

iOS has no install referrer. When the app is installed after tapping a link,
the link's ref is lost. The ways to attribute these installs are a referral
code entered in the app (`setReferralCode`), or having the user tap the link
again once the app is installed. The SDK deliberately does not match installs
by IP address or device fingerprint: that is probabilistic, and Apple's App
Tracking Transparency rules forbid fingerprinting.

## What the SDK stores and sends

Stored on the device (`shared_preferences`, keys prefixed
`affiliate_tracking.`): the current attribution (ref code, click id or
referral code), a random install id, the last link handled (to ignore
repeats), and the queue of undelivered events.

Sent to your affiliate backend only: the ref code, click id, order id (for
`app_install`, `app_install:<key derived from the install>`), amount, currency and event type;
a `Referer` of the link's scheme, host and
path (no query); and a User-Agent such as
`Mozilla/5.0 (Linux; Android 14) Mobile affiliate_tracking/0.2.0` from which
the backend derives OS and phone/tablet. No advertising ids, device ids,
contacts or location.

## Security

Use the program's **tracking key**. Never put the **API secret key** in an
app: anything inside an app can be read from the app file, and the secret
lets its holder approve sales and reverse commissions.

The tracking key is public by design, as it is for the web snippet. Anyone
who has it can post clicks and conversions, and a conversion reported from
inside the app can be forged by a modified app. Conversions are `pending`
until the merchant approves them, so reconcile them against your own order
records before approving.

For purchases, the stronger setup is to have your backend report the sale:
send `AffiliateTracker.instance.attribution?.clickId` with the order, and let
the server call `POST /api/v1/t/conversion` with the `X-API-Secret` header
after payment succeeds. Sales reported that way can be approved
automatically.

### Refunds

Refunds can only be reported from your server, because the server accepts a
refund only with the API secret:

```bash
curl -X POST https://<platform>/api/v1/t/refund \
  -H "Content-Type: application/json" \
  -H "X-API-Secret: <api_secret_key>" \
  -d '{"tracking_key": "<tracking_key>", "external_order_id": "ORD-12345", "refund_amount": 29.99}'
```

The dashboard shows both requests, filled in, on the program's Tracking tab.
`trackRefund()` in the SDK is deprecated: it sends nothing and returns
`rejected` with this explanation.

## Backend requirements

The SDK needs a backend that includes these changes (made alongside it):

- `tracking.py`: `allowed_domains` is checked only for requests that carry
  an `Origin` header. Apps send none, so earlier backends answer 403 to every
  app request on a program with an allowlist.
- `analytics_service.py`: clicks from the SDK get `browser = "App"`.
- `smart_link.py`: affiliate links on Android send users to Google Play with
  `ref` and `click_id` in `referrer`, also when the program has its own
  Google Play URL.

## Configuration

| Option | Default | |
|---|---|---|
| `apiBaseUrl` | required | Backend origin; a path prefix is kept. |
| `trackingKey` | required | The program's tracking key. |
| `refParams` | `['ref']` | Query parameters that carry the ref code. |
| `clickIdParams` | `['click_id', 'aff_click_id']` | Query parameters that may carry an existing click id. |
| `readInstallReferrer` | `true` | Android: read the Play Install Referrer on first launch. |
| `reportInstalls` | `true` | Report `app_install` for referrer-attributed installs. |
| `maxEventAge` | 30 days | Queued events older than this are dropped. |
| `requestTimeout` | 15 s | Per request. |
| `debug` | `false` | Log to `dart:developer` under `affiliate_tracking`. |

## Development

```bash
flutter test
```

The live test runs the SDK against a real backend and is skipped unless one
is configured. It creates real clicks and conversions, so point it at a
scratch program:

```bash
flutter test test/live_backend_test.dart --dart-define=E2E_API=http://127.0.0.1:8036 --dart-define=E2E_TRACKING_KEY=<key> --dart-define=E2E_REF=<ref_code> --dart-define=E2E_COUPON=<coupon>
```

The example app in `example/` shows the attribution, the queue, and buttons
to simulate a link, a referral code and a purchase against a real backend:

```bash
cd example
flutter run --dart-define=AFFILIATE_API=http://10.0.2.2:8035 --dart-define=AFFILIATE_TRACKING_KEY=<key>
```

The inspector app in `test_sdk_app/` runs the SDK against a built-in mock
server, so it needs no backend or key. Use it to click through links, codes,
conversions, duplicates and clearing attribution:

```bash
cd test_sdk_app
flutter test     # scripted smoke test
flutter run      # try it by hand (macOS, Chrome, Android or iOS)
```

To test a link on an emulator:
`adb shell am start -a android.intent.action.VIEW -d "affiliatedemo://open?ref=<ref_code>"`.
To test the install referrer end to end, the app has to be installed from a
Play Store listing (an internal testing track works).
