platform :ios, '26.5'

inhibit_all_warnings!

project 'vr-player.xcodeproj'

target 'vr-player' do
  pod 'Protobuf-C++', '3.18.0'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      next unless target.name == 'Protobuf-C++'

      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.5'
      config.build_settings['CLANG_CXX_LANGUAGE_STANDARD'] = 'c++17'
    end
  end
end
