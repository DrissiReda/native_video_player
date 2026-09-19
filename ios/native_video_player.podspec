#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint native_video_player.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'native_video_player'
  s.version          = '1.0.0'
  s.summary          = 'A Flutter widget to play videos on iOS and Android using a native implementation.'
  s.description      = <<-DESC
A Flutter widget to play videos on iOS and Android using a native implementation.
                       DESC
  s.homepage         = 'https://pub.dev/packages/native_video_player'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Alberto Malagoli' => 'albemala@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,m,swift}'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'

  s.platform = :ios, '15.0'
  s.swift_version = '5.0'

  # ADDITIVE (AV1 software decode): minimal LGPL FFmpeg (libavformat,
  # libavcodec, libavutil, libswscale, libswresample) + libdav1d, shipped as
  # static XCFrameworks. Used ONLY by the AV1 software path
  # (Classes/AV1/); the AVPlayer path links nothing new. LGPL compliance:
  # FFmpeg was built --disable-gpl --disable-nonfree, dav1d is BSD-2; see
  # THIRD-PARTY-LICENSES in this repo for the license texts and source offer.
  s.vendored_frameworks = 'XCFrameworks/*.xcframework'
  s.preserve_paths = 'XCFrameworks/**/*'
  s.libraries = 'z', 'bz2', 'iconv', 'c++'
  s.frameworks = 'AudioToolbox', 'CoreMedia', 'CoreVideo', 'VideoToolbox'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/XCFrameworks/Libavcodec.xcframework/ios-arm64/Libavcodec.framework/Headers" "${PODS_TARGET_SRCROOT}/XCFrameworks/Libavformat.xcframework/ios-arm64/Libavformat.framework/Headers" "${PODS_TARGET_SRCROOT}/XCFrameworks/Libavutil.xcframework/ios-arm64/Libavutil.framework/Headers" "${PODS_TARGET_SRCROOT}/XCFrameworks/Libswscale.xcframework/ios-arm64/Libswscale.framework/Headers" "${PODS_TARGET_SRCROOT}/XCFrameworks/Libswresample.xcframework/ios-arm64/Libswresample.framework/Headers" "${PODS_TARGET_SRCROOT}/XCFrameworks/Libdav1d.xcframework/ios-arm64/Libdav1d.framework/Headers"',
    'OTHER_LDFLAGS' => '$(inherited) -lz -lbz2 -liconv -lc++',
  }
end
