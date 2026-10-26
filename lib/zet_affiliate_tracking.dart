/// ZetSIM Affiliate & Referral tracking SDK for Flutter apps, backed by the
/// affiliate platform's public tracking API.
library;

export 'src/config.dart' show AffiliateConfig;
export 'src/link_parser.dart' show AffiliateParams;
export 'src/models.dart'
    show
        Attribution,
        AttributionSource,
        ConversionEventType,
        ConversionResult,
        ConversionStatus,
        EventNames,
        EventResult,
        EventStatus;
export 'src/platform.dart'
    show InstallReferrerDetails, InstallReferrerException, InstallReferrerSource;
export 'src/storage.dart' show KeyValueStore, MemoryStore, SharedPreferencesStore;
export 'src/tracker.dart' show AffiliateTracker;
