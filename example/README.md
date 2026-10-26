# affiliate_tracking example

A demo screen for the SDK: shows the current attribution and the number of
undelivered events, and has buttons to simulate an affiliate link, apply a
referral code, make a $49.99 purchase, flush the queue and clear the
attribution. Links arrive through `app_links`; the Android manifest handles
`affiliatedemo://open?ref=<ref_code>`.

```bash
flutter run --dart-define=AFFILIATE_API=http://10.0.2.2:8035 --dart-define=AFFILIATE_TRACKING_KEY=<key>
```

`10.0.2.2` is the host machine as seen from the Android emulator. The
manifest allows cleartext HTTP so the demo can reach a local backend; a real
app should use HTTPS.
