# Copyright (c) 2009-2012 VMware, Inc.

require 'common/version/release_version'

module Bosh::Director
  module Jobs
    class UpdateRelease < BaseJob
      include LockHelper
      include DownloadHelper

      @queue = :normal

      attr_accessor :release_model
      attr_accessor :tmp_release_dir

      def self.job_type
        :update_release
      end

      # @param [String] tmp_release_dir Directory containing release bundle
      # @param [Hash] options Release update options
      def initialize(tmp_release_dir, options = {})
        @tmp_release_dir = tmp_release_dir
        @release_model = nil
        @release_version_model = nil

        @rebase = !!options["rebase"]

        @manifest = nil
        @name = nil
        @version = nil

        @packages_unchanged = false
        @jobs_unchanged = false

        @remote_release = options['remote'] || false
        @remote_release_location = options['location'] if @remote_release
      end

      # Extracts release tarball, verifies release manifest and saves release
      # in DB
      # @return [void]
      def perform
        logger.info("Processing update release")
        if @rebase
          logger.info("Release rebase will be performed")
        end

        single_step_stage("Downloading remote release") { download_remote_release } if @remote_release
        single_step_stage("Extracting release") { extract_release }
        single_step_stage("Verifying manifest") { verify_manifest }

        with_release_lock(@name) { process_release }

        if @rebase && @packages_unchanged && @jobs_unchanged
          raise DirectorError,
                "Rebase is attempted without any job or package changes"
        end

        "Created release `#{@name}/#{@version}'"
      rescue Exception => e
        remove_release_version_model
        raise e
      ensure
        if @tmp_release_dir && File.exists?(@tmp_release_dir)
          FileUtils.rm_rf(@tmp_release_dir)
        end
      end

      def download_remote_release
        release_file = File.join(@tmp_release_dir, Api::ReleaseManager::RELEASE_TGZ)
        download_remote_file('release', @remote_release_location, release_file)
      end

      # Extracts release tarball
      # @return [void]
      def extract_release
        release_tgz = File.join(@tmp_release_dir,
                                Api::ReleaseManager::RELEASE_TGZ)

        result = Bosh::Exec.sh("tar -C #{@tmp_release_dir} -xzf #{release_tgz} 2>&1", :on_error => :return)
        if result.failed?
          logger.error("Extracting release archive failed in dir #{@tmp_release_dir}, " +
                       "tar returned #{result.exit_status}, " +
                       "output: #{result.output}")
          raise ReleaseInvalidArchive, "Extracting release archive failed. Check task debug log for details."
        end
      ensure
        if release_tgz && File.exists?(release_tgz)
          FileUtils.rm(release_tgz)
        end
      end

      # @return [void]
      def verify_manifest
        manifest_file = File.join(@tmp_release_dir, "release.MF")
        unless File.file?(manifest_file)
          raise ReleaseManifestNotFound, "Release manifest not found"
        end

        @manifest = Psych.load_file(manifest_file)
        normalize_manifest

        @name = @manifest["name"]

        begin
          @version = Bosh::Common::Version::ReleaseVersion.parse(@manifest["version"])
          unless @version == @manifest["version"]
            logger.info("Formatted version '#{@manifest["version"]}' => '#{@version}'")
          end
        rescue SemiSemantic::ParseError
          raise ReleaseVersionInvalid, "Release version invalid: #{@manifest["version"]}"
        end

        @commit_hash = @manifest.fetch("commit_hash", nil)
        @uncommitted_changes = @manifest.fetch("uncommitted_changes", nil)
      end

      # Processes uploaded release, creates jobs and packages in DB if needed
      # @return [void]
      def process_release
        @release_model = Models::Release.find_or_create(:name => @name)

        if @rebase
          @version = next_release_version
        end

        version_attrs = {
          :release => @release_model,
          :version => @version.to_s
        }
        version_attrs[:uncommitted_changes] = @uncommitted_changes if @uncommitted_changes
        version_attrs[:commit_hash] = @commit_hash if @commit_hash

        @release_version_model = Models::ReleaseVersion.new(version_attrs)
        unless @release_version_model.valid?
          if @release_version_model.errors[:version] == [:format]
            raise ReleaseVersionInvalid,
              "Release version invalid `#{@name}/#{@version}'"
          else
            raise ReleaseAlreadyExists,
              "Release `#{@name}/#{@version}' already exists"
          end
        end

        @release_version_model.save

        single_step_stage("Resolving package dependencies") do
          resolve_package_dependencies(@manifest["packages"])
        end

        @packages = {}
        process_packages
        process_jobs

        event_log.begin_stage("Release has been created", 1)
        event_log.track("#{@name}/#{@version}") {}
      end

      # Normalizes release manifest, so all names, versions, and checksums are Strings.
      # @return [void]
      def normalize_manifest
        Bosh::Director.hash_string_vals(@manifest, 'name', 'version')

        @manifest['packages'].each { |p| Bosh::Director.hash_string_vals(p, 'name', 'version', 'sha1') }
        @manifest['jobs'].each { |j| Bosh::Director.hash_string_vals(j, 'name', 'version', 'sha1') }
      end

      # Resolves package dependencies, makes sure there are no cycles
      # and all dependencies are present
      # @return [void]
      def resolve_package_dependencies(packages)
        packages_by_name = {}
        packages.each do |package|
          packages_by_name[package["name"]] = package
          package["dependencies"] ||= []
        end
        dependency_lookup = lambda do |package_name|
          packages_by_name[package_name]["dependencies"]
        end
        result = CycleHelper.check_for_cycle(packages_by_name.keys,
                                             :connected_vertices => true,
                                             &dependency_lookup)

        packages.each do |package|
          name = package["name"]
          dependencies = package["dependencies"]

          logger.info("Resolving package dependencies for `#{name}', " +
                      "found: #{dependencies.pretty_inspect}")
          package["dependencies"] = result[:connected_vertices][name]
          logger.info("Resolved package dependencies for `#{name}', " +
                      "to: #{dependencies.pretty_inspect}")
        end
      end

      # Finds all package definitions in the manifest and sorts them into two
      # buckets: new and existing packages, then creates new packages and points
      # current release version to the existing packages.
      # @return [void]
      def process_packages
        logger.info("Checking for new packages in release")

        new_packages = []
        existing_packages = []

        @manifest["packages"].each do |package_meta|
          # Checking whether we might have the same bits somewhere
          packages = Models::Package.where(fingerprint: package_meta["fingerprint"]).all

          if packages.empty?
            new_packages << package_meta
            next
          end

          existing_package = packages.find do |package|
            package.release_id == @release_model.id &&
            package.name == package_meta["name"] &&
            package.version == package_meta["version"]
          end

          if existing_package
            existing_packages << [existing_package, package_meta]
          else
            # We found a package with the same checksum but different
            # (release, name, version) tuple, so we need to make a copy
            # of the package blob and create a new db entry for it
            package = packages.first
            package_meta["blobstore_id"] = package.blobstore_id
            package_meta["sha1"] = package.sha1
            new_packages << package_meta
          end
        end

        create_packages(new_packages)
        use_existing_packages(existing_packages)
      end

      # Creates packages using provided metadata
      # @param [Array<Hash>] packages Packages metadata
      # @return [void]
      def create_packages(packages)
        if packages.empty?
          @packages_unchanged = true
          return
        end

        event_log.begin_stage("Creating new packages", packages.size)
        packages.each do |package_meta|
          package_desc = "#{package_meta["name"]}/#{package_meta["version"]}"
          event_log.track(package_desc) do
            logger.info("Creating new package `#{package_desc}'")
            package = create_package(package_meta)
            register_package(package)
          end
        end
      end

      # Points release DB model to existing packages described by given metadata
      # @param [Array<Array>] packages Existing packages metadata
      def use_existing_packages(packages)
        return if packages.empty?

        single_step_stage("Processing #{packages.size} existing package#{"s" if packages.size > 1}") do
          packages.each do |package, _|
            package_desc = "#{package.name}/#{package.version}"
            logger.info("Using existing package `#{package_desc}'")
            register_package(package)
          end
        end
      end

      # Creates package in DB according to given metadata
      # @param [Hash] package_meta Package metadata
      # @return [void]
      def create_package(package_meta)
        name, version = package_meta["name"], package_meta["version"]

        package_attrs = {
          :release => @release_model,
          :name => name,
          :sha1 => package_meta["sha1"],
          :fingerprint => package_meta["fingerprint"],
          :version => version
        }

        package = Models::Package.new(package_attrs)
        package.dependency_set = package_meta["dependencies"]

        existing_blob = package_meta["blobstore_id"]
        desc = "package `#{name}/#{version}'"

        if existing_blob
          logger.info("Creating #{desc} from existing blob #{existing_blob}")
          package.blobstore_id = BlobUtil.copy_blob(existing_blob)
        else
          logger.info("Creating #{desc} from provided bits")

          package_tgz = File.join(@tmp_release_dir, "packages", "#{name}.tgz")
          result = Bosh::Exec.sh("tar -tzf #{package_tgz} 2>&1", :on_error => :return)
          if result.failed?
            logger.error("Extracting #{desc} archive failed, " +
                         "tar returned #{result.exit_status}, " +
                         "output: #{result.output}")
            raise PackageInvalidArchive, "Extracting #{desc} archive failed. Check task debug log for details."
          end

          package.blobstore_id = BlobUtil.create_blob(package_tgz)
        end

        package.save
      end

      # Marks package model as used by release version model
      # @param [Models::Package] package Package model
      # @return [void]
      def register_package(package)
        @packages[package.name] = package
        @release_version_model.add_package(package)
      end

      # Finds job template definitions in release manifest and sorts them into
      # two buckets: new and existing job templates, then creates new job
      # template records in the database and points release version to existing ones.
      # @return [void]
      def process_jobs
        logger.info("Checking for new jobs in release")

        new_jobs = []
        existing_jobs = []

        @manifest["jobs"].each do |job_meta|
          # Checking whether we might have the same bits somewhere
          jobs = Models::Template.where(fingerprint: job_meta["fingerprint"]).all

          template = jobs.find do |job|
            job.release_id == @release_model.id &&
            job.name == job_meta["name"] &&
            job.version == job_meta["version"]
          end

          if template.nil?
            new_jobs << job_meta
          else
            existing_jobs << [template, job_meta]
          end
        end

        create_jobs(new_jobs)
        use_existing_jobs(existing_jobs)
      end

      def create_jobs(jobs)
        if jobs.empty?
          @jobs_unchanged = true
          return
        end

        event_log.begin_stage("Creating new jobs", jobs.size)
        jobs.each do |job_meta|
          job_desc = "#{job_meta["name"]}/#{job_meta["version"]}"
          event_log.track(job_desc) do
            logger.info("Creating new template `#{job_desc}'")
            template = create_job(job_meta)
            register_template(template)
          end
        end
      end

      def create_job(job_meta)
        name, version = job_meta["name"], job_meta["version"]

        template_attrs = {
          :release => @release_model,
          :name => name,
          :sha1 => job_meta["sha1"],
          :fingerprint => job_meta["fingerprint"],
          :version => version
        }

        logger.info("Creating job template `#{name}/#{version}' " +
                    "from provided bits")
        template = Models::Template.new(template_attrs)

        job_tgz = File.join(@tmp_release_dir, "jobs", "#{name}.tgz")
        job_dir = File.join(@tmp_release_dir, "jobs", "#{name}")

        FileUtils.mkdir_p(job_dir)

        desc = "job `#{name}/#{version}'"
        result = Bosh::Exec.sh("tar -C #{job_dir} -xzf #{job_tgz} 2>&1", :on_error => :return)
        if result.failed?
          logger.error("Extracting #{desc} archive failed in dir #{job_dir}, " +
                       "tar returned #{result.exit_status}, " +
                       "output: #{result.output}")
          raise JobInvalidArchive, "Extracting #{desc} archive failed. Check task debug log for details."
        end

        manifest_file = File.join(job_dir, "job.MF")
        unless File.file?(manifest_file)
          raise JobMissingManifest,
                "Missing job manifest for `#{template.name}'"
        end

        job_manifest = Psych.load_file(manifest_file)

        if job_manifest["templates"]
          job_manifest["templates"].each_key do |relative_path|
            path = File.join(job_dir, "templates", relative_path)
            unless File.file?(path)
              raise JobMissingTemplateFile,
                    "Missing template file `#{relative_path}' for job `#{template.name}'"
            end
          end
        end

        main_monit_file = File.join(job_dir, "monit")
        aux_monit_files = Dir.glob(File.join(job_dir, "*.monit"))

        unless File.exists?(main_monit_file) || aux_monit_files.size > 0
          raise JobMissingMonit, "Job `#{template.name}' is missing monit file"
        end

        template.blobstore_id = BlobUtil.create_blob(job_tgz)

        package_names = []
        job_manifest["packages"].each do |package_name|
          package = @packages[package_name]
          if package.nil?
            raise JobMissingPackage,
                  "Job `#{template.name}' is referencing " +
                  "a missing package `#{package_name}'"
          end
          package_names << package.name
        end
        template.package_names = package_names

        if job_manifest["logs"]
          unless job_manifest["logs"].is_a?(Hash)
            raise JobInvalidLogSpec,
                  "Job `#{template.name}' has invalid logs spec format"
          end

          template.logs = job_manifest["logs"]
        end

        if job_manifest["properties"]
          unless job_manifest["properties"].is_a?(Hash)
            raise JobInvalidPropertySpec,
                  "Job `#{template.name}' has invalid properties spec format"
          end

          template.properties = job_manifest["properties"]
        end

        template.save
      end

      # @param [Array<Array>] jobs Existing jobs metadata
      # @return [void]
      def use_existing_jobs(jobs)
        return if jobs.empty?

        single_step_stage("Processing #{jobs.size} existing job#{"s" if jobs.size > 1}") do
          jobs.each do |template, _|
            job_desc = "#{template.name}/#{template.version}"
            logger.info("Using existing job `#{job_desc}'")
            register_template(template)
          end
        end
      end

      # Marks job template model as being used by release version
      # @param [Models::Template] template Job template model
      # @return [void]
      def register_template(template)
        @release_version_model.add_template(template)
      end

      private

      # Returns the next release version (to be used for rebased release)
      # @return [String]
      def next_release_version
        attrs = {:release_id => @release_model.id}
        models = Models::ReleaseVersion.filter(attrs).all
        strings = models.map(&:version)
        list = Bosh::Common::Version::ReleaseVersionList.parse(strings)
        list.rebase(@version)
      end

      # Removes release version model, along with all packages and templates.
      # @return [void]
      def remove_release_version_model
        return unless @release_version_model && !@release_version_model.new?

        @release_version_model.remove_all_packages
        @release_version_model.remove_all_templates
        @release_version_model.destroy
      end
    end
  end
end
