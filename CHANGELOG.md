## 0.2.0

- `trackRefund()` is deprecated and sends nothing. The server accepts refunds
  only with the program's API secret, which an app cannot keep, so it always
  refused them. Report refunds from your server (see README, Refunds).
- README: Android installs from the platform's affiliate links, never putting
  the API secret in an app, and the server refund request. Removed the
  `affiliateSDK.playStoreUrl()` instructions: the web snippet has no such
  function.

## 0.1.0

- First version: deep-link clicks, Google Play Install Referrer attribution
  (Android) with optional `app_install` conversions, referral/coupon codes,
  and conversions with an offline, persistent retry queue.
