#!/usr/bin/env ruby
# Legt das iOS-Share-Extension-Target an bzw. aktualisiert es, damit
# PaperBuddy Dateien aus dem Teilen-Menü anderer Apps empfängt.
#
#   ruby tool/ios_share_extension.rb
#
# Wiederholbar: nach `flutter pub upgrade` erneut ausführen, damit der Pfad
# zum Swift-Paket von receive_sharing_intent stimmt.
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'ios/Runner.xcodeproj')
project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |t| t.name == 'Runner' } or abort 'Runner-Target fehlt'

packages = File.join(root, 'ios/Flutter/ephemeral/Packages/.packages')
package_dir = Dir.glob(File.join(packages, 'receive_sharing_intent*')).max or
  abort 'receive_sharing_intent nicht gefunden – zuerst `flutter build ios --config-only` ausführen'
relative_package = package_dir.sub("#{File.join(root, 'ios')}/", '')

name = 'ShareExtension'
group_id = 'group.$(PAPERBUDDY_BUNDLE_ID)'
debug_xc = project.files.find { |f| f.path&.end_with?('Debug.xcconfig') && f.path.include?('Flutter') }
release_xc = project.files.find { |f| f.path&.end_with?('Release.xcconfig') && f.path.include?('Flutter') }

ext = project.targets.find { |t| t.name == name }
unless ext
  ext = project.new_target(:app_extension, name, :ios, '15.0', nil, :swift)
  group = project.main_group.find_subpath(name, true)
  group.set_source_tree('<group>')
  group.set_path(name)
  swift = group.new_reference('ShareViewController.swift')
  ext.add_file_references([swift])
  storyboard = group.new_variant_group('MainInterface.storyboard')
  storyboard.new_reference('Base.lproj/MainInterface.storyboard').name = 'Base'
  ext.resources_build_phase.add_file_reference(storyboard)
  group.new_reference('Info.plist')
  group.new_reference("#{name}.entitlements")

  # Einbetten in die App, vor „Thin Binary“.
  embed = runner.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' } ||
          runner.new_copy_files_build_phase('Embed Foundation Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
  build_file = embed.add_file_reference(ext.product_reference, true)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  runner.add_dependency(ext)
  thin = runner.build_phases.find { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
  if thin
    runner.build_phases.delete(embed)
    runner.build_phases.insert(runner.build_phases.index(thin), embed)
  end
end

ext.build_configurations.each do |config|
  s = config.build_settings
  config.base_configuration_reference = config.name == 'Debug' ? debug_xc : release_xc
  s['PRODUCT_BUNDLE_IDENTIFIER'] = '$(PAPERBUDDY_BUNDLE_ID).ShareExtension'
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['INFOPLIST_FILE'] = "#{name}/Info.plist"
  # Feste Gruppen-ID je Variante; Xcode setzt beim Registrieren im
  # Apple-Konto keine Variablen in Entitlements ein.
  s['CODE_SIGN_ENTITLEMENTS'] = "#{name}/#{name}$(PAPERBUDDY_VARIANT).entitlements"
  s['CUSTOM_GROUP_ID'] = group_id
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  s['SWIFT_VERSION'] = '5.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['SKIP_INSTALL'] = 'YES'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
end

runner.build_configurations.each do |config|
  config.build_settings['CUSTOM_GROUP_ID'] = group_id
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner$(PAPERBUDDY_VARIANT).entitlements'
end
runner_group = project.main_group['Runner']
%w[Runner.entitlements Runner-dev.entitlements].each do |f|
  runner_group.new_reference(f) unless runner_group.files.any? { |r| r.path == f }
end
ext_group = project.main_group[name]
%W[#{name}.entitlements #{name}-dev.entitlements].each do |f|
  ext_group.new_reference(f) unless ext_group.files.any? { |r| r.path == f }
end

# Swift-Paket von receive_sharing_intent für die Extension.
ref = project.root_object.package_references.find do |r|
  r.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) && r.relative_path.to_s.include?('receive_sharing_intent')
end
unless ref
  ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  project.root_object.package_references << ref
end
ref.relative_path = relative_package

unless ext.package_product_dependencies.any? { |d| d.product_name == 'receive-sharing-intent' }
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = 'receive-sharing-intent'
  ext.package_product_dependencies << dep
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  ext.frameworks_build_phase.files << build_file
end
ext.package_product_dependencies.each { |d| d.package = ref if d.product_name == 'receive-sharing-intent' }

# App Groups als Capability eintragen, damit die automatische Signierung
# die Gruppe im Apple-Konto anlegt und in beide Profile aufnimmt.
attributes = project.root_object.attributes['TargetAttributes'] ||= {}
[runner, ext].each do |t|
  a = attributes[t.uuid] ||= {}
  a['SystemCapabilities'] = { 'com.apple.ApplicationGroups.iOS' => { 'enabled' => '1' } }
end

project.save
puts "Share Extension eingerichtet (Paket: #{relative_package})"
