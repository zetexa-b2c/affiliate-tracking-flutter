Pod::Spec.new do |s|
  s.name             = 'zet_affiliate_tracking'
  s.version          = '0.1.0'
  s.summary          = 'ZetSIM Affiliate tracking Flutter SDK'
  s.description      = <<-DESC
ZetSIM Affiliate click, event and conversion tracking for Flutter apps.
                       DESC
  s.homepage         = 'https://zetsim.com'
  s.license          = { :type => 'BSD' }
  s.author           = { 'ZetSim' => 'dev@zetsim.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
