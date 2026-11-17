# frozen_string_literal: true
# Uses xcodeproj already bundled with the installed CocoaPods; no gem install.
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'ios/Runner.xcodeproj'))
runner = project.targets.find { |target| target.name == 'Runner' }
raise 'Missing Runner target' unless runner

def add_file(group, path)
  group.files.find { |file| file.path == path } || group.new_file(path)
end

def source(target, file)
  target.source_build_phase.add_file_reference(file) unless target.source_build_phase.files_references.include?(file)
end

runner_group = project.main_group.find_subpath('Runner', false)
source(runner, add_file(runner_group, 'ShiriPlatformBridge.swift'))
source(runner, add_file(runner_group, 'ShiriCalendar.swift'))
source(runner, add_file(runner_group, 'ShiriWidgetReloader.swift'))
add_file(runner_group, 'Runner.entitlements')
privacy = add_file(runner_group, 'PrivacyInfo.xcprivacy')
runner.resources_build_phase.add_file_reference(privacy) unless runner.resources_build_phase.files_references.include?(privacy)

widget_group = project.main_group.find_subpath('ShiriWidgets', false) || project.main_group.new_group('ShiriWidgets', 'ShiriWidgets')
widget = project.targets.find { |target| target.name == 'ShiriWidgets' } || project.new_target(:app_extension, 'ShiriWidgets', :ios, '16.0')
source(widget, add_file(widget_group, 'ShiriWidgets.swift'))
source(widget, add_file(widget_group, 'AnniversaryDays.swift'))
add_file(widget_group, 'Info.plist')
add_file(widget_group, 'ShiriWidgets.entitlements')
%w[SwiftUI WidgetKit AppIntents].each do |framework|
  widget.add_system_framework(framework) unless widget.frameworks_build_phase.files_references.any? { |file| file.path&.end_with?(framework + '.framework') }
end
widget.frameworks_build_phase.files_references.each do |file|
  next unless file.path&.include?('/System/Library/Frameworks/')
  file.path = 'System/Library/Frameworks/' + File.basename(file.path)
  file.source_tree = 'SDKROOT'
end

# The same immutable Adobe font assets serve Flutter and WidgetKit.
fonts_group = project.main_group.find_subpath('Fonts', false) || project.main_group.new_group('Fonts', '../assets/font')
%w[light regular medium].each do |weight|
  font = add_file(fonts_group, "source_han_sans_cn_#{weight}.otf")
  widget.resources_build_phase.add_file_reference(font) unless widget.resources_build_phase.files_references.include?(font)
end

project.build_configurations.each { |config| config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0' }
runner.build_configurations.each do |config|
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.shiri.anniversary'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
end

widget.build_configurations.each do |config|
  config.build_settings.merge!({
    'APPLICATION_EXTENSION_API_ONLY' => 'YES',
    'CODE_SIGN_ENTITLEMENTS' => 'ShiriWidgets/ShiriWidgets.entitlements',
    'CODE_SIGN_STYLE' => 'Automatic',
    'CURRENT_PROJECT_VERSION' => '1',
    'MARKETING_VERSION' => '1.0.0',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'INFOPLIST_FILE' => 'ShiriWidgets/Info.plist',
    'IPHONEOS_DEPLOYMENT_TARGET' => '16.0',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks'],
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.shiri.anniversary.widgets',
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'SKIP_INSTALL' => 'YES',
    'SWIFT_VERSION' => '5.0',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => '',
    'SWIFT_EMIT_LOC_STRINGS' => 'YES'
  })
end

runner.add_dependency(widget) unless runner.dependencies.any? { |dependency| dependency.target == widget }
embed = runner.copy_files_build_phases.find { |phase| phase.name == 'Embed App Extensions' } || runner.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
embed.dst_path = ''
unless embed.files_references.include?(widget.product_reference)
  file = embed.add_file_reference(widget.product_reference)
  file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
# Embed before Flutter's Thin Binary phase to avoid an extension-copy cycle.
runner.build_phases.delete(embed)
thin_index = runner.build_phases.index { |phase| phase.respond_to?(:name) && phase.name == 'Thin Binary' } || runner.build_phases.length
runner.build_phases.insert(thin_index, embed)

attributes = project.root_object.attributes['TargetAttributes'] ||= {}
[runner, widget].each do |target|
  attributes[target.uuid] ||= {}
  attributes[target.uuid]['SystemCapabilities'] ||= {}
  attributes[target.uuid]['SystemCapabilities']['com.apple.ApplicationGroups.iOS'] = { 'enabled' => 1 }
end
project.save
puts 'Configured Runner bridge and embedded ShiriWidgets extension (iOS 16+).'
