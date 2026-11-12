Pod::Spec.new do |s|
  s.name             = 'affiliate_tracking'
  s.version          = '0.1.0'
  s.summary          = 'Affiliate tracking Flutter SDK'
  s.description      = <<-DESC
Affiliate click, event and conversion tracking for Flutter apps.
                       DESC
  s.homepage         = 'https://example.invalid'
  s.license          = { :type => 'BSD' }
  s.author           = { 'Affiliate platform' => 'noreply@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
