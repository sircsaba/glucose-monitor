# Adds the BGWidget extension (home-screen / lock-screen glucose) to the Xcode
# project that `flutter create` generated. Run from the repository root, after
# `flutter build ios --config-only` and `pod install`:
#   bundle exec ruby native/ios/add_widget.rb
require 'xcodeproj'
require 'fileutils'

bundle_id = ENV['BUNDLE_ID'] || 'com.monitorglucose.app'
build = ENV['BUILD_NUMBER'] || '1'
version = File.read('pubspec.yaml')[/^version:\s*([0-9.]+)/, 1] || '1.0.0'

FileUtils.mkdir_p('ios/BGWidget')
FileUtils.cp('native/ios/BGWidget/BGWidget.swift', 'ios/BGWidget/BGWidget.swift')
File.write('ios/BGWidget/Info.plist', <<~PLIST)
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>CFBundleDevelopmentRegion</key><string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleDisplayName</key><string>Glucose</string>
    <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key><string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
    <key>CFBundleShortVersionString</key><string>#{version}</string>
    <key>CFBundleVersion</key><string>#{build}</string>
    <key>NSExtension</key>
    <dict>
      <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
  </dict>
  </plist>
PLIST

proj = Xcodeproj::Project.open('ios/Runner.xcodeproj')
if proj.targets.any? { |t| t.name == 'BGWidget' }
  puts 'BGWidget already in the project'
  exit 0
end
app = proj.targets.find { |t| t.name == 'Runner' }

widget = proj.new_target(:app_extension, 'BGWidget', :ios, '17.0', nil, :swift)
group = proj.main_group.new_group('BGWidget', 'BGWidget')
swift = group.new_reference('BGWidget.swift')
group.new_reference('Info.plist')
widget.add_file_references([swift])

widget.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{bundle_id}.BGWidget"
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['INFOPLIST_FILE'] = 'BGWidget/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  s['SWIFT_VERSION'] = '5.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['SKIP_INSTALL'] = 'YES'
  s['MARKETING_VERSION'] = version
  s['CURRENT_PROJECT_VERSION'] = build
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
  s['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = ''
  s['ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME'] = ''
end

app.add_dependency(widget)
embed = app.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
bf = embed.add_file_reference(widget.product_reference, true)
bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# Embed the widget before Flutter's script phases ("Thin Binary"), or Xcode
# reports a dependency cycle.
app.build_phases.delete(embed)
first_script = app.build_phases.index { |p| p.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) && p.name.to_s.include?('Thin Binary') }
idx = first_script || app.build_phases.length
app.build_phases.insert(idx, embed)

proj.save
puts "BGWidget added (#{bundle_id}.BGWidget, version #{version} (#{build}))"
