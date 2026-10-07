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
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'

  s.platform = :ios, '11.0'
  # Flutter.framework does not contain a i386 slice.
  headers = %w[avcodec avformat avutil swscale swresample].map { |l| "\"${PODS_TARGET_SRCROOT}/XCFrameworks/Lib#{l}.xcframework/ios-arm64/Lib#{l}.framework/Headers\"" }
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386', 'HEADER_SEARCH_PATHS' => "$(inherited) #{headers.join(' ')}" }
  s.swift_version = '5.0'
  s.prepare_command = <<-CMD
    set -eu
    curl -fsSL --retry 3 -o deps.zip "https://github.com/DrissiReda/native_video_player/releases/download/av1-ios9-deps-v1/native-video-player-ios9-deps-f8680fb.zip"
    echo '00ece99276ed7a35fcbc142b9e317b7a5384d08fae53340dae31a8023b30f6a3  deps.zip' | shasum -a 256 -c -
    unzip -oq deps.zip 'XCFrameworks/*' -d . && rm deps.zip
  CMD
  s.vendored_frameworks = 'XCFrameworks/*.xcframework'
  s.libraries = 'z', 'bz2', 'iconv', 'c++'
  s.frameworks = 'AudioToolbox', 'CoreMedia', 'CoreVideo', 'VideoToolbox'
end
