Pod::Spec.new do |s|
  s.name             = 'app_links_kit'
  s.version          = '0.1.0'
  s.summary          = 'Incoming Universal Links and custom URL schemes for DartNative.'
  s.description      = <<-DESC
    Captures links from the DartNativeSceneDelegate (cold and warm start) and
    hands them to Dart over FFI. No platform channels, no app code changes.
  DESC
  s.homepage         = 'https://github.com/AbdurahmanAlmehdi/dartnative_app_links'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'Abdurahman Almehdi'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{swift,h,m}'
  s.frameworks       = 'UIKit', 'Foundation'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
